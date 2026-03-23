import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { runPowerShell, formatToolResponse } from '../powershell.js';

export function registerNetworkTools(server: McpServer) {
  server.registerTool(
    'get_network_metrics',
    {
      description:
        'Get network metrics including per-adapter bandwidth usage, active TCP/UDP connections with associated PIDs, DNS resolution latency, packet retransmits, interface speed and link state, Wi-Fi signal strength, and listening ports.',
      inputSchema: {
        adapter_name: z
          .string()
          .optional()
          .describe('Filter to specific adapter name'),
        include_connections: z
          .boolean()
          .optional()
          .default(false)
          .describe('Include active TCP/UDP connections'),
        include_firewall_rules: z
          .boolean()
          .optional()
          .default(false)
          .describe('Include Windows Firewall rules'),
        include_wifi: z
          .boolean()
          .optional()
          .default(false)
          .describe('Include Wi-Fi details'),
        test_dns: z
          .string()
          .optional()
          .describe('DNS name to test resolution latency'),
      },
    },
    async ({
      adapter_name,
      include_connections,
      include_firewall_rules,
      include_wifi,
      test_dns,
    }) => {
      const result = await runPowerShell('network-metrics.ps1', {
        adapter_name,
        include_connections,
        include_firewall_rules,
        include_wifi,
        test_dns,
      });
      return { content: formatToolResponse(result) };
    },
  );
}
