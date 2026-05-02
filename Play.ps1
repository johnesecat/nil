# Launcher script that ensures PS7 usage and enables Debug mode

$ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnginePath = Join-Path $ScriptPath "DoomEngine.ps1"

if (Test-Path $EnginePath) {
    # Check if we are already in PowerShell 7 (Core)
    if ($PSVersionTable.PSEdition -eq 'Core') {
        & $EnginePath -Debug
    } else {
        # Launch PowerShell 7 explicitly
        if (Get-Command pwsh -ErrorAction SilentlyContinue) {
            & pwsh -NoProfile -ExecutionPolicy Bypass -File $EnginePath -Debug
        } else {
            Write-Host "ERROR: PowerShell 7 (pwsh) is required but not found." -ForegroundColor Red
            Write-Host "Please install PowerShell 7 from: https://aka.ms/powershell" -ForegroundColor Yellow
            Read-Host "Press Enter to exit"
        }
    }
} else {
    Write-Host "Error: DoomEngine.ps1 not found in $ScriptPath" -ForegroundColor Red
    Read-Host "Press Enter to exit"
}
