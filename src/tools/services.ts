import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { runPowerShell, formatToolResponse } from '../powershell.js';

export function registerServicesTools(server: McpServer) {
  server.registerTool(
    'get_services',
    {
      description:
        'List Windows services with status, startup type, account, PID, description, and dependencies.',
      inputSchema: {
        status_filter: z
          .enum(['running', 'stopped', 'all'])
          .optional()
          .default('all')
          .describe('Filter by service state'),
        name_filter: z
          .string()
          .optional()
          .describe(
            'Filter by service name or display name (substring)',
          ),
        include_dependencies: z
          .boolean()
          .optional()
          .default(false)
          .describe('Include dependency chain'),
      },
    },
    async ({ status_filter, name_filter, include_dependencies }) => {
      const result = await runPowerShell('services.ps1', {
        status_filter,
        name_filter,
        include_dependencies,
      });
      return { content: formatToolResponse(result) };
    },
  );
}
