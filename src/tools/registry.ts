import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { runPowerShell, formatToolResponse } from '../powershell.js';

export function registerRegistryTools(server: McpServer) {
  server.registerTool(
    'read_registry',
    {
      description:
        'Read Windows Registry values for performance-related keys. Includes presets for common performance settings.',
      inputSchema: {
        key_path: z
          .string()
          .optional()
          .describe("Registry path, e.g. 'HKLM:\\\\SYSTEM\\\\CurrentControlSet\\\\Control\\\\Power'"),
        value_name: z
          .string()
          .optional()
          .describe('Specific value name (default: all values under key)'),
        preset: z
          .string()
          .optional()
          .describe('Preset: power, memory_management, network_tuning, filesystem, prefetch, superfetch'),
      },
    },
    async ({ key_path, value_name, preset }) => {
      const result = await runPowerShell('registry.ps1', {
        key_path,
        value_name,
        preset,
      });
      return { content: formatToolResponse(result) };
    },
  );
}
