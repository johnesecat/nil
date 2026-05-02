# Nil Game Launcher
# Runs the engine with Debug mode enabled to show errors on crash.
param(
    [switch]$NoDebug
)

$ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnginePath = Join-Path $ScriptPath "DoomEngine.ps1"

if (-not (Test-Path $EnginePath)) {
    Write-Host "Error: DoomEngine.ps1 not found. Please run the installer first." -ForegroundColor Red
    Write-Host "iwr -useb https://raw.githubusercontent.com/johnesecat/nil/main/install.ps1 | iex"
    Start-Sleep -Seconds 5
    exit 1
}

if ($NoDebug) {
    & $EnginePath
} else {
    & $EnginePath -Debug
}
