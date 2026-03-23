import os from 'node:os';
import { execFile, execFileSync } from 'node:child_process';
import { PdhQuery } from './pdh.js';

function isAdmin(): boolean {
  try {
    const result = execFileSync('powershell.exe', [
      '-NoProfile', '-Command',
      'if(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){"true"}else{"false"}'
    ], { timeout: 3000, windowsHide: true, encoding: 'utf-8' });
    return result.trim() === 'true';
  } catch {
    return false;
  }
}

interface CpuTimes {
  user: number;
  nice: number;
  sys: number;
  idle: number;
  irq: number;
}

export interface NativeSample {
  timestamp: number; // Date.now()
  cpu_percent: number;
  cpu_per_core?: number[];
  memory_total_mb: number;
  memory_used_mb: number;
  memory_free_mb: number;
  memory_used_percent: number;
  disk_read_bytes_sec?: number;
  disk_write_bytes_sec?: number;
  disk_idle_percent?: number;
  disk_queue_length?: number;
  cpu_interrupts_sec?: number;
  cpu_temp_c?: number;
  gpu_3d_percent?: number;
  gpu_temp_c?: number;
  gpu_power_w?: number;
  gpu_clock_mhz?: number;
  gpu_mem_clock_mhz?: number;
  net_recv_bytes_sec?: number;
  net_sent_bytes_sec?: number;
  [key: string]: unknown;
}

export interface SamplerConfig {
  cpu?: boolean;
  memory?: boolean;
  disk?: boolean;
  gpu?: boolean;
  network?: boolean;
  cpuPerCore?: boolean;
}

export class NativeSampler {
  private config: SamplerConfig;
  private pdhQuery: PdhQuery | null = null;
  private prevCpuTimes: CpuTimes[] = [];
  private initialized = false;
  private pdhHasDisk = false;
  private pdhHasGpu = false;
  private pdhHasNet = false;
  private pdhHasInterrupts = false;
  // CPU temp (WMI, requires admin, cached ~1s)
  private canReadCpuTemp = false;
  private cpuTemp: number | null = null;
  private lastCpuTempTime = 0;
  private cpuTempPending = false;
  // nvidia-smi cached data (refreshed every ~1s)
  private nvidiaSmiAvailable = false;
  private gpuTelemetry: { temp: number; power: number; clockGfx: number; clockMem: number } | null = null;
  private lastNvidiaSmiTime = 0;
  private nvidiaSmiPending = false;

  constructor(config: SamplerConfig = {}) {
    this.config = {
      cpu: true,
      memory: true,
      disk: true,
      gpu: true,
      network: true,
      cpuPerCore: false,
      ...config,
    };
  }

  init(): void {
    // Snapshot initial CPU times for delta calculation
    this.prevCpuTimes = os.cpus().map(c => c.times);

    // Set up PDH for disk, GPU, network
    if (this.config.disk || this.config.gpu || this.config.network) {
      try {
        this.pdhQuery = new PdhQuery();
        this.pdhQuery.open();

        // CPU interrupts/sec
        if (this.config.cpu) {
          this.pdhHasInterrupts = this.pdhQuery.addCounter('cpu.interrupts_sec', '\\Processor(_Total)\\Interrupts/sec');
        }

        if (this.config.disk) {
          this.pdhHasDisk = true;
          this.pdhHasDisk = this.pdhQuery.addCounter('disk.read_bytes_sec', '\\PhysicalDisk(_Total)\\Disk Read Bytes/sec')
            && this.pdhQuery.addCounter('disk.write_bytes_sec', '\\PhysicalDisk(_Total)\\Disk Write Bytes/sec')
            && this.pdhQuery.addCounter('disk.idle_percent', '\\PhysicalDisk(_Total)\\% Idle Time')
            && this.pdhQuery.addCounter('disk.queue_length', '\\PhysicalDisk(_Total)\\Current Disk Queue Length');
        }

        if (this.config.gpu) {
          // Only add 3D engine counters to keep counter count manageable (~50 vs ~750)
          // This covers the main GPU utilization metric
          const allPaths = this.pdhQuery.expandWildcard('\\GPU Engine(*)\\Utilization Percentage');
          let gpuAdded = 0;
          for (const p of allPaths) {
            if (p.includes('engtype_3D')) {
              const match = p.match(/\(([^)]+)\)/);
              const instance = match ? match[1] : String(gpuAdded);
              if (this.pdhQuery.addCounterLocalized(`gpu_3d.${instance}`, p)) {
                gpuAdded++;
              }
            }
          }
          this.pdhHasGpu = gpuAdded > 0;
        }

        if (this.config.network) {
          // Add per-adapter bytes received/sent
          const recvAdded = this.pdhQuery.addWildcardCounters('net_recv', '\\Network Interface(*)\\Bytes Received/sec');
          const sentAdded = this.pdhQuery.addWildcardCounters('net_sent', '\\Network Interface(*)\\Bytes Sent/sec');
          this.pdhHasNet = recvAdded > 0 || sentAdded > 0;
        }

        // Do an initial collect to prime the counters (first collect returns no data for rate counters)
        this.pdhQuery.collect();
      } catch (err) {
        console.error(`[winperf-sampler] PDH init failed: ${err instanceof Error ? err.message : String(err)}`);
        this.pdhQuery = null;
      }
    }

