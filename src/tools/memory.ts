import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { runPowerShell, formatToolResponse } from '../powershell.js';

export function registerMemoryTools(server: McpServer) {
  server.registerTool(
    'get_memory_metrics',
    {
      description:
        'Get memory metrics including total/used/available/cached/committed bytes, page faults/sec, paged and non-paged pool sizes, standby list breakdown, and optionally top processes by memory usage.',
      inputSchema: {
        include_top_processes: z
          .boolean()
          .optional()
          .default(false)
          .describe('Include top N processes by memory'),
        top_n: z
          .number()
          .min(1)
          .max(100)
          .optional()
          .default(10)
          .describe('Number of top processes to include'),
      },
    },
    async ({ include_top_processes, top_n }) => {
      const result = await runPowerShell('memory-metrics.ps1', {
        include_top_processes,
        top_n,
      });
      return { content: formatToolResponse(result) };
    },
  );
}
