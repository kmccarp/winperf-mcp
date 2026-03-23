[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$params = $input | ConvertFrom-Json
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$warnings = @()
$result = @{}

$statusFilter = if ($params.statusFilter) { $params.statusFilter } else { "" }
$nameFilter = if ($params.nameFilter) { $params.nameFilter } else { "" }
$includeDependencies = if ($params.includeDependencies -ne $null) { [bool]$params.includeDependencies } else { $false }

$services = @()
try {
    $cimServices = Get-CimInstance Win32_Service -ErrorAction Stop

    # Filter by status
    if ($statusFilter -ne "") {
        switch ($statusFilter.ToLower()) {
            "running" {
                $cimServices = $cimServices | Where-Object { $_.State -eq "Running" }
            }
            "stopped" {
                $cimServices = $cimServices | Where-Object { $_.State -eq "Stopped" }
            }
        }
    }

    # Filter by name
    if ($nameFilter -ne "") {
        $cimServices = $cimServices | Where-Object {
            $_.Name -like "*$nameFilter*" -or $_.DisplayName -like "*$nameFilter*"
        }
    }

    # Sort by DisplayName
    $cimServices = $cimServices | Sort-Object DisplayName

    foreach ($svc in $cimServices) {
        try {
            $entry = @{
                Name        = $svc.Name
                DisplayName = $svc.DisplayName
                State       = $svc.State
                StartMode   = $svc.StartMode
                ProcessId   = $svc.ProcessId
                PathName    = $svc.PathName
                Description = $svc.Description
                StartName   = $svc.StartName
            }

            # Get dependencies if requested
            if ($includeDependencies) {
                try {
                    $psSvc = Get-Service -Name $svc.Name -ErrorAction Stop
                    $dependsOn = @()
                    foreach ($dep in $psSvc.ServicesDependedOn) {
                        $dependsOn += @{
                            Name        = $dep.ServiceName
                            DisplayName = $dep.DisplayName
                            Status      = $dep.Status.ToString()
                        }
                    }
                    $dependents = @()
                    foreach ($dep in $psSvc.DependentServices) {
                        $dependents += @{
                            Name        = $dep.ServiceName
                            DisplayName = $dep.DisplayName
                            Status      = $dep.Status.ToString()
                        }
                    }
                    $entry['ServicesDependedOn'] = @($dependsOn)
                    $entry['DependentServices'] = @($dependents)
                } catch {
                    $entry['ServicesDependedOn'] = @()
                    $entry['DependentServices'] = @()
                    $warnings += "Could not get dependencies for service '$($svc.Name)': $($_.Exception.Message)"
                }
            }

            $services += $entry
        } catch {
            # Skip individual service errors
        }
    }
} catch {
    $warnings += "Failed to enumerate services: $($_.Exception.Message)"
}

$result['services'] = @($services)
$result['total_count'] = $services.Count
$result['filters'] = @{
    StatusFilter = $statusFilter
    NameFilter   = $nameFilter
    IncludeDependencies = $includeDependencies
}
$result['elevated'] = $isAdmin
$result['elevation_warnings'] = $warnings
$result | ConvertTo-Json -Depth 10
