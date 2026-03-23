[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$params = $input | ConvertFrom-Json
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$warnings = @()
$result = @{}

$path = if ($null -ne $params.path -and $params.path -ne '') { $params.path } else { 'C:\' }
$mode = if ($null -ne $params.mode -and $params.mode -ne '') { $params.mode } else { 'space_analysis' }
$minSizeMb = if ($null -ne $params.minSizeMb -and $params.minSizeMb -gt 0) { [double]$params.minSizeMb } else { 100 }
$topN = if ($null -ne $params.topN -and $params.topN -gt 0) { [int]$params.topN } else { 20 }
$maxDepth = if ($null -ne $params.maxDepth -and $params.maxDepth -ge 0) { [int]$params.maxDepth } else { 3 }

$result['mode'] = $mode
$result['path'] = $path

switch ($mode) {
    'large_files' {
        try {
            $minBytes = $minSizeMb * 1MB
            $files = Get-ChildItem -Path $path -Recurse -File -Depth $maxDepth -ErrorAction SilentlyContinue |
                Where-Object { $_.Length -ge $minBytes } |
                Sort-Object Length -Descending |
                Select-Object -First $topN

            $result['large_files'] = @($files | ForEach-Object {
                @{
                    full_name       = $_.FullName
                    size_bytes      = $_.Length
                    size_mb         = [math]::Round($_.Length / 1MB, 2)
                    last_write_time = $_.LastWriteTime.ToString('o')
                    extension       = $_.Extension
                }
            })
            $result['file_count'] = $result['large_files'].Count
            $result['min_size_mb'] = $minSizeMb
            $result['max_depth'] = $maxDepth
        } catch {
            $warnings += "Failed to scan for large files: $_"
            $result['large_files'] = @()
            $result['file_count'] = 0
        }
    }

    'dir_sizes' {
        try {
            $dirs = Get-ChildItem -Path $path -Directory -ErrorAction Stop
            $dirSizes = @()
            foreach ($dir in $dirs) {
                try {
                    $size = (Get-ChildItem -Path $dir.FullName -Recurse -File -ErrorAction SilentlyContinue |
                        Measure-Object Length -Sum).Sum
                    if ($null -eq $size) { $size = 0 }
                    $dirSizes += @{
                        name       = $dir.Name
                        full_path  = $dir.FullName
                        size_bytes = [long]$size
                        size_mb    = [math]::Round($size / 1MB, 2)
                        size_gb    = [math]::Round($size / 1GB, 2)
                    }
                } catch {
                    $warnings += "Failed to compute size for '$($dir.FullName)': $_"
                }
            }
            $result['directories'] = @($dirSizes | Sort-Object { $_.size_bytes } -Descending | Select-Object -First $topN)
            $result['directory_count'] = $result['directories'].Count
        } catch {
            $warnings += "Failed to enumerate directories in '$path': $_"
            $result['directories'] = @()
            $result['directory_count'] = 0
        }
    }

    'temp_files' {
        $tempDirs = @(
            $env:TEMP,
            "$env:LOCALAPPDATA\Temp",
            "C:\Windows\Temp"
        ) | Select-Object -Unique

        $tempAnalysis = @()
        foreach ($tempDir in $tempDirs) {
            try {
                if (Test-Path $tempDir) {
                    $files = Get-ChildItem -Path $tempDir -Recurse -File -ErrorAction SilentlyContinue
                    $totalSize = ($files | Measure-Object Length -Sum).Sum
                    if ($null -eq $totalSize) { $totalSize = 0 }
                    $oldest = $files | Sort-Object LastWriteTime | Select-Object -First 1
                    $newest = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1

                    $tempAnalysis += @{
                        path        = $tempDir
                        file_count  = $files.Count
                        total_size_bytes = [long]$totalSize
                        total_size_mb    = [math]::Round($totalSize / 1MB, 2)
                        oldest_file_date = if ($oldest) { $oldest.LastWriteTime.ToString('o') } else { $null }
                        newest_file_date = if ($newest) { $newest.LastWriteTime.ToString('o') } else { $null }
                    }
                } else {
                    $tempAnalysis += @{
                        path   = $tempDir
                        exists = $false
                    }
                }
            } catch {
                $warnings += "Failed to analyze temp directory '$tempDir': $_"
            }
        }
        $result['temp_directories'] = $tempAnalysis
    }

    'space_analysis' {
        # Logical disk info
        try {
            $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop
            $result['logical_disks'] = @($disks | ForEach-Object {
                @{
                    device_id   = $_.DeviceID
                    volume_name = $_.VolumeName
                    file_system = $_.FileSystem
                    size_bytes  = $_.Size
                    size_gb     = [math]::Round($_.Size / 1GB, 2)
                    free_bytes  = $_.FreeSpace
                    free_gb     = [math]::Round($_.FreeSpace / 1GB, 2)
                    used_gb     = [math]::Round(($_.Size - $_.FreeSpace) / 1GB, 2)
                    used_percent = if ($_.Size -gt 0) { [math]::Round((($_.Size - $_.FreeSpace) / $_.Size) * 100, 1) } else { 0 }
                }
            })
        } catch {
            $warnings += "Failed to get logical disk info: $_"
            $result['logical_disks'] = @()
        }

        # Recycle bin size
        try {
            $shell = New-Object -ComObject Shell.Application
            $recycleBin = $shell.NameSpace(10)
            $items = $recycleBin.Items()
            $totalSize = 0
            $itemCount = $items.Count
            foreach ($item in $items) {
                $totalSize += $recycleBin.GetDetailsOf($item, 2) -replace '[^\d]', ''
            }
            # Alternative approach using folder size
            try {
                $rbSize = 0
                $rbCount = 0
                Get-ChildItem 'C:\$Recycle.Bin' -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    if (-not $_.PSIsContainer) {
                        $rbSize += $_.Length
                        $rbCount++
                    }
                }
                $result['recycle_bin'] = @{
                    item_count  = $rbCount
                    size_bytes  = [long]$rbSize
                    size_mb     = [math]::Round($rbSize / 1MB, 2)
                }
            } catch {
                $result['recycle_bin'] = @{
                    item_count = $itemCount
                    note       = "Could not determine exact size"
                }
            }
        } catch {
            $warnings += "Failed to get recycle bin info: $_"
            $result['recycle_bin'] = $null
        }
    }

    default {
        $result['error'] = "Unknown mode '$mode'. Valid modes: large_files, dir_sizes, temp_files, space_analysis"
    }
}

$result['elevated'] = $isAdmin
$result['elevation_warnings'] = $warnings
$result | ConvertTo-Json -Depth 10
