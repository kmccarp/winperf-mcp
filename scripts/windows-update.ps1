[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$params = $input | ConvertFrom-Json
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$warnings = @()
$result = @{}

$historyCount = if ($params.historyCount) { [int]$params.historyCount } else { 20 }
$includePending = if ($params.includePending -ne $null) { [bool]$params.includePending } else { $false }

# --- Installed hotfixes ---
try {
    $hotfixes = @()
    $rawHotfixes = Get-HotFix -ErrorAction Stop | Sort-Object InstalledOn -Descending -ErrorAction SilentlyContinue | Select-Object -First $historyCount
    foreach ($hf in $rawHotfixes) {
        $hotfixes += @{
            HotFixID    = $hf.HotFixID
            Description = $hf.Description
            InstalledOn = if ($hf.InstalledOn) { $hf.InstalledOn.ToString("o") } else { $null }
            InstalledBy = $hf.InstalledBy
        }
    }
    $result['installed_updates'] = @($hotfixes)
} catch {
    $warnings += "Failed to retrieve installed hotfixes: $($_.Exception.Message)"
    $result['installed_updates'] = @()
}

# --- Windows Update service state ---
try {
    $wuService = Get-Service wuauserv -ErrorAction Stop
    $result['update_service'] = @{
        Status    = $wuService.Status.ToString()
        StartType = $wuService.StartType.ToString()
    }
} catch {
    $warnings += "Could not query Windows Update service: $($_.Exception.Message)"
    $result['update_service'] = $null
}

# --- Pending updates via COM ---
if ($includePending) {
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $searchResult = $searcher.Search("IsInstalled=0")
        $pending = @()
        foreach ($update in $searchResult.Updates) {
            $pending += @{
                Title        = $update.Title
                IsDownloaded = $update.IsDownloaded
                IsMandatory  = $update.IsMandatory
            }
        }
        $result['pending_updates'] = @($pending)
    } catch {
        $warnings += "Could not check pending updates: $($_.Exception.Message)"
        $result['pending_updates'] = @()
    }
}

# --- Recent update activity from event log ---
try {
    $updateEvents = @()
    $rawEvents = Get-WinEvent -FilterHashtable @{
        LogName      = 'System'
        ProviderName = 'Microsoft-Windows-WindowsUpdateClient'
        StartTime    = (Get-Date).AddDays(-30)
    } -MaxEvents 20 -ErrorAction Stop

    foreach ($evt in $rawEvents) {
        $msgTruncated = $null
        if ($evt.Message) {
            $msgTruncated = if ($evt.Message.Length -gt 500) { $evt.Message.Substring(0, 500) + "..." } else { $evt.Message }
        }
        $updateEvents += @{
            TimeCreated      = $evt.TimeCreated.ToString("o")
            Id               = $evt.Id
            Level            = $evt.Level
            LevelDisplayName = try { $evt.LevelDisplayName } catch { $null }
            Message          = $msgTruncated
        }
    }
    $result['recent_update_events'] = @($updateEvents)
} catch [Exception] {
    if ($_.Exception.Message -like "*No events were found*") {
        $result['recent_update_events'] = @()
    } else {
        $warnings += "Could not query update events: $($_.Exception.Message)"
        $result['recent_update_events'] = @()
    }
}

$result['elevated'] = $isAdmin
$result['elevation_warnings'] = $warnings
$result | ConvertTo-Json -Depth 10
