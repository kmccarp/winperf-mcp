[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$params = $input | ConvertFrom-Json
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$warnings = @()
$result = @{}

$diskIndex = $null
if ($null -ne $params.diskIndex) { $diskIndex = [int]$params.diskIndex }
$includeSmart = $false
if ($params.includeSmart -eq $true) { $includeSmart = $true }
$sampleSeconds = 1
if ($params.sampleSeconds -and $params.sampleSeconds -gt 0) { $sampleSeconds = [int]$params.sampleSeconds }

# Disk performance counters
try {
    $ErrorActionPreference = 'SilentlyContinue'
    $diskCounters = @(
        '\PhysicalDisk(*)\Disk Reads/sec',
        '\PhysicalDisk(*)\Disk Writes/sec',
        '\PhysicalDisk(*)\Disk Read Bytes/sec',
        '\PhysicalDisk(*)\Disk Write Bytes/sec',
        '\PhysicalDisk(*)\Avg. Disk sec/Read',
        '\PhysicalDisk(*)\Avg. Disk sec/Write',
        '\PhysicalDisk(*)\Current Disk Queue Length',
        '\PhysicalDisk(*)\% Idle Time'
    )
    $samples = Get-Counter -Counter $diskCounters -SampleInterval 1 -MaxSamples $sampleSeconds

    # Accumulate values per instance per counter
    $diskData = @{}
    foreach ($sample in $samples) {
        foreach ($cs in $sample.CounterSamples) {
            $instance = $cs.InstanceName
            if ($instance -eq '_total') { continue }
            if (-not $diskData.ContainsKey($instance)) {
                $diskData[$instance] = @{}
            }
            $counterName = ($cs.Path -replace '.*\\physicaldisk\([^)]*\)\\', '') -replace ' ', '_' -replace '/', '_per_' -replace '\.', '' -replace '%', 'pct'
            $counterName = $counterName.ToLower()
            if (-not $diskData[$instance].ContainsKey($counterName)) {
                $diskData[$instance][$counterName] = @()
            }
            $diskData[$instance][$counterName] += $cs.CookedValue
        }
    }

    # Average samples
    $perfResults = @{}
    foreach ($instance in $diskData.Keys) {
        # If diskIndex specified, filter by checking if instance starts with the index
        if ($null -ne $diskIndex) {
            if (-not $instance.StartsWith("$diskIndex ")) { continue }
        }
        $perfResults[$instance] = @{}
        foreach ($counter in $diskData[$instance].Keys) {
            $vals = $diskData[$instance][$counter]
            if ($vals.Count -gt 0) {
                $perfResults[$instance][$counter] = [math]::Round(($vals | Measure-Object -Average).Average, 4)
            }
        }
    }
    $result['performance_counters'] = $perfResults
} catch {
    $warnings += "Disk counters: $($_.Exception.Message)"
}

# Physical disk drives
try {
    $ErrorActionPreference = 'SilentlyContinue'
    $drives = @(Get-CimInstance Win32_DiskDrive)
    $driveList = @()
    foreach ($d in $drives) {
        if ($null -ne $diskIndex -and $d.Index -ne $diskIndex) { continue }
        $driveList += @{
            index          = [int]$d.Index
            model          = [string]$d.Model
            media_type     = [string]$d.MediaType
            size           = [long]$d.Size
            size_gb        = [math]::Round([long]$d.Size / 1GB, 2)
            interface_type = [string]$d.InterfaceType
            status         = [string]$d.Status
        }
    }
    $result['disk_drives'] = $driveList
} catch {
    $warnings += "Disk drives: $($_.Exception.Message)"
}

# Logical disks (partitions)
try {
    $ErrorActionPreference = 'SilentlyContinue'
    $logicalDisks = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3")
    $ldList = @()
    foreach ($ld in $logicalDisks) {
        $usedSpace = [long]$ld.Size - [long]$ld.FreeSpace
        $usagePercent = 0
        if ([long]$ld.Size -gt 0) {
            $usagePercent = [math]::Round(($usedSpace / [long]$ld.Size) * 100, 2)
        }
        $ldList += @{
            device_id     = [string]$ld.DeviceID
            size          = [long]$ld.Size
            size_gb       = [math]::Round([long]$ld.Size / 1GB, 2)
            free_space    = [long]$ld.FreeSpace
            free_space_gb = [math]::Round([long]$ld.FreeSpace / 1GB, 2)
            used_space    = $usedSpace
            used_space_gb = [math]::Round($usedSpace / 1GB, 2)
            usage_percent = $usagePercent
            file_system   = [string]$ld.FileSystem
            volume_name   = [string]$ld.VolumeName
        }
    }
    $result['logical_disks'] = $ldList
} catch {
    $warnings += "Logical disks: $($_.Exception.Message)"
}

# SMART / Storage Reliability
if ($includeSmart) {
    # Physical disk health info
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $physDisks = @(Get-PhysicalDisk)
        $healthList = @()
        foreach ($pd in $physDisks) {
            if ($null -ne $diskIndex -and $pd.DeviceId -ne "$diskIndex") { continue }
            $healthList += @{
                device_id    = [string]$pd.DeviceId
                friendly_name = [string]$pd.FriendlyName
                health_status = [string]$pd.HealthStatus
                media_type   = [string]$pd.MediaType
                bus_type     = [string]$pd.BusType
                size_gb      = [math]::Round([long]$pd.Size / 1GB, 2)
            }
        }
        $result['physical_disk_health'] = $healthList
    } catch {
        $warnings += "Physical disk health: $($_.Exception.Message)"
    }

    # Storage reliability counters (requires admin)
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $physDisks = @(Get-PhysicalDisk)
        $reliabilityList = @()
        foreach ($pd in $physDisks) {
            if ($null -ne $diskIndex -and $pd.DeviceId -ne "$diskIndex") { continue }
            $rel = $pd | Get-StorageReliabilityCounter
            if ($rel) {
                $reliabilityList += @{
                    device_id         = [string]$pd.DeviceId
                    friendly_name     = [string]$pd.FriendlyName
                    temperature       = $rel.Temperature
                    wear              = $rel.Wear
                    read_errors_total = $rel.ReadErrorsTotal
                    write_errors_total = $rel.WriteErrorsTotal
                    power_on_hours    = $rel.PowerOnHours
                }
            }
        }
        $result['storage_reliability'] = $reliabilityList
    } catch {
        $warnings += "Storage reliability: Requires elevated privileges. $($_.Exception.Message)"
    }
}

$result['elevated'] = $isAdmin
$result['elevation_warnings'] = $warnings
$result | ConvertTo-Json -Depth 10
