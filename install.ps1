<#
.SYNOPSIS
    Nil Game Engine Installer with Auto-Versioning
.DESCRIPTION
    Downloads and installs the latest version of the Doom-style Raycasting Engine.
    Automatically detects updates by comparing file hashes and GitHub metadata.
#>

$InstallDir = "$env:USERPROFILE\NilGame"
$RepoUser = "johnesecat"
$RepoName = "nil"
$Branch = "main"

# Files to manage
$Files = @(
    @{ Name = "DoomEngine.ps1"; Path = "$InstallDir\DoomEngine.ps1" },
    @{ Name = "Play.ps1"; Path = "$InstallDir\Play.ps1" },
    @{ Name = "version.txt"; Path = "$InstallDir\version.txt" }
)

function Get-GitHubFileMeta {
    param($fileName)
    try {
        $url = "https://api.github.com/repos/$RepoUser/$RepoName/contents/$fileName?ref=$Branch"
        $meta = Invoke-RestMethod -Uri $url -UseBasicParsing -ErrorAction Stop
        return $meta
    } catch {
        Write-Host "Failed to fetch metadata for $fileName : $_" -ForegroundColor Red
        return $null
    }
}

function Get-FileHashLocal {
    param($path)
    if (Test-Path $path) {
        $hash = Get-FileHash -Path $path -Algorithm SHA256
        return $hash.Hash
    }
    return $null
}

function Test-UpdateAvailable {
    $updateNeeded = $false
    $reasons = @()

    foreach ($file in $Files) {
        $meta = Get-GitHubFileMeta -fileName $file.Name
        if (-not $meta) { continue }

        $localHash = Get-FileHashLocal -path $file.Path
        $remoteHash = $meta.sha # GitHub API returns content hash in 'sha' field for files

        if ($localHash -ne $remoteHash) {
            $updateNeeded = $true
            $reasons += "$($file.Name) changed"
        }
    }

    # Check version.txt logic as fallback
    $versionPath = "$InstallDir\version.txt"
    $currentVer = "v0.0.0"
    if (Test-Path $versionPath) {
        $currentVer = Get-Content $versionPath -ErrorAction SilentlyContinue
    }
    
    # Try to infer version from remote version.txt content if available
    $verMeta = Get-GitHubFileMeta -fileName "version.txt"
    if ($verMeta) {
        $remoteContent = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($verMeta.content))
        $remoteVer = $remoteContent.Trim()
        if ($currentVer -ne $remoteVer) {
            $updateNeeded = $true
            $reasons += "Version mismatch ($currentVer vs $remoteVer)"
        }
    }

    return @{ Needed = $updateNeeded; Reasons = $reasons }
}

function Install-Game {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "       Nil Game Engine Installer      " -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir | Out-Null
        Write-Host "Created installation directory: $InstallDir" -ForegroundColor Green
    }

    # Check for updates
    $existing = Test-Path "$InstallDir\DoomEngine.ps1"
    if ($existing) {
        $check = Test-UpdateAvailable
        if (-not $check.Needed) {
            Write-Host "Installation is up to date." -ForegroundColor Green
            $currentVer = Get-Content "$InstallDir\version.txt" -ErrorAction SilentlyContinue
            Write-Host "Current Version: $currentVer" -ForegroundColor Gray
            Write-Host "Launch game with: .\Play.ps1" -ForegroundColor Yellow
            return
        } else {
            Write-Host "Update detected!" -ForegroundColor Yellow
            Write-Host "Reasons: $($check.Reasons -join ', ')" -ForegroundColor Gray
            $currentVer = Get-Content "$InstallDir\version.txt" -ErrorAction SilentlyContinue
            Write-Host "Upgrading from: $currentVer" -ForegroundColor Gray
        }
    } else {
        Write-Host "New installation detected." -ForegroundColor Green
    }

    # Download Files
    foreach ($file in $Files) {
        Write-Host "Downloading $($file.Name)..." -NoNewline
        try {
            $url = "https://raw.githubusercontent.com/$RepoUser/$RepoName/$Branch/$($file.Name)"
            Invoke-RestMethod -Uri $url -OutFile $file.Path -UseBasicParsing -ErrorAction Stop
            Write-Host " Done" -ForegroundColor Green
        } catch {
            Write-Host " Failed: $_" -ForegroundColor Red
            # If version.txt fails to download, create a placeholder based on date
            if ($file.Name -eq "version.txt") {
                "v1.0.0-auto" | Set-Content -Path $file.Path
            }
        }
    }

    # Create Play.ps1 wrapper if missing
    $playPath = "$InstallDir\Play.ps1"
    if (-not (Test-Path $playPath)) {
        @"
# Nil Game Launcher
& "$InstallDir\DoomEngine.ps1"
"@ | Set-Content -Path $playPath
    }

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Installation / Update Complete!" -ForegroundColor Green
    $vContent = Get-Content "$InstallDir\version.txt" -ErrorAction SilentlyContinue
    Write-Host "Version: $vContent" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Run the game with: .\Play.ps1" -ForegroundColor Yellow
    Write-Host "Or directly: $InstallDir\DoomEngine.ps1" -ForegroundColor Gray
    Write-Host "Add -Debug flag to see errors: .\DoomEngine.ps1 -Debug" -ForegroundColor Gray
}

Install-Game
