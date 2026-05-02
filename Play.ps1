# Play.ps1 - Launcher with Debug Mode
param(
    [switch]$Debug
)

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$enginePath = Join-Path $scriptPath "DoomEngine.ps1"

if (Test-Path $enginePath) {
    if ($Debug) {
        & $enginePath -Debug
    } else {
        & $enginePath
    }
} else {
    Write-Host "Error: DoomEngine.ps1 not found in $scriptPath" -ForegroundColor Red
    Start-Sleep -Seconds 3
}
