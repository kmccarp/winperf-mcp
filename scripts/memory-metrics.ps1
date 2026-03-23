[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$params = $input | ConvertFrom-Json
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$warnings = @()
$result = @{}

$includeTopProcesses = $false
if ($params.includeTopProcesses -eq $true) { $includeTopProcesses = $true }
$topN = 10
if ($params.topN -and $params.topN -gt 0) { $topN = [int]$params.topN }

# OS memory info
try {
    $ErrorActionPreference = 'SilentlyContinue'
    $os = Get-CimInstance Win32_OperatingSystem
    $totalPhysicalKB = [long]$os.TotalVisibleMemorySize
    $freePhysicalKB = [long]$os.FreePhysicalMemory
    $usedPhysicalKB = $totalPhysicalKB - $freePhysicalKB
    $totalVirtualKB = [long]$os.TotalVirtualMemorySize
    $freeVirtualKB = [long]$os.FreeVirtualMemory
    $usedVirtualKB = $totalVirtualKB - $freeVirtualKB

    $usagePercent = 0
    if ($totalPhysicalKB -gt 0) {
        $usagePercent = [math]::Round(($usedPhysicalKB / $totalPhysicalKB) * 100, 2)
    }

    $result['physical_memory'] = @{
        total_kb      = $totalPhysicalKB
        total_mb      = [math]::Round($totalPhysicalKB / 1024, 2)
        total_gb      = [math]::Round($totalPhysicalKB / 1048576, 2)
        free_kb       = $freePhysicalKB
        free_mb       = [math]::Round($freePhysicalKB / 1024, 2)
        free_gb       = [math]::Round($freePhysicalKB / 1048576, 2)
        used_kb       = $usedPhysicalKB
        used_mb       = [math]::Round($usedPhysicalKB / 1024, 2)
        used_gb       = [math]::Round($usedPhysicalKB / 1048576, 2)
        usage_percent = $usagePercent
    }

    $virtualUsagePercent = 0
    if ($totalVirtualKB -gt 0) {
        $virtualUsagePercent = [math]::Round(($usedVirtualKB / $totalVirtualKB) * 100, 2)
    }

    $result['virtual_memory'] = @{
        total_kb      = $totalVirtualKB
        total_mb      = [math]::Round($totalVirtualKB / 1024, 2)
        total_gb      = [math]::Round($totalVirtualKB / 1048576, 2)
        free_kb       = $freeVirtualKB
        free_mb       = [math]::Round($freeVirtualKB / 1024, 2)
        free_gb       = [math]::Round($freeVirtualKB / 1048576, 2)
        used_kb       = $usedVirtualKB
        used_mb       = [math]::Round($usedVirtualKB / 1024, 2)
        used_gb       = [math]::Round($usedVirtualKB / 1048576, 2)
        usage_percent = $virtualUsagePercent
    }
} catch {
    $warnings += "OS memory: $($_.Exception.Message)"
}

# Memory performance counters
try {
    $ErrorActionPreference = 'SilentlyContinue'
    $memCounters = Get-Counter -Counter @(
        '\Memory\Available MBytes',
        '\Memory\Committed Bytes',
        '\Memory\Commit Limit',
        '\Memory\Cache Bytes',
        '\Memory\Page Faults/sec',
        '\Memory\Pages/sec',
        '\Memory\Pool Nonpaged Bytes',
        '\Memory\Pool Paged Bytes'
    ) -SampleInterval 1 -MaxSamples 1

    $countersResult = @{}
    foreach ($cs in $memCounters.CounterSamples) {
        $shortName = ($cs.Path -replace '.*\\memory\\', '') -replace ' ', '_' -replace '/', '_per_'
        $countersResult[$shortName.ToLower()] = [math]::Round($cs.CookedValue, 2)
    }
    $result['performance_counters'] = $countersResult
} catch {
    $warnings += "Memory counters: $($_.Exception.Message)"
}

# Top processes by memory
if ($includeTopProcesses) {
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $procs = Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First $topN
        $procList = @()
        foreach ($p in $procs) {
            $procList += @{
                name                  = [string]$p.Name
                id                    = [int]$p.Id
                working_set_bytes     = [long]$p.WorkingSet64
                working_set_mb        = [math]::Round($p.WorkingSet64 / 1MB, 2)
                private_memory_bytes  = [long]$p.PrivateMemorySize64
                private_memory_mb     = [math]::Round($p.PrivateMemorySize64 / 1MB, 2)
                virtual_memory_bytes  = [long]$p.VirtualMemorySize64
                virtual_memory_mb     = [math]::Round($p.VirtualMemorySize64 / 1MB, 2)
            }
        }
        $result['top_processes'] = $procList
    } catch {
        $warnings += "Top processes: $($_.Exception.Message)"
    }
}

$result['elevated'] = $isAdmin
$result['elevation_warnings'] = $warnings
$result | ConvertTo-Json -Depth 10
