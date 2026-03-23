[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$params = $input | ConvertFrom-Json
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$warnings = @()
$result = @{}

$sortBy = if ($params.sortBy) { $params.sortBy } else { "WorkingSet64" }
$topN = if ($params.topN) { [int]$params.topN } else { 0 }
$nameFilter = if ($params.nameFilter) { $params.nameFilter } else { "" }
$includeCommandLine = if ($params.includeCommandLine -ne $null) { [bool]$params.includeCommandLine } else { $false }

# Collect processes
$processes = @()
try {
    $allProcs = Get-Process -ErrorAction SilentlyContinue

    if ($nameFilter -ne "") {
        $allProcs = $allProcs | Where-Object { $_.Name -like "*$nameFilter*" }
    }

    # Build CIM lookup if includeCommandLine is requested
    $cimLookup = @{}
    if ($includeCommandLine) {
        try {
            $cimProcs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
            foreach ($cp in $cimProcs) {
                $ownerName = $null
                try {
                    $ownerResult = Invoke-CimMethod -InputObject $cp -MethodName GetOwner -ErrorAction SilentlyContinue
                    if ($ownerResult -and $ownerResult.User) {
                        $ownerName = if ($ownerResult.Domain) { "$($ownerResult.Domain)\$($ownerResult.User)" } else { $ownerResult.User }
                    }
                } catch {
                    # Owner lookup can fail for system processes
                }
                $cimLookup[$cp.ProcessId] = @{
                    CommandLine = $cp.CommandLine
                    ParentProcessId = $cp.ParentProcessId
                    Owner = $ownerName
                }
            }
        } catch {
            $warnings += "Could not retrieve CIM process data: $($_.Exception.Message)"
        }
    }

    foreach ($proc in $allProcs) {
        try {
            $cpuValue = $null
            try {
                if ($proc.TotalProcessorTime) {
                    $cpuValue = [math]::Round($proc.TotalProcessorTime.TotalSeconds, 2)
                }
            } catch {
                $cpuValue = $null
            }

            $entry = @{
                Name = $proc.Name
                Id = $proc.Id
                CPU = $cpuValue
                WorkingSet64 = $proc.WorkingSet64
                PrivateMemorySize64 = $proc.PrivateMemorySize64
                ThreadCount = $proc.Threads.Count
                HandleCount = $proc.HandleCount
                MainWindowTitle = $proc.MainWindowTitle
                Responding = $proc.Responding
            }

            if ($includeCommandLine -and $cimLookup.ContainsKey($proc.Id)) {
                $entry['CommandLine'] = $cimLookup[$proc.Id].CommandLine
                $entry['ParentProcessId'] = $cimLookup[$proc.Id].ParentProcessId
                $entry['Owner'] = $cimLookup[$proc.Id].Owner
            }

            $processes += $entry
        } catch {
            # Skip individual process errors silently
        }
    }
} catch {
    $warnings += "Failed to enumerate processes: $($_.Exception.Message)"
}

# Sort
try {
    $sortField = switch ($sortBy.ToLower()) {
        "cpu"               { "CPU" }
        "memory"            { "WorkingSet64" }
        "workingset"        { "WorkingSet64" }
        "workingset64"      { "WorkingSet64" }
        "privatememory"     { "PrivateMemorySize64" }
        "privatememorysize64" { "PrivateMemorySize64" }
        "threads"           { "ThreadCount" }
        "threadcount"       { "ThreadCount" }
        "handles"           { "HandleCount" }
        "handlecount"       { "HandleCount" }
        "name"              { "Name" }
        "id"                { "Id" }
        "pid"               { "Id" }
        default             { "WorkingSet64" }
    }

    if ($sortField -eq "Name") {
        $processes = $processes | Sort-Object { $_[$sortField] }
    } else {
        $processes = $processes | Sort-Object { $_[$sortField] } -Descending
    }
} catch {
    $warnings += "Failed to sort processes by '$sortBy': $($_.Exception.Message)"
}

# Limit to topN
if ($topN -gt 0 -and $processes.Count -gt $topN) {
    $processes = $processes | Select-Object -First $topN
}

$result['processes'] = @($processes)
$result['total_count'] = $processes.Count
$result['sort_by'] = $sortBy
$result['elevated'] = $isAdmin
$result['elevation_warnings'] = $warnings
$result | ConvertTo-Json -Depth 10
