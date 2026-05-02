# Launcher script that forces PowerShell 7 and enables Debug mode

$ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnginePath = Join-Path $ScriptPath "DoomEngine.ps1"

if (Test-Path $EnginePath) {
    # Explicitly call 'pwsh' (PowerShell 7) instead of 'powershell' (v5.1)
    # This ensures class support and modern .NET features
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $EnginePath -Debug
} else {
    Write-Host "Error: DoomEngine.ps1 not found in $ScriptPath" -ForegroundColor Red
    Read-Host "Press Enter to exit"
}
