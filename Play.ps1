# Launcher script that forces PowerShell 7 and enables Debug mode

$ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnginePath = Join-Path $ScriptPath "DoomEngine.ps1"

if (Test-Path $EnginePath) {
    # Try to find pwsh (PowerShell 7)
    $pwshPath = Get-Command pwsh -ErrorAction SilentlyContinue
    
    if ($pwshPath) {
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $EnginePath -Debug
    } else {
        # Fallback to default powershell (might fail if < 7.0 due to 'class' usage)
        Write-Host "Warning: PowerShell 7 (pwsh) not found. Attempting to run with default shell..." -ForegroundColor Yellow
        & powershell -NoProfile -ExecutionPolicy Bypass -File $EnginePath -Debug
    }
} else {
    Write-Host "Error: DoomEngine.ps1 not found in $ScriptPath" -ForegroundColor Red
    Read-Host "Press Enter to exit"
}
