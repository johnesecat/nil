param([switch]$ForceUpdate)

$RepoOwner = "johnesecat"
$RepoName = "nil"
$InstallDir = "$env:USERPROFILE\NilGame"
$Files = @("DoomEngine.ps1", "Play.ps1")

Write-Host "=== Nil Game Installer ===" -ForegroundColor Cyan

# Create Directory
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir | Out-Null
    Write-Host "Created installation directory: $InstallDir" -ForegroundColor Green
}

# Helper: Get Local Commit Hash (from a marker file we create)
$HashFile = Join-Path $InstallDir ".commit_hash"
$LocalHash = ""
if (Test-Path $HashFile) {
    $LocalHash = Get-Content $HashFile -ErrorAction SilentlyContinue
}

# Helper: Get Remote Commit Hash via API
try {
    $apiUrl = "https://api.github.com/repos/$RepoOwner/$RepoName/commits/main"
    $response = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -ErrorAction Stop
    $RemoteHash = $response.sha
    Write-Host "Latest Commit: $RemoteHash" -ForegroundColor Gray
} catch {
    Write-Host "Failed to fetch remote commit info. Check internet connection." -ForegroundColor Red
    Write-Host $_.Exception.Message
    exit 1
}

# Compare
if ($LocalHash -eq $RemoteHash -and -not $ForceUpdate) {
    Write-Host "Up to date! (Commit: $LocalHash)" -ForegroundColor Green
    # Verify files exist just in case
    $missing = $Files | Where-Object { -not (Test-Path (Join-Path $InstallDir $_)) }
    if ($missing) {
        Write-Host "Some files missing. Re-installing..." -ForegroundColor Yellow
    } else {
        exit 0
    }
} else {
    if ($LocalHash) {
        Write-Host "Update Available! Updating from $LocalHash to $RemoteHash" -ForegroundColor Yellow
    } else {
        Write-Host "Installing new version ($RemoteHash)..." -ForegroundColor Yellow
    }
}

# Download Files
foreach ($file in $Files) {
    $url = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/main/$file"
    $dest = Join-Path $InstallDir $file
    Write-Host "Downloading $file..." -NoNewline
    try {
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -ErrorAction Stop
        Write-Host " Done" -ForegroundColor Green
    } catch {
        Write-Host " Failed" -ForegroundColor Red
        Write-Host "Error downloading $file : $($_.Exception.Message)"
    }
}

# Save Commit Hash
$RemoteHash | Set-Content $HashFile -Encoding ASCII

# Create Play.ps1 if it wasn't in the repo download (fallback)
$PlayPath = Join-Path $InstallDir "Play.ps1"
if (-not (Test-Path $PlayPath)) {
    @"
# Launcher for Nil Game
& "$PSScriptRoot\DoomEngine.ps1" -Debug
"@ | Set-Content $PlayPath
}

Write-Host "`nInstallation Complete!" -ForegroundColor Green
Write-Host "Run the game with: .\Play.ps1" -ForegroundColor Cyan
Write-Host "Or directly: $InstallDir\DoomEngine.ps1"
Write-Host "Tip: Add -Debug flag to see errors if it crashes."
