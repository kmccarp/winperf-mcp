# winperf-mcp

MCP server for troubleshooting Windows performance issues with Claude Code.

Provides 24 tools covering real-time system metrics, per-app FPS capture, high-frequency recording with visualization, and deep-dive diagnostics — all accessible as MCP tools from Claude Code.

## Setup

```bash
npm install   # installs deps + downloads PresentMon for FPS capture
npm run build
```

Add to your Claude Code config:

```bash
claude mcp add --scope user winperf -- node /path/to/winperf-mcp/dist/index.js
```

## Tools

### System Metrics (PowerShell-backed, point-in-time)

| Tool | Description |
|------|-------------|
| `get_system_info` | OS version, hostname, uptime, CPU/GPU/BIOS/motherboard/RAM hardware |
| `get_cpu_metrics` | Per-core utilization, clock speeds, temperature, context switches, interrupts |
| `get_memory_metrics` | Usage, page faults, pools, top processes by memory |
| `get_disk_metrics` | Per-disk IOPS, throughput, latency, SMART health, SSD wear |
| `get_gpu_metrics` | Utilization by engine, VRAM, temperature, clocks, per-process GPU usage |
| `get_network_metrics` | Bandwidth, connections, Wi-Fi signal, firewall rules, DNS latency |
| `get_process_list` | Sorted/filtered process list with CPU%, memory, disk I/O, GPU% |
| `get_process_detail` | Deep dive: threads, handles, DLLs, network, GDI objects, crash history |
| `get_event_logs` | Filterable event logs with presets (BSOD, disk errors, app crashes) |
| `get_services` | Service list with status, startup type, dependencies |
| `get_startup_items` | Startup programs + scheduled tasks |
| `get_windows_update` | Pending/installed updates, WU service state |
| `get_power_thermal` | Power plan, battery health, thermal throttling, sleep config |
| `get_installed_software` | Programs list (fast registry scan), driver signing status |
| `query_perf_counter` | Arbitrary Windows Performance Counter queries |
| `query_wmi` | Arbitrary read-only WMI/CIM queries |
| `analyze_filesystem` | Large file finder, directory sizes, temp file accumulation |
| `read_registry` | Registry reads with presets for performance-related keys |

### FPS Capture (PresentMon)

| Tool | Description |
|------|-------------|
| `get_fps_metrics` | Per-app FPS (avg/min/p1/p5), frame times, CPU/GPU busy time |

### Recording System (Native, high-frequency)

| Tool | Description |
|------|-------------|
| `start_recording` | Begin sampling at up to 50ms intervals (CPU, memory, disk, GPU, network, FPS) |
| `stop_recording` | Stop and return CSV data with summary stats and anomaly detection |
| `get_recording_status` | Check active recording: duration, sample count, samples/sec |
| `stop_recording_and_visualize` | Stop recording and open interactive HTML dashboard in browser |
| `visualize_recording` | Generate dashboard from last recording or arbitrary CSV data |

## Architecture

```
Claude Code <-> STDIO <-> MCP Server (Node.js)
                              |
              +---------------+---------------+
              |               |               |
         os.cpus()      PDH via FFI     PowerShell
         os.freemem()   (koffi)         (spawn)
              |               |               |
         CPU + Memory    Disk IOPS       Deep-dive
         (<0.1ms)        GPU %           tools
                         Network         (~1-8s)
                         Interrupts
                         (<10ms)
              |
         nvidia-smi          PresentMon
         (async, 1s cache)   (streaming)
              |                    |
         GPU temp/power       Per-app FPS
         GPU clocks           Frame timing
```

### Recording performance

The native sampler uses `os.cpus()` + PDH FFI (via koffi) + async nvidia-smi, achieving ~16ms per sample with all metrics. This supports intervals as low as 50ms for near-real-time capture.

| Source | Metrics | Time |
|--------|---------|------|
| `os.cpus()` | CPU % per core | <0.1ms |
| `os.freemem()` | Memory usage | <0.1ms |
| PDH (`pdh.dll`) | Disk, GPU %, network, interrupts | ~10ms |
| `nvidia-smi` | GPU temp, power, clocks | async, 1s cache |
| PresentMon | Per-app FPS, frame timing | streaming, 1s snapshots |
| WMI (admin) | CPU temperature | async, 1s cache |

### Recordings

Recordings are saved to `recordings/` as JSON files and persist across server restarts. The `visualize_recording` tool can re-visualize any previous recording.

## Requirements

- Windows 10/11
- Node.js 18+
- PowerShell 5.1+ (included with Windows)
- NVIDIA GPU (optional, for GPU temp/power/clocks via nvidia-smi)
- Admin privileges (optional, for CPU temperature via WMI thermal zone)

## License

MIT
