[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$params = $input | ConvertFrom-Json
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$warnings = @()
$result = @{}

$includeDrivers = if ($null -ne $params.includeDrivers) { $params.includeDrivers } else { $false }
$nameFilter = if ($null -ne $params.nameFilter -and $params.nameFilter -ne '') { $params.nameFilter } else { $null }
$unsignedDriversOnly = if ($null -ne $params.unsignedDriversOnly) { $params.unsignedDriversOnly } else { $false }

# Installed software from registry
try {
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $software = Get-ItemProperty $regPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName } |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallDate, InstallLocation, EstimatedSize

    if ($nameFilter) {
        $software = $software | Where-Object { $_.DisplayName -like "*$nameFilter*" }
    }

    $software = $software | Sort-Object DisplayName

    $result['software'] = @($software | ForEach-Object {
        @{
            display_name     = $_.DisplayName
            display_version  = $_.DisplayVersion
            publisher        = $_.Publisher
            install_date     = $_.InstallDate
            install_location = $_.InstallLocation
            estimated_size_kb = $_.EstimatedSize
        }
    })
    $result['software_count'] = $result['software'].Count
} catch {
    $warnings += "Failed to enumerate installed software: $_"
    $result['software'] = @()
    $result['software_count'] = 0
}

# Drivers
if ($includeDrivers) {
    try {
        $drivers = Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop |
            Select-Object DeviceName, DriverVersion, Manufacturer, IsSigned, DriverDate

        if ($unsignedDriversOnly) {
            $drivers = $drivers | Where-Object { $_.IsSigned -eq $false }
        }

        $result['drivers'] = @($drivers | ForEach-Object {
            @{
                device_name    = $_.DeviceName
                driver_version = $_.DriverVersion
                manufacturer   = $_.Manufacturer
                is_signed      = $_.IsSigned
                driver_date    = if ($_.DriverDate) { $_.DriverDate.ToString('o') } else { $null }
            }
        })
        $result['driver_count'] = $result['drivers'].Count
    } catch {
        $warnings += "Failed to enumerate drivers: $_"
        $result['drivers'] = @()
        $result['driver_count'] = 0
    }
}

$result['elevated'] = $isAdmin
$result['elevation_warnings'] = $warnings
$result | ConvertTo-Json -Depth 10
