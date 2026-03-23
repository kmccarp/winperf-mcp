import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { runPowerShell, formatToolResponse } from '../powershell.js';

export function registerInstalledSoftwareTools(server: McpServer) {
  server.registerTool(
    'get_installed_software',
    {
      description:
        'List installed programs (name, version, publisher, install date) and running drivers with signed/unsigned status. Uses registry for fast enumeration (avoids slow Win32_Product).',
      inputSchema: {
        include_drivers: z
          .boolean()
          .optional()
          .default(false)
          .describe('Include loaded drivers'),
        name_filter: z
          .string()
          .optional()
          .describe('Filter software by name (substring)'),
        unsigned_drivers_only: z
          .boolean()
          .optional()
          .default(false)
          .describe('Only show unsigned drivers'),
      },
    },
    async ({ include_drivers, name_filter, unsigned_drivers_only }) => {
      const result = await runPowerShell('installed-software.ps1', {
        include_drivers,
        name_filter,
        unsigned_drivers_only,
      });
      return { content: formatToolResponse(result) };
    },
  );
}
