import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { writeFileSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { stopRecording, samplesToCSV, getRecordingStatus, getLastRecording } from '../recorder.js';

function generateHTML(csv: string, summaryText: string): string {
  // Parse CSV to get headers and data
  const lines = csv.trim().split('\n');
  const headers = lines[0].split(',');
  const rows = lines.slice(1).map(line => {
    const vals = line.split(',');
    return headers.reduce((obj, h, i) => {
      obj[h] = vals[i] ?? '';
      return obj;
    }, {} as Record<string, string>);
  });

  // Identify metric groups for charting
  const numericCols = headers.filter(h => {
    if (h === 'timestamp') return false;
    if (h.endsWith('_app') || h.endsWith('_pid')) return false;
    return rows.some(r => !isNaN(parseFloat(r[h])));
  });

  // Group into chart panels
  const chartGroups: { title: string; cols: string[]; yLabel: string }[] = [];

  const cpuPctCols = numericCols.filter(c => c === 'cpu_percent');
  if (cpuPctCols.length) chartGroups.push({ title: 'CPU Usage', cols: cpuPctCols, yLabel: '%' });

  const cpuIntCols = numericCols.filter(c => c === 'cpu_interrupts_sec');
  if (cpuIntCols.length) chartGroups.push({ title: 'CPU Interrupts', cols: cpuIntCols, yLabel: '/sec' });

  const memCols = numericCols.filter(c => c.startsWith('memory') && c.includes('percent'));
  if (memCols.length) chartGroups.push({ title: 'Memory Usage', cols: memCols, yLabel: '%' });

  const memMbCols = numericCols.filter(c => c.startsWith('memory') && c.includes('_mb') && !c.includes('total'));
  if (memMbCols.length) chartGroups.push({ title: 'Memory (MB)', cols: memMbCols, yLabel: 'MB' });

  const diskCols = numericCols.filter(c => c.startsWith('disk') && !c.includes('idle') && !c.includes('queue'));
  if (diskCols.length) chartGroups.push({ title: 'Disk Throughput', cols: diskCols, yLabel: 'bytes/sec' });

  const diskOtherCols = numericCols.filter(c => (c.includes('disk_idle') || c.includes('disk_queue')));
  if (diskOtherCols.length) chartGroups.push({ title: 'Disk Health', cols: diskOtherCols, yLabel: '' });

  const gpuUtilCols = numericCols.filter(c => c === 'gpu_3d_percent');
  if (gpuUtilCols.length) chartGroups.push({ title: 'GPU Utilization', cols: gpuUtilCols, yLabel: '%' });

  const gpuTempCols = numericCols.filter(c => c === 'gpu_temp_c' || c === 'cpu_temp_c');
  if (gpuTempCols.length) chartGroups.push({ title: 'Temperature', cols: gpuTempCols, yLabel: '°C' });

  const gpuPowerCols = numericCols.filter(c => c === 'gpu_power_w');
  if (gpuPowerCols.length) chartGroups.push({ title: 'GPU Power', cols: gpuPowerCols, yLabel: 'W' });

  const gpuClockCols = numericCols.filter(c => c === 'gpu_clock_mhz' || c === 'gpu_mem_clock_mhz');
  if (gpuClockCols.length) chartGroups.push({ title: 'GPU Clocks', cols: gpuClockCols, yLabel: 'MHz' });

  const netCols = numericCols.filter(c => c.startsWith('net'));
  if (netCols.length) chartGroups.push({ title: 'Network', cols: netCols, yLabel: 'bytes/sec' });

  // FPS columns: fps_Wow, fps_Chrome etc. (start with fps_ but don't have a second underscore suffix)
  const fpsFpsCols = numericCols.filter(c => c.startsWith('fps_') && !c.includes('_frame_time_ms') && !c.includes('_cpu_busy_ms') && !c.includes('_gpu_busy_ms'));
  if (fpsFpsCols.length) chartGroups.push({ title: 'FPS', cols: fpsFpsCols, yLabel: 'FPS' });

  const fpsTimingCols = numericCols.filter(c => c.startsWith('fps_') && (c.endsWith('_frame_time_ms') || c.endsWith('_cpu_busy_ms') || c.endsWith('_gpu_busy_ms')));
  if (fpsTimingCols.length) chartGroups.push({ title: 'Frame Timing', cols: fpsTimingCols, yLabel: 'ms' });

  // Any remaining columns
  const usedCols = new Set(chartGroups.flatMap(g => g.cols));
  const otherCols = numericCols.filter(c => !usedCols.has(c));
  if (otherCols.length) chartGroups.push({ title: 'Other Metrics', cols: otherCols, yLabel: '' });

  // Build timestamps array
  const timestamps = rows.map(r => r.timestamp);

  // Color palette
  const colors = [
    '#3b82f6', '#ef4444', '#22c55e', '#f59e0b', '#8b5cf6',
    '#ec4899', '#06b6d4', '#f97316', '#14b8a6', '#6366f1',
  ];

  const chartConfigs = chartGroups.map((group, idx) => {
    const datasets = group.cols.map((col, ci) => ({
      label: col,
      data: rows.map(r => parseFloat(r[col]) || 0),
      borderColor: colors[ci % colors.length],
      backgroundColor: colors[ci % colors.length] + '20',
      borderWidth: 1.5,
      pointRadius: 0,
      tension: 0.3,
      fill: group.cols.length === 1,
    }));

    return { id: `chart${idx}`, title: group.title, yLabel: group.yLabel, datasets };
  });

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>WinPerf Recording Dashboard</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4"></script>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #0f172a; color: #e2e8f0; padding: 20px; }
  h1 { font-size: 1.5rem; margin-bottom: 4px; color: #f8fafc; }
  .subtitle { color: #94a3b8; font-size: 0.85rem; margin-bottom: 20px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(600px, 1fr)); gap: 16px; }
  .card { background: #1e293b; border-radius: 8px; padding: 16px; }
  .card h2 { font-size: 0.95rem; color: #94a3b8; margin-bottom: 8px; }
  canvas { width: 100% !important; }
  .summary { background: #1e293b; border-radius: 8px; padding: 16px; margin-bottom: 16px; }
  .summary pre { font-size: 0.8rem; color: #cbd5e1; white-space: pre-wrap; overflow-x: auto; }
  .summary h2 { font-size: 0.95rem; color: #94a3b8; margin-bottom: 8px; }
  @media (max-width: 700px) { .grid { grid-template-columns: 1fr; } }
</style>
</head>
<body>
<h1>WinPerf Recording Dashboard</h1>
<div class="subtitle">${rows.length} samples | ${timestamps[0]} to ${timestamps[timestamps.length - 1]}</div>

<div class="summary"><h2>Summary Statistics</h2><pre>${summaryText}</pre></div>

<div class="grid">
${chartConfigs.map(c => `  <div class="card"><h2>${c.title}</h2><canvas id="${c.id}"></canvas></div>`).join('\n')}
</div>

<script>
const timestamps = ${JSON.stringify(timestamps)};
const chartOptions = (yLabel) => ({
  responsive: true,
  animation: false,
  interaction: { mode: 'index', intersect: false },
  plugins: { legend: { labels: { color: '#94a3b8', font: { size: 11 } } } },
  scales: {
    x: { ticks: { color: '#64748b', font: { size: 10 }, maxTicksLimit: 20, maxRotation: 45 },
         grid: { color: '#334155' } },
    y: { ticks: { color: '#64748b' }, grid: { color: '#334155' },
         title: { display: !!yLabel, text: yLabel, color: '#94a3b8' } }
  }
});

${chartConfigs.map(c => `
new Chart(document.getElementById('${c.id}'), {
  type: 'line',
  data: { labels: timestamps.map(t => new Date(t).toLocaleTimeString()), datasets: ${JSON.stringify(c.datasets)} },
  options: chartOptions('${c.yLabel}')
});`).join('\n')}
</script>
</body>
</html>`;
}

function buildDashboard(
  samples: import('../recorder.js').RecordingSample[],
  summary: { durationSeconds: number; sampleCount: number; startTime: string; endTime: string; metrics: Record<string, { min: number; max: number; avg: number; p95: number; anomalies: string[] }> },
  outputPath?: string,
): { filePath: string; sampleCount: number } {
  const csv = samplesToCSV(samples);

  let summaryText = '';
  const lines: string[] = [];
  lines.push(`Duration: ${summary.durationSeconds}s | Samples: ${summary.sampleCount}`);
  lines.push('');
  lines.push('Metric                        Min        Max        Avg        P95');
  lines.push('─'.repeat(75));
  for (const [key, s] of Object.entries(summary.metrics)) {
    const name = key.padEnd(30);
    lines.push(`${name}${String(s.min).padStart(10)} ${String(s.max).padStart(10)} ${String(s.avg).padStart(10)} ${String(s.p95).padStart(10)}`);
  }
  summaryText = lines.join('\n');

  const html = generateHTML(csv, summaryText);
  const filePath = outputPath || path.join(os.tmpdir(), `winperf-${Date.now()}.html`);
  writeFileSync(filePath, html, 'utf-8');

  // Open in browser
  import('node:child_process').then(({ exec }) => exec(`start "" "${filePath}"`));

  return { filePath, sampleCount: samples.length };
}

export function registerVisualizeTools(server: McpServer) {
  server.registerTool(
    'stop_recording_and_visualize',
    {
      description:
        'Stop the active recording and generate an interactive HTML dashboard with charts for all recorded metrics. Opens in the default browser. The recording data is preserved and can be re-visualized later.',
      inputSchema: {
        output_path: z
          .string()
          .optional()
          .describe('Output HTML file path. Defaults to a temp file.'),
      },
    },
    async ({ output_path }) => {
      const status = getRecordingStatus();
      if (!status.active) {
        // Try the last recording instead
        const last = getLastRecording();
        if (!last) {
          return {
            content: [{ type: 'text' as const, text: 'No active or previous recording found.' }],
          };
        }
        const { filePath, sampleCount } = buildDashboard(last.samples, last.summary, output_path);
        return {
          content: [{
            type: 'text' as const,
            text: `Visualized previous recording (${sampleCount} samples).\nDashboard saved to: ${filePath}\nOpened in default browser.`,
          }],
        };
      }

      const result = stopRecording();
      if (result.samples.length === 0) {
        return {
          content: [{ type: 'text' as const, text: 'Recording stopped but no samples were collected.' }],
        };
      }

      const { filePath, sampleCount } = buildDashboard(result.samples, result.summary!, output_path);
      return {
        content: [{
          type: 'text' as const,
          text: `Recording stopped. ${sampleCount} samples collected.\nDashboard saved to: ${filePath}\nOpened in default browser.`,
        }],
      };
    },
  );

  server.registerTool(
    'visualize_recording',
    {
      description:
        'Generate an interactive HTML dashboard from CSV recording data or from the last recording. If csv_data is provided, it is visualized directly. Otherwise, the most recent recording is used. Opens the dashboard in the default browser.',
      inputSchema: {
        csv_data: z
          .string()
          .optional()
          .describe('Raw CSV data to visualize (timestamp column + metric columns). If omitted, uses the last recording.'),
        output_path: z
          .string()
          .optional()
          .describe('Output HTML file path. Defaults to a temp file.'),
      },
    },
    async ({ csv_data, output_path }) => {
      if (csv_data) {
        // Visualize arbitrary CSV
        const html = generateHTML(csv_data, '');
        const filePath = output_path || path.join(os.tmpdir(), `winperf-${Date.now()}.html`);
        writeFileSync(filePath, html, 'utf-8');
        import('node:child_process').then(({ exec }) => exec(`start "" "${filePath}"`));
        const rowCount = csv_data.trim().split('\n').length - 1;
        return {
          content: [{
            type: 'text' as const,
            text: `Dashboard generated from ${rowCount} rows of CSV data.\nSaved to: ${filePath}\nOpened in default browser.`,
          }],
        };
      }

      // Fall back to last recording
      const last = getLastRecording();
      if (!last) {
        return {
          content: [{ type: 'text' as const, text: 'No recording data available. Provide csv_data or run a recording first.' }],
        };
      }

      const { filePath, sampleCount } = buildDashboard(last.samples, last.summary, output_path);
      return {
        content: [{
          type: 'text' as const,
          text: `Visualized last recording (${sampleCount} samples).\nDashboard saved to: ${filePath}\nOpened in default browser.`,
        }],
      };
    },
  );
}
