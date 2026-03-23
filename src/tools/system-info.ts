import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { runPowerShell, formatToolResponse } from '../powershell.js';

export function registerSystemInfoTools(server: McpServer) {
  server.registerTool(
    'get_system_info',
    {
      description:
        'Get Windows system information including OS version/build/edition, hostname, uptime, last boot time, installed RAM, CPU model, GPU model, BIOS version, and motherboard details.',
      inputSchema: {
        sections: z
          .array(z.string())
          .optional()
          .default(['all'])
          .describe(
            'Filter sections: os, cpu, gpu, bios, motherboard, memory_hardware, all',
          ),
      },
    },
    async ({ sections }) => {
      const result = await runPowerShell('system-info.ps1', { sections });
      return { content: formatToolResponse(result) };
    },
  );
}
