# install.ps1 - Auto-Updating Installer using Commit Hashes
$InstallDir = "$env:USERPROFILE\NilGame"
$RepoOwner = "johnesecat"
$RepoName = "nil"
$Branch = "main"

Write-Host "=== Nil Game Installer ===" -ForegroundColor Cyan

# Create Directory
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir | Out-Null
}
Set-Location $InstallDir

# Fetch Latest Commit Hash from GitHub API
try {
    $apiUrl = "https://api.github.com/repos/$RepoOwner/$RepoName/commits?sha=$Branch&per_page=1"
    $response = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing
    $latestCommit = $response[0].sha
    Write-Host "Latest Commit: $latestCommit" -ForegroundColor Green
} catch {
    Write-Host "Failed to fetch commit info. Using fallback." -ForegroundColor Yellow
    $latestCommit = "unknown"
}

# Check Local Commit Hash
$localCommitFile = Join-Path $InstallDir ".commit_hash"
$localCommit = ""
if (Test-Path $localCommitFile) {
    $localCommit = Get-Content $localCommitFile -Raw
}

# Compare and Update
if ($localCommit -eq $latestCommit -and $latestCommit -ne "unknown") {
    Write-Host "Already up to date ($latestCommit)." -ForegroundColor Gray
} else {
    Write-Host "Update Available! Updating from $localCommit to $latestCommit" -ForegroundColor Yellow
    
    # Download Files
    $files = @("DoomEngine.ps1", "Play.ps1")
    foreach ($file in $files) {
        try {
            $url = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch/$file"
            Write-Host "Downloading $file..." -NoNewline
            Invoke-WebRequest -Uri $url -OutFile (Join-Path $InstallDir $file) -UseBasicParsing
            Write-Host " Done" -ForegroundColor Green
        } catch {
            Write-Host " Failed" -ForegroundColor Red
        }
    }
    
    # Save Commit Hash
    $latestCommit | Set-Content $localCommitFile
    Write-Host "Installation Complete!" -ForegroundColor Cyan
}

Write-Host "Run the game with: .\Play.ps1" -ForegroundColor White
Write-Host "Or directly: $InstallDir\DoomEngine.ps1" -ForegroundColor Gray
Write-Host "Tip: Add -Debug flag to see errors if it crashes." -ForegroundColor DarkGray
