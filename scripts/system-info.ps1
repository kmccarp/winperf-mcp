[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$params = $input | ConvertFrom-Json
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$warnings = @()
$result = @{}

$sections = @()
if ($params.sections) {
    $sections = @($params.sections)
}
if ($sections.Count -eq 0) {
    $sections = @("all")
}

$collectAll = $sections -contains "all"

$result['hostname'] = $env:COMPUTERNAME

# OS
if ($collectAll -or $sections -contains "os") {
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $os = Get-CimInstance Win32_OperatingSystem
        $uptime = (Get-Date) - $os.LastBootUpTime
        $result['os'] = @{
            caption        = [string]$os.Caption
            version        = [string]$os.Version
            build_number   = [string]$os.BuildNumber
            architecture   = [string]$os.OSArchitecture
            last_boot_time = [string]$os.LastBootUpTime
            uptime         = @{
                days    = [int]$uptime.Days
                hours   = [int]$uptime.Hours
                minutes = [int]$uptime.Minutes
                seconds = [int]$uptime.Seconds
                total_seconds = [math]::Round($uptime.TotalSeconds, 0)
            }
        }
    } catch {
        $warnings += "OS: $($_.Exception.Message)"
    }
}

# CPU
if ($collectAll -or $sections -contains "cpu") {
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $cpus = @(Get-CimInstance Win32_Processor)
        $cpuList = @()
        foreach ($cpu in $cpus) {
            $cpuList += @{
                name                       = [string]$cpu.Name
                number_of_cores            = [int]$cpu.NumberOfCores
                number_of_logical_processors = [int]$cpu.NumberOfLogicalProcessors
                max_clock_speed_mhz        = [int]$cpu.MaxClockSpeed
                current_clock_speed_mhz    = [int]$cpu.CurrentClockSpeed
            }
        }
        $result['cpu'] = $cpuList
    } catch {
        $warnings += "CPU: $($_.Exception.Message)"
    }
}

# GPU
if ($collectAll -or $sections -contains "gpu") {
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $gpus = @(Get-CimInstance Win32_VideoController)
        $gpuList = @()
        foreach ($gpu in $gpus) {
            $gpuList += @{
                name           = [string]$gpu.Name
                driver_version = [string]$gpu.DriverVersion
                adapter_ram    = $gpu.AdapterRAM
                status         = [string]$gpu.Status
            }
        }
        $result['gpu'] = $gpuList
    } catch {
        $warnings += "GPU: $($_.Exception.Message)"
    }
}

# BIOS
if ($collectAll -or $sections -contains "bios") {
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $bios = Get-CimInstance Win32_BIOS
        $result['bios'] = @{
            manufacturer       = [string]$bios.Manufacturer
            smbios_bios_version = [string]$bios.SMBIOSBIOSVersion
            release_date       = [string]$bios.ReleaseDate
        }
    } catch {
        $warnings += "BIOS: $($_.Exception.Message)"
    }
}

# Motherboard
if ($collectAll -or $sections -contains "motherboard") {
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $board = Get-CimInstance Win32_BaseBoard
        $result['motherboard'] = @{
            manufacturer  = [string]$board.Manufacturer
            product       = [string]$board.Product
            serial_number = [string]$board.SerialNumber
        }
    } catch {
        $warnings += "Motherboard: $($_.Exception.Message)"
    }
}

# Memory Hardware
if ($collectAll -or $sections -contains "memory_hardware") {
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $sticks = @(Get-CimInstance Win32_PhysicalMemory)
        $stickList = @()
        $totalCapacity = [long]0
        foreach ($stick in $sticks) {
            $cap = [long]$stick.Capacity
            $totalCapacity += $cap
            $stickList += @{
                manufacturer = [string]$stick.Manufacturer
                capacity     = $cap
                capacity_gb  = [math]::Round($cap / 1GB, 2)
                speed_mhz    = [int]$stick.Speed
                memory_type  = [int]$stick.MemoryType
            }
        }
        $result['memory_hardware'] = @{
            sticks         = $stickList
            total_capacity = $totalCapacity
            total_capacity_gb = [math]::Round($totalCapacity / 1GB, 2)
            stick_count    = $stickList.Count
        }
    } catch {
        $warnings += "Memory Hardware: $($_.Exception.Message)"
    }
}

$result['elevated'] = $isAdmin
$result['elevation_warnings'] = $warnings
$result | ConvertTo-Json -Depth 10
