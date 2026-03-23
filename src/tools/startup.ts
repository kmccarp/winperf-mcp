import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { runPowerShell, formatToolResponse } from '../powershell.js';

export function registerStartupTools(server: McpServer) {
  server.registerTool(
    'get_startup_items',
    {
      description:
        'List startup programs and scheduled tasks. For startup items: name, command, location, publisher. For scheduled tasks: name, status, last run time, next run time, last result, trigger type.',
      inputSchema: {
        include_tasks: z
          .boolean()
          .optional()
          .default(true)
          .describe('Include scheduled tasks'),
        include_startup: z
          .boolean()
          .optional()
          .default(true)
          .describe('Include startup programs'),
        task_state_filter: z
          .enum(['ready', 'running', 'disabled', 'all'])
          .optional()
          .default('all')
          .describe('Filter scheduled tasks by state'),
      },
    },
    async ({ include_tasks, include_startup, task_state_filter }) => {
      const result = await runPowerShell('startup.ps1', {
        include_tasks,
        include_startup,
        task_state_filter,
      });
      return { content: formatToolResponse(result) };
    },
  );
}
