# Play.ps1
# Launcher script that enables Debug mode by default to catch crashes

$ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnginePath = Join-Path $ScriptPath "DoomEngine.ps1"

if (Test-Path $EnginePath) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $EnginePath -Debug
} else {
    Write-Host "Error: DoomEngine.ps1 not found in $ScriptPath" -ForegroundColor Red
    Read-Host "Press Enter to exit"
}
