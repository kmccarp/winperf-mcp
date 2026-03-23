[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$params = $input | ConvertFrom-Json
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$warnings = @()
$result = @{}

$logName = if ($params.logName) { $params.logName } else { "System" }
$level = if ($params.level) { @($params.level) } else { @() }
$hoursBack = if ($params.hoursBack) { [int]$params.hoursBack } else { 24 }
$source = if ($params.source) { $params.source } else { "" }
$eventId = $params.eventId
$maxEvents = if ($params.maxEvents) { [int]$params.maxEvents } else { 50 }
$preset = if ($params.preset) { $params.preset } else { "" }

# Apply presets
if ($preset -ne "") {
    switch ($preset.ToLower()) {
        "bsod" {
            $logName = "System"
            $source = "BugCheck"
            $level = @("Critical", "Error")
            $hoursBack = 720
        }
        "disk_errors" {
            $logName = "System"
            $source = "disk,Ntfs,storahci,stornvme"
            $level = @("Critical", "Error", "Warning")
            $hoursBack = 720
        }
        "hardware_errors" {
            $logName = "System"
            $source = "WHEA-Logger"
            $level = @("Critical", "Error", "Warning")
            $hoursBack = 720
        }
        "power_events" {
            $logName = "System"
            $source = "Kernel-Power,Kernel-Boot"
            $level = @()
            $hoursBack = 720
        }
        "app_crashes" {
            $logName = "Application"
            $source = "Application Error,Application Hang,.NET Runtime"
            $level = @("Critical", "Error")
            $hoursBack = 720
        }
        "reliability" {
            # Handle reliability separately
            try {
                $reliabilityRecords = @()
                try {
                    $records = Get-CimInstance Win32_ReliabilityRecords -ErrorAction Stop | Select-Object -First 50
                    foreach ($rec in $records) {
                        $reliabilityRecords += @{
                            EventIdentifier = $rec.EventIdentifier
                            InsertionStrings = $rec.InsertionStrings
                            Logfile = $rec.Logfile
                            Message = if ($rec.Message -and $rec.Message.Length -gt 500) { $rec.Message.Substring(0, 500) + "..." } else { $rec.Message }
                            ProductName = $rec.ProductName
                            RecordNumber = $rec.RecordNumber
                            SourceName = $rec.SourceName
                            TimeGenerated = if ($rec.TimeGenerated) { $rec.TimeGenerated.ToString("o") } else { $null }
                            User = $rec.User
                        }
                    }
                } catch {
                    $warnings += "Could not retrieve reliability records: $($_.Exception.Message)"
                }

                $stabilityMetrics = @()
                try {
                    $metrics = Get-CimInstance Win32_ReliabilityStabilityMetrics -ErrorAction Stop | Select-Object -First 30
                    foreach ($m in $metrics) {
                        $stabilityMetrics += @{
                            SystemStabilityIndex = $m.SystemStabilityIndex
                            TimeGenerated = if ($m.TimeGenerated) { $m.TimeGenerated.ToString("o") } else { $null }
                        }
                    }
                } catch {
                    $warnings += "Could not retrieve stability metrics: $($_.Exception.Message)"
                }

                $result['preset'] = "reliability"
                $result['reliability_records'] = @($reliabilityRecords)
                $result['stability_metrics'] = @($stabilityMetrics)
                $result['elevated'] = $isAdmin
                $result['elevation_warnings'] = $warnings
                $result | ConvertTo-Json -Depth 10
                return
            } catch {
                $warnings += "Failed to collect reliability data: $($_.Exception.Message)"
                $result['preset'] = "reliability"
                $result['reliability_records'] = @()
                $result['stability_metrics'] = @()
                $result['elevated'] = $isAdmin
                $result['elevation_warnings'] = $warnings
                $result | ConvertTo-Json -Depth 10
                return
            }
        }
        default {
            $warnings += "Unknown preset '$preset', using provided parameters instead."
        }
    }
}

# Map level strings to level numbers
$levelMap = @{
    "critical"    = 1
    "error"       = 2
    "warning"     = 3
    "information" = 4
    "verbose"     = 5
}

# Build filter hashtable
try {
    $filter = @{
        LogName   = $logName
        StartTime = (Get-Date).AddHours(-$hoursBack)
    }

    # Add level filter
    if ($level.Count -gt 0) {
        $levelNumbers = @()
        foreach ($l in $level) {
            $lLower = $l.ToString().ToLower()
            if ($levelMap.ContainsKey($lLower)) {
                $levelNumbers += $levelMap[$lLower]
            }
        }
        if ($levelNumbers.Count -gt 0) {
            $filter['Level'] = $levelNumbers
        }
    }

    # Add source filter (can be comma-separated list)
    if ($source -ne "") {
        $sourceList = $source -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
        if ($sourceList.Count -eq 1) {
            $filter['ProviderName'] = $sourceList[0]
        } elseif ($sourceList.Count -gt 1) {
            $filter['ProviderName'] = $sourceList
        }
    }

    # Add event ID filter
    if ($eventId -ne $null -and $eventId -ne "") {
        $filter['Id'] = [int]$eventId
    }

    # Query events
    $events = @()
    try {
        $rawEvents = Get-WinEvent -FilterHashtable $filter -MaxEvents $maxEvents -ErrorAction Stop
        foreach ($evt in $rawEvents) {
            $msgTruncated = $null
            if ($evt.Message) {
                $msgTruncated = if ($evt.Message.Length -gt 500) { $evt.Message.Substring(0, 500) + "..." } else { $evt.Message }
            }
            $events += @{
                TimeCreated      = $evt.TimeCreated.ToString("o")
                Id               = $evt.Id
                Level            = $evt.Level
                LevelDisplayName = try { $evt.LevelDisplayName } catch { $null }
                ProviderName     = $evt.ProviderName
                Message          = $msgTruncated
            }
        }
    } catch [Exception] {
        if ($_.Exception.Message -like "*No events were found*") {
            # No events matching the criteria is not an error
        } else {
            $warnings += "Error querying events: $($_.Exception.Message)"
        }
    }

    $result['events'] = @($events)
    $result['total_count'] = $events.Count
    $result['filter'] = @{
        LogName   = $logName
        HoursBack = $hoursBack
        Level     = $level
        Source    = $source
        EventId   = $eventId
        MaxEvents = $maxEvents
    }
    if ($preset -ne "") {
        $result['preset'] = $preset
    }
} catch {
    $warnings += "Failed to build event query: $($_.Exception.Message)"
    $result['events'] = @()
    $result['total_count'] = 0
}

$result['elevated'] = $isAdmin
$result['elevation_warnings'] = $warnings
$result | ConvertTo-Json -Depth 10
