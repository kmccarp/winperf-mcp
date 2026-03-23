[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$params = $input | ConvertFrom-Json
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$warnings = @()
$result = @{}

$pid_val = [int]$params.pid
$sections = if ($params.sections) { @($params.sections) } else { @("all") }
$allSections = $sections -contains "all"

# Verify process exists
try {
    $proc = Get-Process -Id $pid_val -ErrorAction Stop
} catch {
    $result['error'] = "Process with PID $pid_val not found: $($_.Exception.Message)"
    $result['elevated'] = $isAdmin
    $result['elevation_warnings'] = $warnings
    $result | ConvertTo-Json -Depth 10
    return
}

$processName = $proc.Name

# --- basic ---
if ($allSections -or $sections -contains "basic") {
    try {
        $basic = @{
            Name = $proc.Name
            Id = $proc.Id
            WorkingSet64 = $proc.WorkingSet64
            PrivateMemorySize64 = $proc.PrivateMemorySize64
            VirtualMemorySize64 = $proc.VirtualMemorySize64
            HandleCount = $proc.HandleCount
            ThreadCount = $proc.Threads.Count
            Responding = $proc.Responding
            MainWindowTitle = $proc.MainWindowTitle
        }

        try { $basic['StartTime'] = $proc.StartTime.ToString("o") } catch { $basic['StartTime'] = $null }
        try { $basic['CPU'] = [math]::Round($proc.TotalProcessorTime.TotalSeconds, 2) } catch { $basic['CPU'] = $null }
        try { $basic['PriorityClass'] = $proc.PriorityClass.ToString() } catch { $basic['PriorityClass'] = $null }

        # CIM data
        try {
            $cimProc = Get-CimInstance Win32_Process -Filter "ProcessId=$pid_val" -ErrorAction Stop
            $basic['CommandLine'] = $cimProc.CommandLine
            $basic['ParentProcessId'] = $cimProc.ParentProcessId
            $basic['CreationDate'] = if ($cimProc.CreationDate) { $cimProc.CreationDate.ToString("o") } else { $null }

            try {
                $ownerResult = Invoke-CimMethod -InputObject $cimProc -MethodName GetOwner -ErrorAction Stop
                if ($ownerResult -and $ownerResult.User) {
                    $basic['Owner'] = if ($ownerResult.Domain) { "$($ownerResult.Domain)\$($ownerResult.User)" } else { $ownerResult.User }
                }
            } catch {
                $basic['Owner'] = $null
                $warnings += "Could not retrieve process owner: $($_.Exception.Message)"
            }
        } catch {
            $warnings += "Could not retrieve CIM process data: $($_.Exception.Message)"
        }

        $result['basic'] = $basic
    } catch {
        $warnings += "Failed to collect basic info: $($_.Exception.Message)"
    }
}

# --- threads ---
if ($allSections -or $sections -contains "threads") {
    try {
        $threadList = @()
        foreach ($t in $proc.Threads) {
            try {
                $threadEntry = @{
                    Id = $t.Id
                    CurrentPriority = $t.CurrentPriority
                    ThreadState = $t.ThreadState.ToString()
                    TotalProcessorTime = $null
                    StartTime = $null
                    WaitReason = $null
                }
                try { $threadEntry['TotalProcessorTime'] = $t.TotalProcessorTime.ToString() } catch {}
                try { $threadEntry['StartTime'] = $t.StartTime.ToString("o") } catch {}
                try {
                    if ($t.ThreadState -eq [System.Diagnostics.ThreadState]::Wait) {
                        $threadEntry['WaitReason'] = $t.WaitReason.ToString()
                    }
                } catch {}
                $threadList += $threadEntry
            } catch {
                # Skip individual thread errors
            }
        }
        $result['threads'] = @($threadList)
    } catch {
        $warnings += "Failed to collect thread info: $($_.Exception.Message)"
    }
}

# --- handles ---
if ($allSections -or $sections -contains "handles") {
    try {
        $result['handles'] = @{
            HandleCount = $proc.HandleCount
            Note = "Detailed handle type breakdown requires Sysinternals handle.exe. Only total handle count is available via standard PowerShell APIs."
        }
    } catch {
        $warnings += "Failed to collect handle info: $($_.Exception.Message)"
    }
}

# --- modules ---
if ($allSections -or $sections -contains "modules") {
    try {
        $moduleList = @()
        try {
            foreach ($m in $proc.Modules) {
                try {
                    $moduleList += @{
                        ModuleName = $m.ModuleName
                        FileName = $m.FileName
                        FileVersion = $m.FileVersionInfo.FileVersion
                        Size = $m.ModuleMemorySize
                    }
                } catch {
                    # Skip individual module errors
                }
            }
        } catch {
            $warnings += "Could not enumerate modules (access denied for some or all): $($_.Exception.Message)"
        }
        $result['modules'] = @($moduleList)
    } catch {
        $warnings += "Failed to collect module info: $($_.Exception.Message)"
    }
}

# --- network ---
if ($allSections -or $sections -contains "network") {
    try {
        $netConnections = @()

        try {
            $tcpConns = Get-NetTCPConnection -OwningProcess $pid_val -ErrorAction SilentlyContinue
            foreach ($conn in $tcpConns) {
                $netConnections += @{
                    Protocol = "TCP"
                    LocalAddress = $conn.LocalAddress
                    LocalPort = $conn.LocalPort
                    RemoteAddress = $conn.RemoteAddress
                    RemotePort = $conn.RemotePort
                    State = $conn.State.ToString()
                }
            }
        } catch {
            $warnings += "Could not retrieve TCP connections: $($_.Exception.Message)"
        }

        try {
            $udpEndpoints = Get-NetUDPEndpoint -OwningProcess $pid_val -ErrorAction SilentlyContinue
            foreach ($ep in $udpEndpoints) {
                $netConnections += @{
                    Protocol = "UDP"
                    LocalAddress = $ep.LocalAddress
                    LocalPort = $ep.LocalPort
                    RemoteAddress = $null
                    RemotePort = $null
                    State = "N/A"
                }
            }
        } catch {
            $warnings += "Could not retrieve UDP endpoints: $($_.Exception.Message)"
        }

        $result['network'] = @($netConnections)
    } catch {
        $warnings += "Failed to collect network info: $($_.Exception.Message)"
    }
}

# --- gdi ---
if ($allSections -or $sections -contains "gdi") {
    try {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
public class GDIResources {
    [DllImport("user32.dll")]
    public static extern int GetGuiResources(IntPtr hProcess, int uiFlags);
}
"@ -ErrorAction SilentlyContinue

        $gdiCount = $null
        $userCount = $null
        try {
            $gdiCount = [GDIResources]::GetGuiResources($proc.Handle, 0)
            $userCount = [GDIResources]::GetGuiResources($proc.Handle, 1)
        } catch {
            $warnings += "Could not read GDI resources (may need elevation or process handle access): $($_.Exception.Message)"
        }

        $result['gdi'] = @{
            GDIObjectCount = $gdiCount
            USERObjectCount = $userCount
        }
    } catch {
        $warnings += "Failed to collect GDI info: $($_.Exception.Message)"
    }
}

# --- children ---
if ($allSections -or $sections -contains "children") {
    try {
        $childProcs = @()
        $cimChildren = Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $pid_val }
        foreach ($child in $cimChildren) {
            $childProcs += @{
                Name = $child.Name
                ProcessId = $child.ProcessId
                CreationDate = if ($child.CreationDate) { $child.CreationDate.ToString("o") } else { $null }
            }
        }
        $result['children'] = @($childProcs)
    } catch {
        $warnings += "Failed to collect child process info: $($_.Exception.Message)"
    }
}

