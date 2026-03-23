[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$params = $input | ConvertFrom-Json
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$warnings = @()
$result = @{}

$perCore = $false
if ($params.perCore -eq $true) { $perCore = $true }
$sampleSeconds = 1
if ($params.sampleSeconds -and $params.sampleSeconds -gt 0) { $sampleSeconds = [int]$params.sampleSeconds }

# Overall CPU counters
try {
    $ErrorActionPreference = 'SilentlyContinue'
    $counters = @(
        '\Processor(_Total)\% Processor Time',
        '\Processor(_Total)\% Idle Time',
        '\Processor(_Total)\% User Time',
        '\Processor(_Total)\% Privileged Time'
    )
    $samples = Get-Counter -Counter $counters -SampleInterval 1 -MaxSamples $sampleSeconds

    $totals = @{}
    foreach ($c in $counters) {
        $totals[$c] = @()
    }

    foreach ($sample in $samples) {
        foreach ($cs in $sample.CounterSamples) {
            $path = $cs.Path
            foreach ($c in $counters) {
                if ($path -like "*$c") {
                    $totals[$c] += $cs.CookedValue
                }
            }
        }
    }

    $avgValues = @{}
    foreach ($c in $counters) {
        $vals = $totals[$c]
        if ($vals.Count -gt 0) {
            $avg = ($vals | Measure-Object -Average).Average
            $shortName = $c -replace '.*\\', ''
            $avgValues[$shortName] = [math]::Round($avg, 2)
        }
    }
    $result['processor_totals'] = $avgValues
} catch {
    $warnings += "Processor counters: $($_.Exception.Message)"
}

# Per-core CPU usage
if ($perCore) {
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $coreSamples = Get-Counter -Counter '\Processor(*)\% Processor Time' -SampleInterval 1 -MaxSamples $sampleSeconds

        $coreData = @{}
        foreach ($sample in $coreSamples) {
            foreach ($cs in $sample.CounterSamples) {
                $instanceName = $cs.InstanceName
                if ($instanceName -eq '_total') { continue }
                if (-not $coreData.ContainsKey($instanceName)) {
                    $coreData[$instanceName] = @()
                }
                $coreData[$instanceName] += $cs.CookedValue
            }
        }

        $perCoreResult = @{}
        foreach ($core in $coreData.Keys) {
            $vals = $coreData[$core]
            if ($vals.Count -gt 0) {
                $perCoreResult["core_$core"] = [math]::Round(($vals | Measure-Object -Average).Average, 2)
            }
        }
        $result['per_core'] = $perCoreResult
    } catch {
        $warnings += "Per-core counters: $($_.Exception.Message)"
    }
}

# System counters (context switches, queue length)
try {
    $ErrorActionPreference = 'SilentlyContinue'
    $sysCounters = Get-Counter -Counter @(
        '\System\Context Switches/sec',
        '\System\Processor Queue Length'
    ) -SampleInterval 1 -MaxSamples 1

    $sysResult = @{}
    foreach ($cs in $sysCounters.CounterSamples) {
        $shortName = $cs.Path -replace '.*\\', ''
        $sysResult[$shortName] = [math]::Round($cs.CookedValue, 2)
    }
    $result['system_counters'] = $sysResult
} catch {
    $warnings += "System counters: $($_.Exception.Message)"
}

# CIM processor info
try {
    $ErrorActionPreference = 'SilentlyContinue'
    $cpus = @(Get-CimInstance Win32_Processor)
    $cpuInfo = @()
    foreach ($cpu in $cpus) {
        $cpuInfo += @{
            current_clock_speed_mhz = [int]$cpu.CurrentClockSpeed
            max_clock_speed_mhz     = [int]$cpu.MaxClockSpeed
            load_percentage         = [int]$cpu.LoadPercentage
        }
    }
    $result['processor_info'] = $cpuInfo
} catch {
    $warnings += "Processor CIM: $($_.Exception.Message)"
}

# Temperature (requires admin)
try {
    $ErrorActionPreference = 'SilentlyContinue'
    $thermalZones = @(Get-CimInstance MSAcpi_ThermalZoneTemperature -Namespace root/wmi)
    $temps = @()
    foreach ($tz in $thermalZones) {
        $celsius = [math]::Round(($tz.CurrentTemperature - 2732) / 10.0, 1)
        $temps += @{
            instance_name    = [string]$tz.InstanceName
            temperature_c    = $celsius
            temperature_f    = [math]::Round($celsius * 9.0 / 5.0 + 32, 1)
        }
    }
    $result['temperature'] = $temps
} catch {
    $warnings += "Temperature: Requires elevated privileges or WMI thermal zone not available. $($_.Exception.Message)"
}

$result['elevated'] = $isAdmin
$result['elevation_warnings'] = $warnings
$result | ConvertTo-Json -Depth 10
