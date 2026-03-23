[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$params = $input | ConvertFrom-Json
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$warnings = @()
$result = @{}

$includePlanDetails = if ($null -ne $params.includePlanDetails) { $params.includePlanDetails } else { $false }
$includeBattery = if ($null -ne $params.includeBattery) { $params.includeBattery } else { $false }
$includeThermal = if ($null -ne $params.includeThermal) { $params.includeThermal } else { $false }

# Current power plan
try {
    $activePlan = powercfg /getactivescheme 2>&1
    if ($activePlan -match '(\S{8}-\S{4}-\S{4}-\S{4}-\S{12})\s+\((.+)\)') {
        $result['active_plan'] = @{
            guid = $Matches[1]
            name = $Matches[2]
        }
    } else {
        $result['active_plan'] = @{ raw = ($activePlan | Out-String).Trim() }
    }
} catch {
    $warnings += "Failed to get active power plan: $_"
    $result['active_plan'] = $null
}

# Power plan details
if ($includePlanDetails) {
    try {
        $queryOutput = powercfg /query 2>&1 | Out-String
        $planDetails = @{}

        # Parse sleep timeouts
        try {
            $sleepSettings = @{}
            if ($queryOutput -match '(?s)Subgroup GUID:\s+\S+\s+\(Sleep\)(.+?)(?=Subgroup GUID:|$)') {
                $sleepBlock = $Matches[1]
                $settingPattern = '(?s)Power Setting GUID:\s+\S+\s+\(([^)]+)\).*?Current AC Power Setting Index:\s+0x([0-9a-fA-F]+)(?:.*?Current DC Power Setting Index:\s+0x([0-9a-fA-F]+))?'
                $settingMatches = [regex]::Matches($sleepBlock, $settingPattern)
                foreach ($m in $settingMatches) {
                    $name = $m.Groups[1].Value.Trim()
                    $acVal = [Convert]::ToInt32($m.Groups[2].Value, 16)
                    $dcVal = if ($m.Groups[3].Success) { [Convert]::ToInt32($m.Groups[3].Value, 16) } else { $null }
                    $sleepSettings[$name] = @{ ac_seconds = $acVal; dc_seconds = $dcVal }
                }
            }
            $planDetails['sleep'] = $sleepSettings
        } catch {
            $warnings += "Failed to parse sleep settings: $_"
        }

        # Parse display timeouts
        try {
            $displaySettings = @{}
            if ($queryOutput -match '(?s)Subgroup GUID:\s+\S+\s+\(Display\)(.+?)(?=Subgroup GUID:|$)') {
                $displayBlock = $Matches[1]
                $settingMatches = [regex]::Matches($displayBlock, $settingPattern)
                foreach ($m in $settingMatches) {
                    $name = $m.Groups[1].Value.Trim()
                    $acVal = [Convert]::ToInt32($m.Groups[2].Value, 16)
                    $dcVal = if ($m.Groups[3].Success) { [Convert]::ToInt32($m.Groups[3].Value, 16) } else { $null }
                    $displaySettings[$name] = @{ ac_seconds = $acVal; dc_seconds = $dcVal }
                }
            }
            $planDetails['display'] = $displaySettings
        } catch {
            $warnings += "Failed to parse display settings: $_"
        }

        # Parse processor power management
        try {
            $processorSettings = @{}
            if ($queryOutput -match '(?s)Subgroup GUID:\s+\S+\s+\(Processor power management\)(.+?)(?=Subgroup GUID:|$)') {
                $procBlock = $Matches[1]
                $settingMatches = [regex]::Matches($procBlock, $settingPattern)
                foreach ($m in $settingMatches) {
                    $name = $m.Groups[1].Value.Trim()
                    $acVal = [Convert]::ToInt32($m.Groups[2].Value, 16)
                    $dcVal = if ($m.Groups[3].Success) { [Convert]::ToInt32($m.Groups[3].Value, 16) } else { $null }
                    $processorSettings[$name] = @{ ac_value = $acVal; dc_value = $dcVal }
                }
            }
            $planDetails['processor_power_management'] = $processorSettings
        } catch {
            $warnings += "Failed to parse processor power settings: $_"
        }

        # Parse hard disk timeout
        try {
            $diskSettings = @{}
            if ($queryOutput -match '(?s)Subgroup GUID:\s+\S+\s+\(Hard disk\)(.+?)(?=Subgroup GUID:|$)') {
                $diskBlock = $Matches[1]
                $settingMatches = [regex]::Matches($diskBlock, $settingPattern)
                foreach ($m in $settingMatches) {
                    $name = $m.Groups[1].Value.Trim()
                    $acVal = [Convert]::ToInt32($m.Groups[2].Value, 16)
                    $dcVal = if ($m.Groups[3].Success) { [Convert]::ToInt32($m.Groups[3].Value, 16) } else { $null }
                    $diskSettings[$name] = @{ ac_seconds = $acVal; dc_seconds = $dcVal }
                }
            }
            $planDetails['hard_disk'] = $diskSettings
        } catch {
            $warnings += "Failed to parse hard disk settings: $_"
        }

        $result['plan_details'] = $planDetails
    } catch {
        $warnings += "Failed to query power plan details: $_"
        $result['plan_details'] = $null
    }
}

# Battery info
if ($includeBattery) {
    try {
        $battery = Get-CimInstance Win32_Battery -ErrorAction Stop
        if ($battery) {
            $result['battery'] = @{
                estimated_charge_remaining = $battery.EstimatedChargeRemaining
                battery_status             = $battery.BatteryStatus
                design_capacity            = $battery.DesignCapacity
                full_charge_capacity       = $battery.FullChargeCapacity
                estimated_run_time         = $battery.EstimatedRunTime
            }
        } else {
            $result['battery'] = $null
            $warnings += "No battery detected (Win32_Battery returned no results)"
        }
    } catch {
        $warnings += "Failed to get battery info: $_"
        $result['battery'] = $null
    }

    # Battery health data from WMI
    try {
        $staticData = Get-CimInstance BatteryStaticData -Namespace root/wmi -ErrorAction Stop
        $fullCharged = Get-CimInstance BatteryFullChargedCapacity -Namespace root/wmi -ErrorAction Stop
        $result['battery_health'] = @{
            designed_capacity    = $staticData.DesignedCapacity
            full_charged_capacity = $fullCharged.FullChargedCapacity
            health_percent       = if ($staticData.DesignedCapacity -gt 0) {
                [math]::Round(($fullCharged.FullChargedCapacity / $staticData.DesignedCapacity) * 100, 1)
            } else { $null }
        }
    } catch {
        $warnings += "Failed to get battery health data (WMI): $_"
        $result['battery_health'] = $null
    }
}

# Thermal info
if ($includeThermal) {
    try {
        $thermalZones = Get-CimInstance MSAcpi_ThermalZoneTemperature -Namespace root/wmi -ErrorAction Stop
        $result['thermal_zones'] = @($thermalZones | ForEach-Object {
            @{
                instance_name   = $_.InstanceName
                current_temp_c  = [math]::Round(($_.CurrentTemperature / 10) - 273.15, 1)
                critical_temp_c = if ($_.CriticalTripPoint) { [math]::Round(($_.CriticalTripPoint / 10) - 273.15, 1) } else { $null }
                raw_value       = $_.CurrentTemperature
            }
        })
    } catch {
        $warnings += "Failed to get thermal data (requires admin privileges): $_"
        $result['thermal_zones'] = $null
    }
}

# Recent power events
try {
    $startTime = (Get-Date).AddHours(-24)
    $events = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Kernel-Power'; StartTime=$startTime} -MaxEvents 10 -ErrorAction Stop
    $result['recent_power_events'] = @($events | ForEach-Object {
        @{
            id          = $_.Id
            time        = $_.TimeCreated.ToString('o')
            level       = $_.LevelDisplayName
            message     = ($_.Message -split "`n")[0].Trim()
        }
    })
} catch {
    $warnings += "Failed to get recent power events: $_"
    $result['recent_power_events'] = @()
}

# Sleep/hibernate config
try {
    $sleepStates = powercfg /availablesleepstates 2>&1 | Out-String
    $available = @()
    $unavailable = @()
    $currentSection = $null
    foreach ($line in ($sleepStates -split "`n")) {
        $line = $line.Trim()
        if ($line -match 'following sleep states are available') {
            $currentSection = 'available'
        } elseif ($line -match 'following sleep states are not available') {
            $currentSection = 'unavailable'
        } elseif ($line -match '^\s*\S' -and $currentSection) {
            if ($currentSection -eq 'available') { $available += $line }
            else { $unavailable += $line }
        }
    }
    $result['sleep_states'] = @{
        available   = $available
        unavailable = $unavailable
        raw         = $sleepStates.Trim()
    }
} catch {
    $warnings += "Failed to get sleep states: $_"
    $result['sleep_states'] = $null
}

$result['elevated'] = $isAdmin
$result['elevation_warnings'] = $warnings
$result | ConvertTo-Json -Depth 10
