import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { runPowerShell, formatToolResponse } from '../powershell.js';

export function registerFilesystemTools(server: McpServer) {
  server.registerTool(
    'analyze_filesystem',
    {
      description:
        'Analyze filesystem for performance issues: directory sizes, large file finder, temp file accumulation, and disk space analysis.',
      inputSchema: {
        path: z
          .string()
          .describe('Directory path to analyze'),
        mode: z
          .enum(['large_files', 'dir_sizes', 'temp_files', 'space_analysis'])
          .describe('Analysis mode'),
        min_size_mb: z
          .number()
          .optional()
          .default(100)
          .describe('Minimum file size in MB for large_files mode'),
        top_n: z
          .number()
          .min(1)
          .max(100)
          .optional()
          .default(20)
          .describe('Number of results'),
        max_depth: z
          .number()
          .min(1)
          .max(10)
          .optional()
          .default(3)
          .describe('Max directory recursion depth'),
      },
    },
    async ({ path, mode, min_size_mb, top_n, max_depth }) => {
      const result = await runPowerShell('filesystem.ps1', {
        path,
        mode,
        min_size_mb,
        top_n,
        max_depth,
      }, { timeoutMs: 120_000 });
      return { content: formatToolResponse(result) };
    },
  );
}
