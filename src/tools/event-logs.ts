import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { runPowerShell, formatToolResponse } from '../powershell.js';

export function registerEventLogTools(server: McpServer) {
  server.registerTool(
    'get_event_logs',
    {
      description:
        'Query Windows Event Logs (System, Application, Security) with filtering by log name, level, time range, event source, event ID, and keyword search. Includes presets for common queries: bsod, disk_errors, hardware_errors, power_events, app_crashes, reliability.',
      inputSchema: {
        log_name: z
          .string()
          .optional()
          .default('System')
          .describe(
            'Log name: System, Application, Security, or specific log path',
          ),
        level: z
          .array(z.string())
          .optional()
          .default(['Critical', 'Error', 'Warning'])
          .describe('Filter by level'),
        hours_back: z
          .number()
          .min(1)
          .max(720)
          .optional()
          .default(24)
          .describe('Time window in hours'),
        source: z
          .string()
          .optional()
          .describe('Filter by event source/provider'),
        event_id: z
          .number()
          .optional()
          .describe('Filter by specific event ID'),
        max_events: z
          .number()
          .min(1)
          .max(200)
          .optional()
          .default(50)
          .describe('Max events to return'),
        preset: z
          .string()
          .optional()
          .describe(
            'Preset query: bsod, disk_errors, hardware_errors, power_events, app_crashes, reliability',
          ),
      },
    },
    async ({ log_name, level, hours_back, source, event_id, max_events, preset }) => {
      const result = await runPowerShell('event-logs.ps1', {
        log_name,
        level,
        hours_back,
        source,
        event_id,
        max_events,
        preset,
      });
      return { content: formatToolResponse(result) };
    },
  );
}
