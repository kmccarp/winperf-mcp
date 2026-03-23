import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { runPowerShell, formatToolResponse } from '../powershell.js';

export function registerDiskTools(server: McpServer) {
  server.registerTool(
    'get_disk_metrics',
    {
      description:
        'Get disk/storage performance and health data including per-disk IOPS, throughput, latency, queue depth, busy %, free space per volume, SMART health status, SSD wear level, and disk type.',
      inputSchema: {
        disk_index: z
          .number()
          .optional()
          .describe('Specific disk index (default: all disks)'),
        include_smart: z
          .boolean()
          .optional()
          .default(true)
          .describe('Include SMART/health data'),
        sample_seconds: z
          .number()
          .min(1)
          .max(10)
          .optional()
          .default(1)
          .describe('Duration to sample counters in seconds'),
      },
    },
    async ({ disk_index, include_smart, sample_seconds }) => {
      const result = await runPowerShell('disk-metrics.ps1', {
        disk_index,
        include_smart,
        sample_seconds,
      });
      return { content: formatToolResponse(result) };
    },
  );
}
