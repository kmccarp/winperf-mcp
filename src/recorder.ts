import { NativeSampler } from './native/sampler.js';
import { PresentMonStream, isPresentMonAvailable, type AppFpsSummary } from './native/presentmon.js';
import { writeFileSync, readFileSync, mkdirSync, readdirSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const RECORDINGS_DIR = path.resolve(__dirname, '..', 'recordings');

export interface RecordingConfig {
  metrics: string[];
  intervalMs: number;
  maxDurationMinutes: number;
}

export interface RecordingSample {
  timestamp: string;
  data: Record<string, unknown>;
}

interface RecordingState {
  active: boolean;
  config: RecordingConfig | null;
  startTime: Date | null;
  samples: RecordingSample[];
  intervalHandle: ReturnType<typeof setInterval> | null;
  autoStopHandle: ReturnType<typeof setTimeout> | null;
  sampler: NativeSampler | null;
  fpsStream: PresentMonStream | null;
  latestFps: AppFpsSummary[];
}

const MAX_SAMPLES = 100_000;

interface CompletedRecording {
  samples: RecordingSample[];
  summary: RecordingSummary;
}

// Ensure recordings directory exists
if (!existsSync(RECORDINGS_DIR)) {
  mkdirSync(RECORDINGS_DIR, { recursive: true });
}

function saveRecording(recording: CompletedRecording): string {
  const filename = `recording-${new Date().toISOString().replace(/[:.]/g, '-')}.json`;
  const filePath = path.join(RECORDINGS_DIR, filename);
  writeFileSync(filePath, JSON.stringify(recording), 'utf-8');
  return filePath;
}

function loadLatestRecording(): CompletedRecording | null {
  try {
    if (!existsSync(RECORDINGS_DIR)) return null;
    const files = readdirSync(RECORDINGS_DIR)
      .filter(f => f.startsWith('recording-') && f.endsWith('.json'))
      .sort()
      .reverse();
    if (files.length === 0) return null;
    const data = readFileSync(path.join(RECORDINGS_DIR, files[0]), 'utf-8');
    return JSON.parse(data) as CompletedRecording;
  } catch {
    return null;
  }
}

const state: RecordingState = {
  active: false,
  config: null,
  startTime: null,
  samples: [],
  intervalHandle: null,
  autoStopHandle: null,
  sampler: null,
  fpsStream: null,
  latestFps: [],
};

function collectSample(): void {
  if (!state.active || !state.sampler) return;
  if (state.samples.length >= MAX_SAMPLES) {
    stopRecording();
    return;
  }

  try {
    const sample = state.sampler.sample();
    const data: Record<string, unknown> = { ...sample };
    delete data.timestamp;

    // Attach latest FPS snapshot if available
    if (state.latestFps.length > 0) {
      data.fps = state.latestFps.map(s => ({
        app: s.application,
        pid: s.processId,
        fps: s.avgFps,
        frame_time_ms: s.avgFrameTimeMs,
        cpu_busy_ms: s.avgCpuBusyMs,
        gpu_busy_ms: s.avgGpuBusyMs,
      }));
    }

    state.samples.push({
      timestamp: new Date(sample.timestamp).toISOString(),
      data,
    });
  } catch (err) {
    console.error(`[winperf-recorder] Sample failed: ${err instanceof Error ? err.message : String(err)}`);
  }
}

export function startRecording(config: RecordingConfig): { success: boolean; message: string } {
  if (state.active) {
    return { success: false, message: 'A recording is already in progress. Stop it first.' };
  }

  state.active = true;
  state.config = config;
  state.startTime = new Date();
  state.samples = [];

  const sampler = new NativeSampler({
    cpu: config.metrics.includes('cpu'),
    memory: config.metrics.includes('memory'),
    disk: config.metrics.includes('disk'),
    gpu: config.metrics.includes('gpu'),
    network: config.metrics.includes('network'),
  });
  sampler.init();
  state.sampler = sampler;

  // Start FPS capture if requested and PresentMon is available
  const wantsFps = config.metrics.includes('fps');
  if (wantsFps && isPresentMonAvailable()) {
    const fpsStream = new PresentMonStream();
    const started = fpsStream.start(Math.max(config.intervalMs, 1000));
    if (started) {
      fpsStream.onSnapshot((summary) => {
        state.latestFps = summary;
      });
      state.fpsStream = fpsStream;
    }
  }

  // First sample immediately
  collectSample();

  // Set up interval
  state.intervalHandle = setInterval(collectSample, config.intervalMs);

  // Auto-stop after max duration
  state.autoStopHandle = setTimeout(
    () => stopRecording(),
    config.maxDurationMinutes * 60 * 1000
  );

  const intervalLabel = config.intervalMs >= 1000
    ? `${config.intervalMs / 1000}s`
    : `${config.intervalMs}ms`;

  return {
    success: true,
    message: `Recording started. Sampling ${config.metrics.join(', ')} every ${intervalLabel} for up to ${config.maxDurationMinutes} minutes. Max ${MAX_SAMPLES} samples.`,
  };
}

export function stopRecording(): {
  success: boolean;
  message: string;
  summary: RecordingSummary | null;
  samples: RecordingSample[];
} {
  if (!state.active) {
    return { success: false, message: 'No recording is active.', summary: null, samples: [] };
  }

  if (state.intervalHandle) clearInterval(state.intervalHandle);
  if (state.autoStopHandle) clearTimeout(state.autoStopHandle);

  if (state.fpsStream) {
    state.fpsStream.stop();
    state.fpsStream = null;
    state.latestFps = [];
  }

  if (state.sampler) {
    state.sampler.destroy();
    state.sampler = null;
  }

  const samples = [...state.samples];
  const summary = computeSummary(samples, state.startTime!, new Date());

  // Save to disk so it survives restarts
  const recording = { samples, summary };
  try {
    saveRecording(recording);
  } catch (err) {
    console.error(`[winperf-recorder] Failed to save recording: ${err instanceof Error ? err.message : String(err)}`);
  }

  state.active = false;
  state.config = null;
  state.startTime = null;
  state.samples = [];
  state.intervalHandle = null;
  state.autoStopHandle = null;

  return {
    success: true,
    message: `Recording stopped. Collected ${samples.length} samples.`,
    summary,
    samples,
  };
}

export function getLastRecording(): CompletedRecording | null {
  return loadLatestRecording();
}

export function getRecordingStatus(): {
  active: boolean;
  durationSeconds: number | null;
  sampleCount: number;
  config: RecordingConfig | null;
  samplesPerSecond: number | null;
} {
  if (!state.active || !state.startTime) {
    return { active: false, durationSeconds: null, sampleCount: 0, config: null, samplesPerSecond: null };
  }

  const durationSeconds = Math.round((Date.now() - state.startTime.getTime()) / 1000);
  return {
    active: true,
    durationSeconds,
    sampleCount: state.samples.length,
    config: state.config,
    samplesPerSecond: durationSeconds > 0 ? Math.round(state.samples.length / durationSeconds) : null,
  };
}

interface MetricStats {
  min: number;
  max: number;
  avg: number;
  p95: number;
  anomalies: string[];
}

interface RecordingSummary {
  durationSeconds: number;
  sampleCount: number;
  startTime: string;
  endTime: string;
  metrics: Record<string, MetricStats>;
}

function computePercentile(sorted: number[], p: number): number {
  const idx = Math.ceil((p / 100) * sorted.length) - 1;
  return sorted[Math.max(0, idx)];
}

function computeSummary(
  samples: RecordingSample[],
  startTime: Date,
  endTime: Date
): RecordingSummary {
  const metrics: Record<string, number[]> = {};
  const metricTimestamps: Record<string, { value: number; timestamp: string }[]> = {};

  for (const sample of samples) {
    extractNumericMetrics(sample.data, '', metrics, metricTimestamps, sample.timestamp);
  }

  const stats: Record<string, MetricStats> = {};
  for (const [key, values] of Object.entries(metrics)) {
    if (values.length === 0) continue;
    if (key === 'cpu_per_core') continue;

    const sorted = [...values].sort((a, b) => a - b);
    const avg = values.reduce((a, b) => a + b, 0) / values.length;
    const min = sorted[0];
    const max = sorted[sorted.length - 1];
    const p95 = computePercentile(sorted, 95);

    const stdDev = Math.sqrt(values.reduce((sum, v) => sum + (v - avg) ** 2, 0) / values.length);
    const anomalies: string[] = [];
    if (stdDev > 0) {
      const entries = metricTimestamps[key] || [];
      for (const entry of entries) {
        if (Math.abs(entry.value - avg) > 2 * stdDev) {
          anomalies.push(`${key} = ${entry.value.toFixed(1)} at ${entry.timestamp}`);
        }
      }
      if (anomalies.length > 20) {
        anomalies.splice(20, anomalies.length - 20, `... and ${anomalies.length - 20} more`);
      }
    }

    stats[key] = { min, max, avg: Math.round(avg * 100) / 100, p95, anomalies };
  }

  return {
    durationSeconds: Math.round((endTime.getTime() - startTime.getTime()) / 1000),
    sampleCount: samples.length,
    startTime: startTime.toISOString(),
    endTime: endTime.toISOString(),
    metrics: stats,
  };
}

function extractNumericMetrics(
  obj: unknown,
  prefix: string,
  metrics: Record<string, number[]>,
  metricTimestamps: Record<string, { value: number; timestamp: string }[]>,
  timestamp: string
): void {
  if (obj === null || obj === undefined) return;
  if (typeof obj === 'number' && isFinite(obj)) {
    if (!metrics[prefix]) metrics[prefix] = [];
    if (!metricTimestamps[prefix]) metricTimestamps[prefix] = [];
    metrics[prefix].push(obj);
    metricTimestamps[prefix].push({ value: obj, timestamp });
    return;
  }
  if (typeof obj === 'object' && !Array.isArray(obj)) {
    for (const [key, value] of Object.entries(obj as Record<string, unknown>)) {
      const newPrefix = prefix ? `${prefix}.${key}` : key;
      extractNumericMetrics(value, newPrefix, metrics, metricTimestamps, timestamp);
    }
  }
}

/**
 * Flatten a sample's data into a flat key-value map.
 * Nested FPS array becomes columns like fps_1_app, fps_1_fps, fps_1_frame_time_ms, etc.
 */
function flattenSample(data: Record<string, unknown>): Record<string, string | number> {
  const flat: Record<string, string | number> = {};

  for (const [key, value] of Object.entries(data)) {
    if (key === 'fps' && Array.isArray(value)) {
      for (const entry of value) {
        const app = entry as Record<string, unknown>;
        // Strip .exe extension for cleaner column names
        const appName = String(app.app ?? 'unknown').replace(/\.exe$/i, '');
        flat[`fps_${appName}`] = Number(app.fps ?? 0);
        flat[`fps_${appName}_frame_time_ms`] = Number(app.frame_time_ms ?? 0);
        flat[`fps_${appName}_cpu_busy_ms`] = Number(app.cpu_busy_ms ?? 0);
        flat[`fps_${appName}_gpu_busy_ms`] = Number(app.gpu_busy_ms ?? 0);
      }
    } else if (typeof value === 'number' || typeof value === 'string') {
      flat[key] = value;
    }
  }

  return flat;
}

export function samplesToCSV(samples: RecordingSample[]): string {
  if (samples.length === 0) return '';

  // Flatten all samples to discover the full set of columns
  const flatSamples: Record<string, string | number>[] = samples.map(s => ({
    timestamp: s.timestamp,
    ...flattenSample(s.data),
  }));

  // Build column set from all samples (order: timestamp first, then sorted)
  const colSet = new Set<string>();
  for (const flat of flatSamples) {
    for (const key of Object.keys(flat)) {
      colSet.add(key);
    }
  }
  const cols = ['timestamp', ...([...colSet].filter(c => c !== 'timestamp').sort())];

  // Header row
  const lines: string[] = [cols.join(',')];

  // Data rows
  for (const flat of flatSamples) {
    const row = cols.map(col => {
      const val = flat[col];
      if (val === undefined || val === null) return '';
      if (typeof val === 'string' && val.includes(',')) return `"${val}"`;
      return String(val);
    });
    lines.push(row.join(','));
  }

  return lines.join('\n');
}
