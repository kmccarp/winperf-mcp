import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { runPowerShell, formatToolResponse } from '../powershell.js';

export function registerWindowsUpdateTools(server: McpServer) {
  server.registerTool(
    'get_windows_update',
    {
      description:
        'Get Windows Update status including pending updates, recently installed updates, update history, and Windows Update service state.',
      inputSchema: {
        history_count: z
          .number()
          .min(1)
          .max(100)
          .optional()
          .default(20)
          .describe('Number of recent updates to show'),
        include_pending: z
          .boolean()
          .optional()
          .default(true)
          .describe('Check for pending updates (may be slow)'),
      },
    },
    async ({ history_count, include_pending }) => {
      const result = await runPowerShell(
        'windows-update.ps1',
        {
          history_count,
          include_pending,
        },
        { timeoutMs: 120_000 },
      );
      return { content: formatToolResponse(result) };
    },
  );
}
