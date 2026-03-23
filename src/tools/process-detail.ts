import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { runPowerShell, formatToolResponse } from '../powershell.js';

export function registerProcessDetailTools(server: McpServer) {
  server.registerTool(
    'get_process_detail',
    {
      description:
        'Deep dive into a single process: threads, handles (with types and leak detection), loaded DLLs/modules, .NET runtime version, network connections and bandwidth, open file handles, GDI/USER object counts, child processes, and WER crash/hang history.',
      inputSchema: {
        pid: z.number().describe('Process ID to inspect'),
        sections: z
          .array(z.string())
          .optional()
          .default(['all'])
          .describe(
            'Filter sections: threads, handles, modules, network, files, gdi, children, crashes, all',
          ),
      },
    },
    async ({ pid, sections }) => {
      const result = await runPowerShell('process-detail.ps1', {
        pid,
        sections,
      });
      return { content: formatToolResponse(result) };
    },
  );
}
