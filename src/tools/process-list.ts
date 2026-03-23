import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { runPowerShell, formatToolResponse } from '../powershell.js';

export function registerProcessListTools(server: McpServer) {
  server.registerTool(
    'get_process_list',
    {
      description:
        'Get a list of running processes with CPU%, memory usage, disk I/O rates, GPU%, command line, parent PID, owner, thread/handle counts, window title, and responding/hung state.',
      inputSchema: {
        sort_by: z
          .enum(['cpu', 'memory', 'disk_io', 'gpu', 'name', 'pid'])
          .optional()
          .default('cpu')
          .describe('Sort field'),
        top_n: z
          .number()
          .min(0)
          .max(500)
          .optional()
          .default(25)
          .describe('Limit to top N processes (0 = all)'),
        name_filter: z
          .string()
          .optional()
          .describe('Filter by process name (substring match)'),
        include_command_line: z
          .boolean()
          .optional()
          .default(false)
          .describe('Include full command line'),
      },
    },
    async ({ sort_by, top_n, name_filter, include_command_line }) => {
      const result = await runPowerShell('process-list.ps1', {
        sort_by,
        top_n,
        name_filter,
        include_command_line,
      });
      return { content: formatToolResponse(result) };
    },
  );
}
