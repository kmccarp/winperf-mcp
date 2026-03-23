import { spawn, type ChildProcess } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { existsSync } from 'node:fs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const VENDOR_DIR = path.resolve(__dirname, '..', '..', 'vendor');
const PRESENTMON_EXE = path.join(VENDOR_DIR, 'PresentMon.exe');

export interface FrameEvent {
  application: string;
  processId: number;
  timestampMs: number;
  msBetweenPresents: number;
  msCpuBusy: number;
  msGpuBusy: number;
  msGpuLatency: number;
  presentMode: string;
  fps: number;
}

export interface AppFpsSummary {
  application: string;
  processId: number;
  frameCount: number;
  avgFps: number;
  minFps: number;
  maxFps: number;
  p1Fps: number;
  p5Fps: number;
  avgFrameTimeMs: number;
  avgCpuBusyMs: number;
  avgGpuBusyMs: number;
  presentMode: string;
}

// Column indices (parsed from header)
let COL: Record<string, number> = {};

function parseHeader(line: string): void {
  const cols = line.split(',');
  COL = {};
  for (let i = 0; i < cols.length; i++) {
    COL[cols[i].trim()] = i;
  }
}

function parseLine(line: string): FrameEvent | null {
  const cols = line.split(',');
  if (cols.length < 10) return null;

  const msBetween = parseFloat(cols[COL['MsBetweenPresents']]);
  if (isNaN(msBetween) || msBetween <= 0) return null;

  return {
    application: cols[COL['Application']] || '<unknown>',
    processId: parseInt(cols[COL['ProcessID']]) || 0,
    timestampMs: parseFloat(cols[COL['TimeInMs']]) || 0,
    msBetweenPresents: msBetween,
    msCpuBusy: parseFloat(cols[COL['MsCPUBusy']]) || 0,
    msGpuBusy: parseFloat(cols[COL['MsGPUBusy']]) || 0,
    msGpuLatency: parseFloat(cols[COL['MsGPULatency']]) || 0,
    presentMode: cols[COL['PresentMode']] || '',
    fps: 1000 / msBetween,
  };
}

