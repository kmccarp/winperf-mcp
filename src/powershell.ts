import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

import { existsSync } from 'node:fs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const SCRIPTS_DIR = path.resolve(__dirname, '..', 'scripts');

// Log at startup for diagnostics
if (!existsSync(SCRIPTS_DIR)) {
  console.error(`[winperf] WARNING: scripts dir not found at ${SCRIPTS_DIR}`);
}

export interface PowerShellOptions {
  timeoutMs?: number;
}

export interface PowerShellResult {
  data: unknown;
  stderr: string;
}

export function runPowerShell(
  scriptName: string,
  params: Record<string, unknown> = {},
  options: PowerShellOptions = {}
): Promise<PowerShellResult> {
  const { timeoutMs = 30_000 } = options;
  const scriptPath = path.join(SCRIPTS_DIR, scriptName);

  return new Promise((resolve, reject) => {
    const child = spawn(
      'powershell.exe',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', scriptPath],
      {
        stdio: ['pipe', 'pipe', 'pipe'],
        windowsHide: true,
      }
    );

    let stdout = '';
    let stderr = '';
    let settled = false;

    const timer = setTimeout(() => {
      if (!settled) {
        settled = true;
        child.kill();
        reject(new Error(`PowerShell script '${scriptName}' timed out after ${timeoutMs}ms`));
      }
    }, timeoutMs);

    child.stdout.on('data', (chunk: Buffer) => { stdout += chunk.toString(); });
    child.stderr.on('data', (chunk: Buffer) => { stderr += chunk.toString(); });

    child.on('close', (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);

      if (code !== 0 && code !== null) {
        reject(new Error(`PowerShell script '${scriptName}' exited with code ${code}\nStderr: ${stderr}`));
        return;
      }

      const trimmed = stdout.trim();
      if (!trimmed) {
        resolve({ data: {}, stderr });
        return;
      }

      try {
        const data = JSON.parse(trimmed);
        resolve({ data, stderr });
      } catch {
        resolve({ data: { raw_output: trimmed }, stderr });
      }
    });

    child.on('error', (err) => {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        reject(new Error(`PowerShell script '${scriptName}' failed to start: ${err.message}`));
      }
    });

    // Pass parameters as JSON via stdin
    child.stdin.write(JSON.stringify(params));
    child.stdin.end();
  });
}

export function formatToolResponse(result: PowerShellResult): { type: 'text'; text: string }[] {
  let text = JSON.stringify(result.data, null, 2);
  if (result.stderr) {
    text += `\n\n--- PowerShell Warnings ---\n${result.stderr}`;
  }
  return [{ type: 'text', text }];
}
