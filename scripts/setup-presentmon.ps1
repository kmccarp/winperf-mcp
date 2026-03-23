# Downloads PresentMon CLI binary to vendor/ directory
$vendorDir = Join-Path $PSScriptRoot '..' 'vendor'
$exePath = Join-Path $vendorDir 'PresentMon.exe'

if (Test-Path $exePath) {
    Write-Host "PresentMon already exists at $exePath"
    exit 0
}

if (-not (Test-Path $vendorDir)) {
    New-Item -ItemType Directory -Path $vendorDir -Force | Out-Null
}

$url = 'https://github.com/GameTechDev/PresentMon/releases/download/v2.4.0/PresentMon-2.4.0-x64.exe'
Write-Host "Downloading PresentMon from $url..."

try {
    Invoke-WebRequest -Uri $url -OutFile $exePath -UseBasicParsing
    Write-Host "PresentMon installed to $exePath"
} catch {
    Write-Warning "Failed to download PresentMon: $($_.Exception.Message)"
    Write-Warning "FPS metrics will not be available. You can manually download PresentMon from:"
    Write-Warning "  https://github.com/GameTechDev/PresentMon/releases"
    Write-Warning "Place the exe as: $exePath"
    exit 0  # Don't fail the build
}
