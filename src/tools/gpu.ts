import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { runPowerShell, formatToolResponse } from '../powershell.js';

export function registerGpuTools(server: McpServer) {
  server.registerTool(
    'get_gpu_metrics',
    {
      description:
        'Get GPU metrics including utilization by engine type (3D, compute, video encode/decode, copy), VRAM total/used/free, temperature, clock speeds, fan speed, power draw, driver version, and per-process GPU usage.',
      inputSchema: {
        include_processes: z
          .boolean()
          .optional()
          .default(false)
          .describe('Include per-process GPU usage'),
        sample_seconds: z
          .number()
          .min(1)
          .max(5)
          .optional()
          .default(1)
          .describe('Duration to sample counters in seconds'),
      },
    },
    async ({ include_processes, sample_seconds }) => {
      const result = await runPowerShell('gpu-metrics.ps1', {
        include_processes,
        sample_seconds,
      });
      return { content: formatToolResponse(result) };
    },
  );
}
