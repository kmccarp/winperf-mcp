import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { runPowerShell, formatToolResponse } from '../powershell.js';

export function registerPerfCounterTools(server: McpServer) {
  server.registerTool(
    'query_perf_counter',
    {
      description:
        'Query arbitrary Windows Performance Counters by path. Use list_mode to discover available counter sets and their counters.',
      inputSchema: {
        counter_path: z
          .string()
          .optional()
          .describe("Counter path, e.g. '\\\\Processor(_Total)\\\\% Processor Time'"),
        counter_set: z
          .string()
          .optional()
          .describe('Counter set name to list counters from (used with list_mode)'),
        list_mode: z
          .boolean()
          .optional()
          .default(false)
          .describe('If true, list available counter sets or counters in a set'),
        sample_seconds: z
          .number()
          .min(1)
          .max(10)
          .optional()
          .default(1)
          .describe('Sample duration in seconds'),
      },
    },
    async ({ counter_path, counter_set, list_mode, sample_seconds }) => {
      const result = await runPowerShell('perf-counter.ps1', {
        counter_path,
        counter_set,
        list_mode,
        sample_seconds,
      });
      return { content: formatToolResponse(result) };
    },
  );
}
