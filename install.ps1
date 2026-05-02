<#
.SYNOPSIS
    Installs the Nil Doom Engine from GitHub
.DESCRIPTION
    Downloads the latest version of DoomEngine.ps1 and creates a launcher.
#>

param(
    [string]$RepoOwner = "johnesecat",
    [string]$RepoName = "nil",
    [string]$InstallPath = "$env:USERPROFILE\NilGame"
)

Write-Host "=== Nil Doom Engine Installer ===" -ForegroundColor Cyan

# Create Install Directory
if (-not (Test-Path $InstallPath)) {
    New-Item -ItemType Directory -Path $InstallPath | Out-Null
    Write-Host "Created directory: $InstallPath" -ForegroundColor Green
}

# Download Main Script
$engineUrl = "https://raw.githubusercontent.com/${RepoOwner}/${RepoName}/main/DoomEngine.ps1"
$enginePath = Join-Path $InstallPath "DoomEngine.ps1"

Write-Host "Downloading engine from GitHub..." -NoNewline
try {
    Invoke-WebRequest -Uri $engineUrl -OutFile $enginePath -UseBasicParsing | Out-Null
    Write-Host " Done!" -ForegroundColor Green
} catch {
    Write-Host " Failed!" -ForegroundColor Red
    Write-Error "Could not download DoomEngine.ps1. Check your internet connection or repository URL."
    exit 1
}

# Create Launcher Script
$launcherPath = Join-Path $InstallPath "Play.ps1"
$launcherContent = @"
Set-Location "$InstallPath"
.\DoomEngine.ps1
"@
$launcherContent | Set-Content -Path $launcherPath -Encoding UTF8

# Create Desktop Shortcut (Optional but nice)
$WshShell = New-Object -ComObject WScript.Shell
$ShortcutPath = "$env:USERPROFILE\Desktop\Nil Game.lnk"
$Shortcut = $WshShell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath = "powershell.exe"
$Shortcut.Arguments = "-ExecutionPolicy Bypass -File `"$launcherPath`""
$Shortcut.WorkingDirectory = $InstallPath
$Shortcut.IconLocation = "powershell.exe,0"
$Shortcut.Save()
Write-Host "Created desktop shortcut." -ForegroundColor Green

Write-Host "`n=== Installation Complete ===" -ForegroundColor Cyan
Write-Host "To play, run:" -NoNewline
Write-Host " .\Play.ps1" -ForegroundColor Yellow
Write-Host "Or click the 'Nil Game' icon on your desktop."
Write-Host "`nControls:"
Write-Host "  WASD : Move"
Write-Host "  Q/E  : Turn Left/Right"
Write-Host "  Space: Fire"
Write-Host "  PgUp/PgDn: Change Floors"
Write-Host "  ESC  : Quit"