function computeSummary(frames: FrameEvent[]): AppFpsSummary[] {
  // Group by application + processId
  const groups = new Map<string, FrameEvent[]>();
  for (const f of frames) {
    const key = `${f.application}|${f.processId}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key)!.push(f);
  }

  const summaries: AppFpsSummary[] = [];
  for (const [, appFrames] of groups) {
    if (appFrames.length < 2) continue;

    const fpsValues = appFrames.map(f => f.fps).sort((a, b) => a - b);
    const frameTimeValues = appFrames.map(f => f.msBetweenPresents);
    const cpuBusyValues = appFrames.map(f => f.msCpuBusy);
    const gpuBusyValues = appFrames.map(f => f.msGpuBusy);

    const avg = (arr: number[]) => arr.reduce((a, b) => a + b, 0) / arr.length;
    const percentile = (sorted: number[], p: number) => {
      const idx = Math.max(0, Math.ceil((p / 100) * sorted.length) - 1);
      return sorted[idx];
    };

    summaries.push({
      application: appFrames[0].application,
      processId: appFrames[0].processId,
      frameCount: appFrames.length,
      avgFps: Math.round(avg(fpsValues) * 10) / 10,
      minFps: Math.round(fpsValues[0] * 10) / 10,
      maxFps: Math.round(fpsValues[fpsValues.length - 1] * 10) / 10,
      p1Fps: Math.round(percentile(fpsValues, 1) * 10) / 10,
      p5Fps: Math.round(percentile(fpsValues, 5) * 10) / 10,
      avgFrameTimeMs: Math.round(avg(frameTimeValues) * 100) / 100,
      avgCpuBusyMs: Math.round(avg(cpuBusyValues) * 100) / 100,
      avgGpuBusyMs: Math.round(avg(gpuBusyValues) * 100) / 100,
      presentMode: appFrames[0].presentMode,
    });
  }

  return summaries.sort((a, b) => b.avgFps - a.avgFps);
}

export function isPresentMonAvailable(): boolean {
  return existsSync(PRESENTMON_EXE);
}

/**
 * Capture FPS data for a specified duration and return per-app summaries.
 */
export function captureFps(durationSeconds: number = 3): Promise<{
  summaries: AppFpsSummary[];
  totalFrames: number;
  durationSeconds: number;
}> {
  return new Promise((resolve, reject) => {
    if (!isPresentMonAvailable()) {
      reject(new Error(`PresentMon not found at ${PRESENTMON_EXE}`));
      return;
    }

    const child = spawn(PRESENTMON_EXE, [
      '--output_stdout',
      '--timed', String(durationSeconds),
      '--no_console_stats',
      '--stop_existing_session',
    ], {
      stdio: ['pipe', 'pipe', 'pipe'],
      windowsHide: true,
    });

    const frames: FrameEvent[] = [];
    let headerParsed = false;
    let buffer = '';

    child.stdout.on('data', (chunk: Buffer) => {
      buffer += chunk.toString();
      const lines = buffer.split('\n');
      buffer = lines.pop() || ''; // Keep incomplete line in buffer

      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed) continue;

        if (!headerParsed) {
          if (trimmed.startsWith('Application,')) {
            parseHeader(trimmed);
            headerParsed = true;
          }
          continue;
        }

        const frame = parseLine(trimmed);
        if (frame) frames.push(frame);
      }
    });

    child.stderr.on('data', () => {}); // Suppress warnings

    child.on('close', () => {
      // Process remaining buffer
      if (buffer.trim() && headerParsed) {
        const frame = parseLine(buffer.trim());
        if (frame) frames.push(frame);
      }

      resolve({
        summaries: computeSummary(frames),
        totalFrames: frames.length,
        durationSeconds,
      });
    });

    child.on('error', (err) => {
      reject(new Error(`PresentMon failed: ${err.message}`));
    });

    // Safety timeout
    setTimeout(() => {
      child.kill();
    }, (durationSeconds + 5) * 1000);
  });
}

/**
 * PresentMon streaming capture for use during recording.
 * Starts PresentMon and calls onFrames() with batched frame events at the given interval.
 */
export class PresentMonStream {
  private child: ChildProcess | null = null;
  private frames: FrameEvent[] = [];
  private headerParsed = false;
  private buffer = '';
  private flushInterval: ReturnType<typeof setInterval> | null = null;
  private _onSnapshot: ((summary: AppFpsSummary[]) => void) | null = null;

  start(snapshotIntervalMs: number = 1000): boolean {
    if (!isPresentMonAvailable()) return false;

    this.child = spawn(PRESENTMON_EXE, [
      '--output_stdout',
      '--no_console_stats',
      '--stop_existing_session',
    ], {
      stdio: ['pipe', 'pipe', 'pipe'],
      windowsHide: true,
    });

    this.child.stdout!.on('data', (chunk: Buffer) => {
      this.buffer += chunk.toString();
      const lines = this.buffer.split('\n');
      this.buffer = lines.pop() || '';

      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed) continue;

        if (!this.headerParsed) {
          if (trimmed.startsWith('Application,')) {
            parseHeader(trimmed);
            this.headerParsed = true;
          }
          continue;
        }

        const frame = parseLine(trimmed);
        if (frame) this.frames.push(frame);
      }
    });

    this.child.stderr!.on('data', () => {});
    this.child.on('error', () => {});

    // Periodically flush accumulated frames into snapshots
    this.flushInterval = setInterval(() => {
      if (this.frames.length > 0 && this._onSnapshot) {
        const summary = computeSummary(this.frames);
        this.frames = [];
        this._onSnapshot(summary);
      }
    }, snapshotIntervalMs);

    return true;
  }

  onSnapshot(callback: (summary: AppFpsSummary[]) => void): void {
    this._onSnapshot = callback;
  }

  stop(): AppFpsSummary[] {
    if (this.flushInterval) {
      clearInterval(this.flushInterval);
      this.flushInterval = null;
    }

    // Final summary from remaining frames
    const finalSummary = computeSummary(this.frames);
    this.frames = [];

    if (this.child) {
      this.child.kill();
      this.child = null;
    }

    this.headerParsed = false;
    this.buffer = '';

    return finalSummary;
  }
}
