import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { runPowerShell, formatToolResponse } from '../powershell.js';

export function registerWmiTools(server: McpServer) {
  server.registerTool(
    'query_wmi',
    {
      description:
        'Execute an arbitrary read-only WMI/CIM query. Supports class name with optional property filter, or raw WQL query. Only SELECT queries are allowed.',
      inputSchema: {
        class_name: z
          .string()
          .optional()
          .describe("WMI class name, e.g. 'Win32_Processor'"),
        namespace: z
          .string()
          .optional()
          .default('root/cimv2')
          .describe('WMI namespace'),
        properties: z
          .array(z.string())
          .optional()
          .describe('Properties to select (default: all)'),
        filter: z
          .string()
          .optional()
          .describe("WQL WHERE clause, e.g. \"Status='OK'\""),
        query: z
          .string()
          .optional()
          .describe('Raw WQL query (overrides class_name/properties/filter)'),
        max_results: z
          .number()
          .min(1)
          .max(500)
          .optional()
          .default(50)
          .describe('Limit results'),
      },
    },
    async ({ class_name, namespace, properties, filter, query, max_results }) => {
      const result = await runPowerShell('wmi-query.ps1', {
        class_name,
        namespace,
        properties,
        filter,
        query,
        max_results,
      });
      return { content: formatToolResponse(result) };
    },
  );
}
