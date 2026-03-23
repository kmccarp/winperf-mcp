import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { runPowerShell, formatToolResponse } from '../powershell.js';

export function registerPowerThermalTools(server: McpServer) {
  server.registerTool(
    'get_power_thermal',
    {
      description:
        'Get power configuration, battery status and health, thermal throttling state, current power plan and settings, sleep/hibernate configuration, and recent power events.',
      inputSchema: {
        include_plan_details: z
          .boolean()
          .optional()
          .default(false)
          .describe('Include detailed power plan settings'),
        include_battery: z
          .boolean()
          .optional()
          .default(true)
          .describe('Include battery health data'),
        include_thermal: z
          .boolean()
          .optional()
          .default(true)
          .describe('Include thermal data'),
      },
    },
    async ({ include_plan_details, include_battery, include_thermal }) => {
      const result = await runPowerShell('power-thermal.ps1', {
        include_plan_details,
        include_battery,
        include_thermal,
      });
      return { content: formatToolResponse(result) };
    },
  );
}
