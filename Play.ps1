# Play.ps1
# Launcher script that ensures PowerShell 7 is used and enables Debug mode

$ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnginePath = Join-Path $ScriptPath "DoomEngine.ps1"

if (-not (Test-Path $EnginePath)) {
    Write-Host "Error: DoomEngine.ps1 not found in $ScriptPath" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

# Check if we are already running in PowerShell 7 (Core)
# PSVersionTable.PSVersion.Major -ge 6 indicates Core/7+
if ($PSVersionTable.PSVersion.Major -ge 6) {
    # We are in PS 7+, run directly
    & $EnginePath -Debug
} else {
    # We are in Windows PowerShell 5.1, spawn PS 7
    if (Get-Command pwsh -ErrorAction SilentlyContinue) {
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $EnginePath -Debug
    } else {
        Write-Host "CRITICAL: PowerShell 7 (pwsh) is required but not found." -ForegroundColor Red
        Write-Host "Please install PowerShell 7 from: https://aka.ms/powershell" -ForegroundColor Yellow
        Read-Host "Press Enter to exit"
        exit 1
    }
}
