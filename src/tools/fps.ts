import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { captureFps, isPresentMonAvailable } from '../native/presentmon.js';

export function registerFpsTools(server: McpServer) {
  server.registerTool(
    'get_fps_metrics',
    {
      description:
        'Capture per-application FPS metrics using PresentMon. Returns FPS (avg/min/max/p1/p5), frame times, CPU/GPU busy time per frame, and presentation mode for each GPU-presenting application. Requires PresentMon binary in vendor/.',
      inputSchema: {
        duration_seconds: z
          .number()
          .min(1)
          .max(30)
          .optional()
          .default(3)
          .describe('Duration to capture frame data in seconds'),
      },
    },
    async ({ duration_seconds }) => {
      if (!isPresentMonAvailable()) {
        return {
          content: [{
            type: 'text' as const,
            text: JSON.stringify({
              error: 'PresentMon not found. Place PresentMon.exe in the vendor/ directory.',
            }, null, 2),
          }],
        };
      }

      try {
        const result = await captureFps(duration_seconds);
        return {
          content: [{
            type: 'text' as const,
            text: JSON.stringify(result, null, 2),
          }],
        };
      } catch (err) {
        return {
          content: [{
            type: 'text' as const,
            text: JSON.stringify({
              error: err instanceof Error ? err.message : String(err),
            }, null, 2),
          }],
        };
      }
    },
  );
}
