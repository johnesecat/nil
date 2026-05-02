param([switch]$Force)

$InstallDir = "$env:USERPROFILE\NilGame"
$RepoUrl = "https://raw.githubusercontent.com/johnesecat/nil/main"
$VersionFile = "$InstallDir\version.txt"
$LocalVersion = "0.0.0"
$RemoteVersion = "0.0.0"

# 1. Check Existing Install
if (Test-Path $InstallDir) {
    if (Test-Path $VersionFile) {
        $LocalVersion = Get-Content $VersionFile
        Write-Host "Existing installation found: v$LocalVersion" -ForegroundColor Cyan
    }
    
    # 2. Fetch Remote Version
    try {
        $RemoteVersion = Invoke-RestMethod -Uri "$RepoUrl/version.txt" -UseBasicParsing
        Write-Host "Latest version available: v$RemoteVersion" -ForegroundColor Green
    } catch {
        Write-Host "Could not check remote version (offline?). Proceeding with local files." -ForegroundColor Yellow
        $RemoteVersion = $LocalVersion
    }

    # 3. Compare Versions
    if ($LocalVersion -eq $RemoteVersion -and -not $Force) {
        Write-Host "You are already up to date!" -ForegroundColor Green
        $choice = Read-Host "Re-install anyway? (y/n)"
        if ($choice -ne 'y') {
            # Launch Game
            if (Test-Path "$InstallDir\DoomEngine.ps1") {
                Write-Host "Launching game..."
                & "$InstallDir\DoomEngine.ps1"
                exit 0
            }
        }
    } else {
        Write-Host "Update available! Upgrading from v$LocalVersion to v$RemoteVersion..." -ForegroundColor Yellow
    }
} else {
    Write-Host "Installing Nil Game Engine v$RemoteVersion..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
}

# 4. Download Files
$files = @("DoomEngine.ps1", "version.txt")
foreach ($file in $files) {
    try {
        Write-Host "Downloading $file..."
        Invoke-WebRequest -Uri "$RepoUrl/$file" -OutFile "$InstallDir\$file" -UseBasicParsing
    } catch {
        Write-Host "Failed to download $file. Error: $_" -ForegroundColor Red
    }
}

# 5. Create Launcher
$launcher = @"
param([switch]$Debug)
& "$InstallDir\DoomEngine.ps1" -Debug:`$$Debug
"@
$launcher | Set-Content "$InstallDir\Play.ps1"

Write-Host "Installation Complete!" -ForegroundColor Green
Write-Host "Run the game with: .\Play.ps1" -ForegroundColor White
Write-Host "Or directly: $InstallDir\DoomEngine.ps1"

# Launch if new install
& "$InstallDir\DoomEngine.ps1"
