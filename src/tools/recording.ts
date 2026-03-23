import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { startRecording, stopRecording, getRecordingStatus, samplesToCSV } from '../recorder.js';

export function registerRecordingTools(server: McpServer) {
  server.registerTool(
    'start_recording',
    {
      description:
        'Begin high-frequency background recording of system metrics using native OS APIs (not PowerShell). Samples CPU, memory, disk, GPU, and network data. Supports intervals as low as 50ms for near-real-time capture. Only one recording can be active at a time.',
      inputSchema: {
        metrics: z
          .array(z.string())
          .optional()
          .default(['cpu', 'memory', 'disk', 'gpu', 'network', 'fps'])
          .describe('Which metrics to sample: cpu, memory, disk, gpu, network, fps'),
        interval_ms: z
          .number()
          .min(50)
          .max(60000)
          .optional()
          .default(1000)
          .describe('Sampling interval in milliseconds (min 50ms for high-frequency)'),
        max_duration_minutes: z
          .number()
          .min(1)
          .max(120)
          .optional()
          .default(30)
          .describe('Auto-stop after this many minutes'),
      },
    },
    async ({ metrics, interval_ms, max_duration_minutes }) => {
      const result = startRecording({
        metrics,
        intervalMs: interval_ms,
        maxDurationMinutes: max_duration_minutes,
      });
      return {
        content: [{ type: 'text' as const, text: JSON.stringify(result, null, 2) }],
      };
    },
  );

  server.registerTool(
    'stop_recording',
    {
      description:
        'Stop the active recording and return results with time-series data and computed summaries (min/max/avg/p95 per metric) plus anomaly highlights.',
      inputSchema: {
        include_raw_samples: z
          .boolean()
          .optional()
          .default(true)
          .describe('Include raw time-series sample data'),
        include_summary: z
          .boolean()
          .optional()
          .default(true)
          .describe('Include computed summary statistics'),
      },
    },
    async ({ include_raw_samples, include_summary }) => {
      const result = stopRecording();
      const parts: string[] = [];

      parts.push(`${result.message}`);

      if (include_summary && result.summary) {
        parts.push(`\n## Summary (${result.summary.startTime} to ${result.summary.endTime}, ${result.summary.sampleCount} samples)\n`);
        parts.push('metric,min,max,avg,p95');
        for (const [key, stats] of Object.entries(result.summary.metrics)) {
          parts.push(`${key},${stats.min},${stats.max},${stats.avg},${stats.p95}`);
        }
        // Anomalies
        const allAnomalies = Object.values(result.summary.metrics).flatMap(s => s.anomalies);
        if (allAnomalies.length > 0) {
          parts.push(`\n## Anomalies (${allAnomalies.length})\n`);
          for (const a of allAnomalies) {
            parts.push(a);
          }
        }
      }

      if (include_raw_samples && result.samples.length > 0) {
        parts.push('\n## Samples\n');
        parts.push(samplesToCSV(result.samples));
      }

      return {
        content: [{ type: 'text' as const, text: parts.join('\n') }],
      };
    },
  );

  server.registerTool(
    'get_recording_status',
    {
      description:
        'Check if a performance recording is currently active, how long it has been running, sample count, effective samples/sec, and which metrics are being tracked.',
      inputSchema: {},
    },
    async () => {
      const result = getRecordingStatus();
      return {
        content: [{ type: 'text' as const, text: JSON.stringify(result, null, 2) }],
      };
    },
  );
}