# --- crashes ---
if ($allSections -or $sections -contains "crashes") {
    try {
        $crashInfo = @{
            events = @()
            dump_files = @()
        }

        # Check event log for crash events related to this process
        try {
            $crashEvents = Get-WinEvent -FilterHashtable @{
                LogName = 'Application'
                ProviderName = 'Application Error','Application Hang','.NET Runtime','Windows Error Reporting'
                Level = 2
                StartTime = (Get-Date).AddDays(-30)
            } -MaxEvents 20 -ErrorAction SilentlyContinue

            if ($crashEvents) {
                $filtered = $crashEvents | Where-Object { $_.Message -like "*$processName*" }
                foreach ($evt in $filtered) {
                    $msgTruncated = if ($evt.Message.Length -gt 500) { $evt.Message.Substring(0, 500) + "..." } else { $evt.Message }
                    $crashInfo['events'] += @{
                        TimeCreated = $evt.TimeCreated.ToString("o")
                        Id = $evt.Id
                        ProviderName = $evt.ProviderName
                        Message = $msgTruncated
                    }
                }
            }
        } catch {
            $warnings += "Could not query crash events: $($_.Exception.Message)"
        }

        # Check for crash dump files
        try {
            $crashDumpPath = "$env:LOCALAPPDATA\CrashDumps"
            if (Test-Path $crashDumpPath) {
                $dumpFiles = Get-ChildItem $crashDumpPath -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$processName*" }
                foreach ($dump in $dumpFiles) {
                    $crashInfo['dump_files'] += @{
                        Name = $dump.Name
                        Size = $dump.Length
                        LastWriteTime = $dump.LastWriteTime.ToString("o")
                    }
                }
            }
        } catch {
            $warnings += "Could not check crash dumps: $($_.Exception.Message)"
        }

        $result['crashes'] = $crashInfo
    } catch {
        $warnings += "Failed to collect crash info: $($_.Exception.Message)"
    }
}

$result['elevated'] = $isAdmin
$result['elevation_warnings'] = $warnings
$result | ConvertTo-Json -Depth 10
