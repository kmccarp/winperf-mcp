#!/usr/bin/env node

import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';

import { registerSystemInfoTools } from './tools/system-info.js';
import { registerCpuTools } from './tools/cpu.js';
import { registerMemoryTools } from './tools/memory.js';
import { registerDiskTools } from './tools/disk.js';
import { registerGpuTools } from './tools/gpu.js';
import { registerNetworkTools } from './tools/network.js';
import { registerProcessListTools } from './tools/process-list.js';
import { registerProcessDetailTools } from './tools/process-detail.js';
import { registerEventLogTools } from './tools/event-logs.js';
import { registerServicesTools } from './tools/services.js';
import { registerStartupTools } from './tools/startup.js';
import { registerWindowsUpdateTools } from './tools/windows-update.js';
import { registerPowerThermalTools } from './tools/power-thermal.js';
import { registerInstalledSoftwareTools } from './tools/installed-software.js';
import { registerPerfCounterTools } from './tools/perf-counter.js';
import { registerWmiTools } from './tools/wmi.js';
import { registerFilesystemTools } from './tools/filesystem.js';
import { registerRegistryTools } from './tools/registry.js';
import { registerRecordingTools } from './tools/recording.js';
import { registerFpsTools } from './tools/fps.js';
import { registerVisualizeTools } from './tools/visualize.js';

const server = new McpServer({
  name: 'winperf-mcp',
  version: '1.0.0',
});

// Register all tools
registerSystemInfoTools(server);
registerCpuTools(server);
registerMemoryTools(server);
registerDiskTools(server);
registerGpuTools(server);
registerNetworkTools(server);
registerProcessListTools(server);
registerProcessDetailTools(server);
registerEventLogTools(server);
registerServicesTools(server);
registerStartupTools(server);
registerWindowsUpdateTools(server);
registerPowerThermalTools(server);
registerInstalledSoftwareTools(server);
registerPerfCounterTools(server);
registerWmiTools(server);
registerFilesystemTools(server);
registerRegistryTools(server);
registerRecordingTools(server);
registerFpsTools(server);
registerVisualizeTools(server);

// Start the server
const transport = new StdioServerTransport();
await server.connect(transport);
