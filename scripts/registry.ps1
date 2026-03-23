[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$params = $input | ConvertFrom-Json
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$warnings = @()
$result = @{}

$keyPath = if ($null -ne $params.keyPath -and $params.keyPath -ne '') { $params.keyPath } else { $null }
$valueName = if ($null -ne $params.valueName -and $params.valueName -ne '') { $params.valueName } else { $null }
$preset = if ($null -ne $params.preset -and $params.preset -ne '') { $params.preset } else { $null }

# Determine the registry path
$regPath = $null

if ($preset) {
    $presetMap = @{
        'power'               = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
        'memory_management'   = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
        'network_tuning'      = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
        'filesystem'          = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
        'prefetch'            = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters'
        'superfetch'          = 'HKLM:\SYSTEM\CurrentControlSet\Services\SysMain'
    }

    if ($presetMap.ContainsKey($preset)) {
        $regPath = $presetMap[$preset]
        $result['preset'] = $preset
    } else {
        $result['error'] = "Unknown preset '$preset'. Valid presets: $($presetMap.Keys -join ', ')"
        $result['elevated'] = $isAdmin
        $result['elevation_warnings'] = $warnings
        $result | ConvertTo-Json -Depth 10
        return
    }
} elseif ($keyPath) {
    $regPath = $keyPath
} else {
    $result['error'] = "Either 'keyPath' or 'preset' must be provided."
    $result['elevated'] = $isAdmin
    $result['elevation_warnings'] = $warnings
    $result | ConvertTo-Json -Depth 10
    return
}

$result['registry_path'] = $regPath

# Check if path exists
if (-not (Test-Path $regPath)) {
    $result['error'] = "Registry path '$regPath' does not exist."
    $result['elevated'] = $isAdmin
    $result['elevation_warnings'] = $warnings
    $result | ConvertTo-Json -Depth 10
    return
}

# Get registry values
try {
    if ($valueName) {
        # Get a specific value
        $prop = Get-ItemProperty -Path $regPath -Name $valueName -ErrorAction Stop
        $result['value'] = @{
            name = $valueName
            data = $prop.$valueName
            type = (Get-Item $regPath).GetValueKind($valueName).ToString()
        }
    } else {
        # Get all values, stripping PS* built-in properties
        $props = Get-ItemProperty -Path $regPath -ErrorAction Stop
        $values = @{}
        $psBuiltins = @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')
        $props.PSObject.Properties | ForEach-Object {
            if ($_.Name -notin $psBuiltins) {
                $values[$_.Name] = $_.Value
            }
        }
        $result['values'] = $values
        $result['value_count'] = $values.Count
    }
} catch {
    $warnings += "Failed to read registry values: $_"
    $result['values'] = @{}
    $result['value_count'] = 0
}

# List subkeys
try {
    $subkeys = Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue | Select-Object Name
    $result['subkeys'] = @($subkeys | ForEach-Object {
        $_.Name
    })
    $result['subkey_count'] = $result['subkeys'].Count
} catch {
    $warnings += "Failed to list subkeys: $_"
    $result['subkeys'] = @()
    $result['subkey_count'] = 0
}

$result['elevated'] = $isAdmin
$result['elevation_warnings'] = $warnings
$result | ConvertTo-Json -Depth 10
