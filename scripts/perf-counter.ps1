[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$params = $input | ConvertFrom-Json
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$warnings = @()
$result = @{}

$counterPath = if ($null -ne $params.counterPath -and $params.counterPath -ne '') { $params.counterPath } else { $null }
$counterSet = if ($null -ne $params.counterSet -and $params.counterSet -ne '') { $params.counterSet } else { $null }
$listMode = if ($null -ne $params.listMode) { $params.listMode } else { $false }
$sampleSeconds = if ($null -ne $params.sampleSeconds -and $params.sampleSeconds -gt 0) { [int]$params.sampleSeconds } else { 1 }

if ($listMode) {
    if ($counterSet) {
        # List paths for a specific counter set
        try {
            $set = Get-Counter -ListSet $counterSet -ErrorAction Stop
            $result['counter_set'] = $counterSet
            $result['paths'] = @($set | Select-Object -ExpandProperty Paths)
            $result['path_count'] = $result['paths'].Count
        } catch {
            $warnings += "Failed to list counter set '$counterSet': $_"
            $result['paths'] = @()
            $result['path_count'] = 0
        }
    } else {
        # List all counter sets
        try {
            $sets = Get-Counter -ListSet * -ErrorAction Stop |
                Select-Object CounterSetName, Description |
                Sort-Object CounterSetName
            $result['counter_sets'] = @($sets | ForEach-Object {
                @{
                    name        = $_.CounterSetName
                    description = $_.Description
                }
            })
            $result['counter_set_count'] = $result['counter_sets'].Count
        } catch {
            $warnings += "Failed to list counter sets: $_"
            $result['counter_sets'] = @()
            $result['counter_set_count'] = 0
        }
    }
} elseif ($counterPath) {
    # Sample a specific counter
    try {
        $samples = Get-Counter $counterPath -SampleInterval 1 -MaxSamples $sampleSeconds -ErrorAction Stop
        $result['counter_path'] = $counterPath
        $result['sample_count'] = $samples.Count
        $result['samples'] = @($samples | ForEach-Object {
            $timestamp = $_.Timestamp.ToString('o')
            $counterSamples = @($_.CounterSamples | ForEach-Object {
                @{
                    path         = $_.Path
                    cooked_value = $_.CookedValue
                    status       = $_.Status.ToString()
                }
            })
            @{
                timestamp       = $timestamp
                counter_samples = $counterSamples
            }
        })
    } catch {
        $warnings += "Failed to sample counter '$counterPath': $_"
        $result['samples'] = @()
        $result['sample_count'] = 0
    }
} else {
    $result['error'] = "Either 'counterPath' must be specified for sampling, or 'listMode' must be true to list available counters."
}

$result['elevated'] = $isAdmin
$result['elevation_warnings'] = $warnings
$result | ConvertTo-Json -Depth 10
