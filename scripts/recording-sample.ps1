[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$params = $input | ConvertFrom-Json

$metrics = if ($null -ne $params.metrics -and $params.metrics.Count -gt 0) { $params.metrics } else { @('cpu', 'memory') }
$processFilter = if ($null -ne $params.processFilter -and $params.processFilter -ne '') { $params.processFilter } else { $null }

$result = @{}
$result['timestamp'] = (Get-Date).ToString('o')

# CPU
if ($metrics -contains 'cpu') {
    try {
        $counterPaths = @(
            '\Processor(_Total)\% Processor Time',
            '\System\Processor Queue Length'
        )
        $sample = Get-Counter $counterPaths -ErrorAction Stop
        foreach ($cs in $sample.CounterSamples) {
            if ($cs.Path -like '*% Processor Time*') {
                $result['cpu_percent'] = [math]::Round($cs.CookedValue, 1)
            }
            if ($cs.Path -like '*Processor Queue Length*') {
                $result['cpu_queue_length'] = [int]$cs.CookedValue
            }
        }
    } catch {
        $result['cpu_percent'] = $null
        $result['cpu_error'] = $_.ToString()
    }
}

# Memory
if ($metrics -contains 'memory') {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $totalKb = $os.TotalVisibleMemorySize
        $freeKb = $os.FreePhysicalMemory
        $usedKb = $totalKb - $freeKb
        $result['memory_total_mb'] = [math]::Round($totalKb / 1024, 0)
        $result['memory_used_mb'] = [math]::Round($usedKb / 1024, 0)
        $result['memory_free_mb'] = [math]::Round($freeKb / 1024, 0)
        $result['memory_used_percent'] = [math]::Round(($usedKb / $totalKb) * 100, 1)
    } catch {
        $result['memory_used_percent'] = $null
        $result['memory_error'] = $_.ToString()
    }
}

# Disk
if ($metrics -contains 'disk') {
    try {
        $counterPaths = @(
            '\PhysicalDisk(_Total)\Disk Read Bytes/sec',
            '\PhysicalDisk(_Total)\Disk Write Bytes/sec',
            '\PhysicalDisk(_Total)\% Idle Time'
        )
        $sample = Get-Counter $counterPaths -ErrorAction Stop
        foreach ($cs in $sample.CounterSamples) {
            if ($cs.Path -like '*Read Bytes*') {
                $result['disk_read_bytes_sec'] = [math]::Round($cs.CookedValue, 0)
            }
            if ($cs.Path -like '*Write Bytes*') {
                $result['disk_write_bytes_sec'] = [math]::Round($cs.CookedValue, 0)
            }
            if ($cs.Path -like '*Idle Time*') {
                $result['disk_idle_percent'] = [math]::Round($cs.CookedValue, 1)
            }
        }
    } catch {
        $result['disk_read_bytes_sec'] = $null
        $result['disk_write_bytes_sec'] = $null
        $result['disk_error'] = $_.ToString()
    }
}

# GPU
if ($metrics -contains 'gpu') {
    try {
        $sample = Get-Counter '\GPU Engine(*engtype_3D)\Utilization Percentage' -ErrorAction Stop
        $totalGpu = 0.0
        foreach ($cs in $sample.CounterSamples) {
            if ($cs.CookedValue -gt 0) {
                $totalGpu += $cs.CookedValue
            }
        }
        $result['gpu_3d_percent'] = [math]::Round($totalGpu, 1)
    } catch {
        $result['gpu_3d_percent'] = $null
        $result['gpu_error'] = $_.ToString()
    }
}

# Network
if ($metrics -contains 'network') {
    try {
        $counterPaths = @(
            '\Network Interface(*)\Bytes Received/sec',
            '\Network Interface(*)\Bytes Sent/sec'
        )
        $sample = Get-Counter $counterPaths -ErrorAction Stop
        $totalRecv = 0.0
        $totalSent = 0.0
        foreach ($cs in $sample.CounterSamples) {
            if ($cs.Path -like '*Bytes Received*') {
                $totalRecv += $cs.CookedValue
            }
            if ($cs.Path -like '*Bytes Sent*') {
                $totalSent += $cs.CookedValue
            }
        }
        $result['net_recv_bytes_sec'] = [math]::Round($totalRecv, 0)
        $result['net_sent_bytes_sec'] = [math]::Round($totalSent, 0)
    } catch {
        $result['net_recv_bytes_sec'] = $null
        $result['net_sent_bytes_sec'] = $null
        $result['network_error'] = $_.ToString()
    }
}

# Processes
if ($metrics -contains 'processes') {
    try {
        $procs = Get-Process -ErrorAction Stop
        if ($processFilter) {
            $procs = $procs | Where-Object { $_.Name -like "*$processFilter*" }
        }
        $topProcs = $procs | Sort-Object CPU -Descending | Select-Object -First 10
        $result['top_processes'] = @($topProcs | ForEach-Object {
            @{
                name          = $_.Name
                id            = $_.Id
                cpu_seconds   = if ($_.CPU) { [math]::Round($_.CPU, 2) } else { 0 }
                working_set_mb = [math]::Round($_.WorkingSet64 / 1MB, 1)
            }
        })
    } catch {
        $result['top_processes'] = @()
        $result['processes_error'] = $_.ToString()
    }
}

$result | ConvertTo-Json -Depth 10
