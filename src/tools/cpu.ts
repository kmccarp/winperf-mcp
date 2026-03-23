import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { runPowerShell, formatToolResponse } from '../powershell.js';

export function registerCpuTools(server: McpServer) {
  server.registerTool(
    'get_cpu_metrics',
    {
      description:
        'Get CPU performance metrics including per-core and aggregate utilization, clock speeds (current/base/boost), temperature, context switches/sec, interrupts/sec, processor queue length, power throttling state.',
      inputSchema: {
        per_core: z
          .boolean()
          .optional()
          .default(false)
          .describe('Include per-core breakdown'),
        sample_seconds: z
          .number()
          .min(1)
          .max(10)
          .optional()
          .default(1)
          .describe('Duration to sample counters in seconds'),
      },
    },
    async ({ per_core, sample_seconds }) => {
      const result = await runPowerShell('cpu-metrics.ps1', {
        per_core,
        sample_seconds,
      });
      return { content: formatToolResponse(result) };
    },
  );
}
