<#
.SYNOPSIS
    Installs the Nil Doom Engine from GitHub.
.DESCRIPTION
    Downloads the latest version of the DoomEngine.ps1 and creates a launcher.
.LINK
    https://github.com/johnesecat/nil
#>

param(
    [string]$InstallPath = "$env:USERPROFILE\NilGame",
    [string]$RepoUrl = "https://raw.githubusercontent.com/johnesecat/nil/main"
)

Write-Host "=== Nil Doom Engine Installer ===" -ForegroundColor Cyan

# Create Directory
if (-not (Test-Path $InstallPath)) {
    New-Item -ItemType Directory -Path $InstallPath | Out-Null
    Write-Host "Created directory: $InstallPath" -ForegroundColor Green
} else {
    Write-Host "Using existing directory: $InstallPath" -ForegroundColor Yellow
}

Set-Location $InstallPath

# Download Engine
Write-Host "Downloading DoomEngine.ps1..." -NoNewline
try {
    Invoke-WebRequest -Uri "$RepoUrl/DoomEngine.ps1" -OutFile "DoomEngine.ps1" -UseBasicParsing
    Write-Host " Done!" -ForegroundColor Green
} catch {
    Write-Host " Failed!" -ForegroundColor Red
    Write-Error "Could not download DoomEngine.ps1. Check your internet connection or repository URL."
    exit 1
}

# Create Launcher
$launcherContent = @"
# Nil Game Launcher
Set-Location "$InstallPath"
.\DoomEngine.ps1 -Width 100 -Height 50 -Resolution 2
"@

$launcherContent | Out-File -FilePath "Play.ps1" -Encoding UTF8
Write-Host "Created Play.ps1 launcher." -ForegroundColor Green

# Instructions
Write-Host "`n=== Installation Complete ===" -ForegroundColor Cyan
Write-Host "To play the game, run the following command:" -ForegroundColor White
Write-Host "  cd $InstallPath" -ForegroundColor Gray
Write-Host "  .\Play.ps1" -ForegroundColor Green
Write-Host "`nControls:" -ForegroundColor White
Write-Host "  W/A/S/D : Move" -ForegroundColor Gray
Write-Host "  Q/E     : Turn Left/Right" -ForegroundColor Gray
Write-Host "  SPACE   : Fire" -ForegroundColor Gray
Write-Host "  PGUP/DN : Change Floors" -ForegroundColor Gray
Write-Host "  ESC     : Quit" -ForegroundColor Gray