    // CPU temp via WMI (admin only)
    if (this.config.cpu && isAdmin()) {
      this.canReadCpuTemp = true;
      this.refreshCpuTemp();
    }

    // Detect nvidia-smi for GPU telemetry (temp, power, clocks)
    if (this.config.gpu) {
      try {
        this.refreshNvidiaSmi();
      } catch {
        // nvidia-smi not available
      }
    }

    this.initialized = true;
  }

  private refreshNvidiaSmi(): void {
    if (this.nvidiaSmiPending) return;
    this.nvidiaSmiPending = true;
    execFile(
      'nvidia-smi.exe',
      ['--query-gpu=temperature.gpu,power.draw,clocks.current.graphics,clocks.current.memory', '--format=csv,noheader,nounits'],
      { timeout: 2000, windowsHide: true },
      (err, stdout) => {
        this.nvidiaSmiPending = false;
        if (err || !stdout.trim()) return;
        const parts = stdout.trim().split(',').map(s => s.trim());
        if (parts.length >= 4) {
          this.nvidiaSmiAvailable = true;
          this.gpuTelemetry = {
            temp: parseFloat(parts[0]) || 0,
            power: parseFloat(parts[1]) || 0,
            clockGfx: parseFloat(parts[2]) || 0,
            clockMem: parseFloat(parts[3]) || 0,
          };
          this.lastNvidiaSmiTime = Date.now();
        }
      }
    );
  }

  private refreshCpuTemp(): void {
    if (this.cpuTempPending) return;
    this.cpuTempPending = true;
    execFile(
      'powershell.exe',
      ['-NoProfile', '-Command', '(Get-CimInstance MSAcpi_ThermalZoneTemperature -Namespace root/wmi -ErrorAction Stop | Select-Object -First 1).CurrentTemperature'],
      { timeout: 2000, windowsHide: true },
      (err, stdout) => {
        this.cpuTempPending = false;
        if (err || !stdout.trim()) return;
        const raw = parseInt(stdout.trim());
        if (!isNaN(raw) && raw > 0) {
          // Value is in tenths of Kelvin, convert to Celsius
          this.cpuTemp = Math.round((raw / 10 - 273.15) * 10) / 10;
          this.lastCpuTempTime = Date.now();
        }
      }
    );
  }

  sample(): NativeSample {
    if (!this.initialized) {
      throw new Error('Sampler not initialized. Call init() first.');
    }

    const result: NativeSample = {
      timestamp: Date.now(),
      cpu_percent: 0,
      memory_total_mb: 0,
      memory_used_mb: 0,
      memory_free_mb: 0,
      memory_used_percent: 0,
    };

    // CPU via os.cpus()
    if (this.config.cpu) {
      const cpus = os.cpus();
      const currTimes = cpus.map(c => c.times);
      const perCore: number[] = [];

      for (let i = 0; i < currTimes.length; i++) {
        const prev = this.prevCpuTimes[i];
        const curr = currTimes[i];
        if (!prev) continue;

        const totalDelta =
          (curr.user - prev.user) +
          (curr.nice - prev.nice) +
          (curr.sys - prev.sys) +
          (curr.idle - prev.idle) +
          (curr.irq - prev.irq);
        const idleDelta = curr.idle - prev.idle;
        const pct = totalDelta > 0 ? ((totalDelta - idleDelta) / totalDelta) * 100 : 0;
        perCore.push(Math.round(pct * 10) / 10);
      }

      this.prevCpuTimes = currTimes;
      result.cpu_percent = perCore.length > 0
        ? Math.round((perCore.reduce((a, b) => a + b, 0) / perCore.length) * 10) / 10
        : 0;

      if (this.config.cpuPerCore) {
        result.cpu_per_core = perCore;
      }
    }

    // Memory via os module
    if (this.config.memory) {
      const totalBytes = os.totalmem();
      const freeBytes = os.freemem();
      const usedBytes = totalBytes - freeBytes;
      result.memory_total_mb = Math.round(totalBytes / (1024 * 1024));
      result.memory_used_mb = Math.round(usedBytes / (1024 * 1024));
      result.memory_free_mb = Math.round(freeBytes / (1024 * 1024));
      result.memory_used_percent = Math.round((usedBytes / totalBytes) * 1000) / 10;
    }

    // PDH counters (disk, GPU, network, interrupts)
    if (this.pdhQuery) {
      this.pdhQuery.collect();
      const values = this.pdhQuery.getValues();

      if (this.pdhHasInterrupts) {
        result.cpu_interrupts_sec = Math.round(values['cpu.interrupts_sec'] ?? 0);
      }

      // CPU temp (cached, refreshed every ~1s)
      if (this.canReadCpuTemp && this.cpuTemp !== null) {
        result.cpu_temp_c = this.cpuTemp;
        if (Date.now() - this.lastCpuTempTime > 1000) {
          this.refreshCpuTemp();
        }
      }

      if (this.pdhHasDisk) {
        result.disk_read_bytes_sec = Math.round(values['disk.read_bytes_sec'] ?? 0);
        result.disk_write_bytes_sec = Math.round(values['disk.write_bytes_sec'] ?? 0);
        result.disk_idle_percent = Math.round((values['disk.idle_percent'] ?? 0) * 10) / 10;
        result.disk_queue_length = Math.round(values['disk.queue_length'] ?? 0);
      }

      if (this.pdhHasGpu) {
        let gpuTotal = 0;
        for (const [key, value] of Object.entries(values)) {
          if (key.startsWith('gpu_3d.') && value > 0) {
            gpuTotal += value;
          }
        }
        result.gpu_3d_percent = Math.round(Math.min(gpuTotal, 100) * 10) / 10;
      }

      // GPU telemetry from nvidia-smi (cached, refreshed every ~1s)
      if (this.nvidiaSmiAvailable && this.gpuTelemetry) {
        result.gpu_temp_c = this.gpuTelemetry.temp;
        result.gpu_power_w = this.gpuTelemetry.power;
        result.gpu_clock_mhz = this.gpuTelemetry.clockGfx;
        result.gpu_mem_clock_mhz = this.gpuTelemetry.clockMem;
        // Refresh nvidia-smi if stale (>1s)
        if (Date.now() - this.lastNvidiaSmiTime > 1000) {
          this.refreshNvidiaSmi();
        }
      }

      if (this.pdhHasNet) {
        // Sum all adapter recv/sent
        let totalRecv = 0;
        let totalSent = 0;
        for (const [key, value] of Object.entries(values)) {
          if (key.startsWith('net_recv.')) totalRecv += value;
          if (key.startsWith('net_sent.')) totalSent += value;
        }
        result.net_recv_bytes_sec = Math.round(totalRecv);
        result.net_sent_bytes_sec = Math.round(totalSent);
      }
    }

    return result;
  }

  destroy(): void {
    if (this.pdhQuery) {
      this.pdhQuery.close();
      this.pdhQuery = null;
    }
    this.initialized = false;
  }
}
