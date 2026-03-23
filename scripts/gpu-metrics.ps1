[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$params = $input | ConvertFrom-Json
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$warnings = @()
$result = @{}

$includeProcesses = $false
if ($params.includeProcesses -eq $true) { $includeProcesses = $true }
$sampleSeconds = 1
if ($params.sampleSeconds -and $params.sampleSeconds -gt 0) { $sampleSeconds = [int]$params.sampleSeconds }

# GPU info via WMI
try {
    $ErrorActionPreference = 'SilentlyContinue'
    $gpus = @(Get-CimInstance Win32_VideoController)
    $gpuList = @()
    foreach ($gpu in $gpus) {
        $gpuList += @{
            name               = [string]$gpu.Name
            driver_version     = [string]$gpu.DriverVersion
            adapter_ram        = $gpu.AdapterRAM
            adapter_ram_gb     = [math]::Round([long]$gpu.AdapterRAM / 1GB, 2)
            status             = [string]$gpu.Status
            current_refresh_rate = [int]$gpu.CurrentRefreshRate
        }
    }
    $result['gpu_info'] = $gpuList
} catch {
    $warnings += "GPU info: $($_.Exception.Message)"
}

# GPU Engine utilization
try {
    $ErrorActionPreference = 'SilentlyContinue'
    $gpuEngSamples = Get-Counter -Counter '\GPU Engine(*)\Utilization Percentage' -SampleInterval 1 -MaxSamples $sampleSeconds

    # Aggregate by engine type
    $engineData = @{}
    foreach ($sample in $gpuEngSamples) {
        foreach ($cs in $sample.CounterSamples) {
            $instance = $cs.InstanceName
            # Parse engine type from instance name like "pid_1234_luid_0x00000000_0x00001234_phys_0_eng_0_engtype_3D"
            if ($instance -match 'engtype_(.+)$') {
                $engType = $Matches[1]
                if (-not $engineData.ContainsKey($engType)) {
                    $engineData[$engType] = @()
                }
                $engineData[$engType] += $cs.CookedValue
            }
        }
    }

    $engineResult = @{}
    foreach ($engType in $engineData.Keys) {
        $vals = $engineData[$engType]
        if ($vals.Count -gt 0) {
            $engineResult[$engType] = @{
                average_utilization = [math]::Round(($vals | Measure-Object -Average).Average, 4)
                max_utilization     = [math]::Round(($vals | Measure-Object -Maximum).Maximum, 4)
                sample_count        = $vals.Count
            }
        }
    }
    $result['engine_utilization'] = $engineResult
} catch {
    $warnings += "GPU engine counters: $($_.Exception.Message)"
}

# GPU Adapter Memory
try {
    $ErrorActionPreference = 'SilentlyContinue'
    $memCounters = @(
        '\GPU Adapter Memory(*)\Dedicated Usage',
        '\GPU Adapter Memory(*)\Shared Usage',
        '\GPU Adapter Memory(*)\Local Usage'
    )
    $memSamples = Get-Counter -Counter $memCounters -SampleInterval 1 -MaxSamples 1

    $adapterMem = @{}
    foreach ($cs in $memSamples.CounterSamples) {
        $instance = $cs.InstanceName
        if (-not $adapterMem.ContainsKey($instance)) {
            $adapterMem[$instance] = @{}
        }
        $counterName = ($cs.Path -replace '.*\\gpu adapter memory\([^)]*\)\\', '').ToLower() -replace ' ', '_'
        $adapterMem[$instance][$counterName] = @{
            bytes = [math]::Round($cs.CookedValue, 0)
            mb    = [math]::Round($cs.CookedValue / 1MB, 2)
        }
    }
    $result['adapter_memory'] = $adapterMem
} catch {
    $warnings += "GPU adapter memory counters: $($_.Exception.Message)"
}

# GPU Process Memory
if ($includeProcesses) {
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $procCounters = @(
            '\GPU Process Memory(*)\Dedicated Usage',
            '\GPU Process Memory(*)\Shared Usage'
        )
        $procSamples = Get-Counter -Counter $procCounters -SampleInterval 1 -MaxSamples 1

        # Parse per-PID data
        $pidData = @{}
        foreach ($cs in $procSamples.CounterSamples) {
            $instance = $cs.InstanceName
            # Extract PID from instance like "pid_1234_luid_0x00000000_0x00001234_phys_0"
            if ($instance -match 'pid_(\d+)') {
                $pid = $Matches[1]
                if (-not $pidData.ContainsKey($pid)) {
                    $pidData[$pid] = @{}
                }
                $counterName = ($cs.Path -replace '.*\\gpu process memory\([^)]*\)\\', '').ToLower() -replace ' ', '_'
                if (-not $pidData[$pid].ContainsKey($counterName)) {
                    $pidData[$pid][$counterName] = [long]0
                }
                $pidData[$pid][$counterName] += [long]$cs.CookedValue
            }
        }

        # Map PIDs to process names
        $gpuProcesses = @()
        foreach ($pid in $pidData.Keys) {
            $procName = "Unknown"
            try {
                $proc = Get-Process -Id ([int]$pid) -ErrorAction SilentlyContinue
                if ($proc) { $procName = $proc.Name }
            } catch {}

            $entry = @{
                pid          = [int]$pid
                process_name = $procName
            }
            foreach ($counter in $pidData[$pid].Keys) {
                $entry[$counter + "_bytes"] = $pidData[$pid][$counter]
                $entry[$counter + "_mb"] = [math]::Round($pidData[$pid][$counter] / 1MB, 2)
            }
            $gpuProcesses += $entry
        }

        # Sort by dedicated usage descending
        $gpuProcesses = $gpuProcesses | Sort-Object { if ($_.dedicated_usage_bytes) { $_.dedicated_usage_bytes } else { 0 } } -Descending
        $result['gpu_processes'] = $gpuProcesses
    } catch {
        $warnings += "GPU process memory: $($_.Exception.Message)"
    }
}

# nvidia-smi
try {
    $ErrorActionPreference = 'SilentlyContinue'
    $nvidiaSmiPath = 'C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe'
    if (-not (Test-Path $nvidiaSmiPath)) {
        # Try finding nvidia-smi on PATH or in System32
        $nvidiaSmiPath = (Get-Command nvidia-smi -ErrorAction SilentlyContinue).Source
    }
    if ($nvidiaSmiPath -and (Test-Path $nvidiaSmiPath)) {
        $nvOutput = & $nvidiaSmiPath --query-gpu=temperature.gpu,fan.speed,power.draw,clocks.current.graphics,clocks.current.memory --format=csv,noheader,nounits 2>&1
        if ($LASTEXITCODE -eq 0 -and $nvOutput) {
            $nvGpus = @()
            foreach ($line in $nvOutput) {
                $parts = $line -split ',\s*'
                if ($parts.Count -ge 5) {
                    $nvGpus += @{
                        temperature_c          = [double]$parts[0]
                        fan_speed_percent      = $parts[1].Trim()
                        power_draw_w           = [double]$parts[2]
                        graphics_clock_mhz     = [int]$parts[3]
                        memory_clock_mhz       = [int]$parts[4]
                    }
                }
            }
            $result['nvidia_smi'] = $nvGpus
        }
    } else {
        $warnings += "nvidia-smi: Not found. NVIDIA GPU monitoring unavailable."
    }
} catch {
    $warnings += "nvidia-smi: $($_.Exception.Message)"
}

$result['elevated'] = $isAdmin
$result['elevation_warnings'] = $warnings
$result | ConvertTo-Json -Depth 10
