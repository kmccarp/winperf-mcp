[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$params = $input | ConvertFrom-Json
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$warnings = @()
$result = @{}

$includeTasks = if ($params.includeTasks -ne $null) { [bool]$params.includeTasks } else { $true }
$includeStartup = if ($params.includeStartup -ne $null) { [bool]$params.includeStartup } else { $true }
$taskStateFilter = if ($params.taskStateFilter) { $params.taskStateFilter } else { "all" }

# --- Startup items from registry ---
if ($includeStartup) {
    $startupItems = @()

    $runKeys = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Location = 'HKLM\Run' }
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Location = 'HKCU\Run' }
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Location = 'HKLM\Run (Wow6432Node)' }
        @{ Path = 'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Location = 'HKCU\Run (Wow6432Node)' }
    )

    foreach ($key in $runKeys) {
        try {
            if (Test-Path $key.Path) {
                $props = Get-ItemProperty $key.Path -ErrorAction SilentlyContinue
                if ($props) {
                    # Get property names, excluding PowerShell built-in properties
                    $psBuiltinProps = @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')
                    $propNames = $props.PSObject.Properties | Where-Object { $psBuiltinProps -notcontains $_.Name } | Select-Object -ExpandProperty Name

                    foreach ($name in $propNames) {
                        try {
                            $startupItems += @{
                                Name     = $name
                                Command  = $props.$name
                                Location = $key.Location
                                Source   = "Registry"
                            }
                        } catch {
                            # Skip individual property errors
                        }
                    }
                }
            }
        } catch {
            $warnings += "Could not read registry key '$($key.Path)': $($_.Exception.Message)"
        }
    }

    $result['startup_items'] = @($startupItems)
}

# --- Scheduled Tasks ---
if ($includeTasks) {
    $taskList = @()

    try {
        $tasks = Get-ScheduledTask -ErrorAction Stop

        # Filter by state
        if ($taskStateFilter -ne "all") {
            $tasks = $tasks | Where-Object { $_.State -eq $taskStateFilter }
        }

        # Limit to 100 tasks
        $tasks = $tasks | Select-Object -First 100

        foreach ($task in $tasks) {
            try {
                $taskEntry = @{
                    TaskName    = $task.TaskName
                    TaskPath    = $task.TaskPath
                    State       = $task.State.ToString()
                    Description = $task.Description
                }

                # Get additional info
                try {
                    $taskInfo = Get-ScheduledTaskInfo -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue
                    if ($taskInfo) {
                        $taskEntry['LastRunTime'] = if ($taskInfo.LastRunTime -and $taskInfo.LastRunTime -ne [DateTime]::MinValue) { $taskInfo.LastRunTime.ToString("o") } else { $null }
                        $taskEntry['NextRunTime'] = if ($taskInfo.NextRunTime -and $taskInfo.NextRunTime -ne [DateTime]::MinValue) { $taskInfo.NextRunTime.ToString("o") } else { $null }
                        $taskEntry['LastTaskResult'] = $taskInfo.LastTaskResult
                    }
                } catch {
                    $taskEntry['LastRunTime'] = $null
                    $taskEntry['NextRunTime'] = $null
                    $taskEntry['LastTaskResult'] = $null
                }

                $taskList += $taskEntry
            } catch {
                # Skip individual task errors
            }
        }
    } catch {
        $warnings += "Failed to enumerate scheduled tasks: $($_.Exception.Message)"
    }

    $result['scheduled_tasks'] = @($taskList)
    $result['scheduled_tasks_count'] = $taskList.Count
}

$result['elevated'] = $isAdmin
$result['elevation_warnings'] = $warnings
$result | ConvertTo-Json -Depth 10
