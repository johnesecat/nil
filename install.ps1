<#
.SYNOPSIS
    Nil Game Engine Installer & Updater
.DESCRIPTION
    Downloads, installs, and updates the Doom-style Raycasting Engine for PowerShell.
    Supports version checking and seamless upgrades.
.LINK
    https://github.com/johnesecat/nil
#>

param(
    [switch]$Force,
    [switch]$NoPrompt
)

$RepoOwner = "johnesecat"
$RepoName = "nil"
$Branch = "main"
$InstallDir = "$env:USERPROFILE\NilGame"
$EngineFile = "DoomEngine.ps1"
$VersionFile = "version.txt"
$BaseUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch"

# Colors
$Cyan = [ConsoleColor]::Cyan
$Green = [ConsoleColor]::Green
$Yellow = [ConsoleColor]::Yellow
$Red = [ConsoleColor]::Red

function Write-Color {
    param($Text, $Color)
    Write-Host $Text -ForegroundColor $Color
}

Write-Color "=== Nil Game Engine Installer ===" $Cyan

# 1. Determine Local Version
$LocalVersion = "0.0.0"
$IsInstalled = Test-Path "$InstallDir\$EngineFile"

if ($IsInstalled) {
    if (Test-Path "$InstallDir\$VersionFile") {
        $LocalVersion = Get-Content "$InstallDir\$VersionFile"
    } else {
        $LocalVersion = "0.0.0 (Legacy)"
    }
    Write-Color "Existing installation found: v$LocalVersion" $Yellow
} else {
    Write-Color "No existing installation found." $Green
}

# 2. Fetch Remote Version
try {
    Write-Host "Checking for updates..." -NoNewline
    $RemoteVersionRaw = Invoke-RestMethod -Uri "$BaseUrl/version.txt" -UseBasicParsing -ErrorAction Stop
    $RemoteVersion = $RemoteVersionRaw.Trim()
    Write-Host " Latest: v$RemoteVersion" -ForegroundColor Green
} catch {
    Write-Color "Failed to check remote version. Using latest available." $Yellow
    $RemoteVersion = $LocalVersion # Assume up to date if check fails to prevent breakage
}

# 3. Compare Versions
$ShouldInstall = $false
$ShouldUpdate = $false

if (-not $IsInstalled) {
    $ShouldInstall = $true
} elseif ($Force) {
    $ShouldUpdate = $true
    Write-Color "Force flag detected. Re-installing..." $Yellow
} else {
    # Simple string comparison for semantic versions (e.g., 1.0.0 vs 1.0.1)
    if ($RemoteVersion -ne $LocalVersion) {
        # In a real scenario, use [System.Version] but string compare works for simple increments
        Write-Color "Update available: v$LocalVersion -> v$RemoteVersion" $Cyan
        if ($NoPrompt) {
            $ShouldUpdate = $true
        } else {
            $response = Read-Host "Do you want to update? (Y/n)"
            if ([string]::IsNullOrEmpty($response) -or $response -match '^[Yy]') {
                $ShouldUpdate = $true
            } else {
                Write-Color "Update skipped." $Yellow
                exit 0
            }
        }
    } else {
        Write-Color "You are already running the latest version (v$LocalVersion)." $Green
        exit 0
    }
}

# 4. Perform Installation/Update
if ($ShouldInstall -or $ShouldUpdate) {
    try {
        # Ensure Directory Exists
        if (-not (Test-Path $InstallDir)) {
            New-Item -ItemType Directory -Path $InstallDir | Out-Null
        }

        # Download Engine
        Write-Host "Downloading $EngineFile..." -NoNewline
        $ScriptContent = Invoke-RestMethod -Uri "$BaseUrl/$EngineFile" -UseBasicParsing
        Set-Content -Path "$InstallDir\$EngineFile" -Value $ScriptContent -Encoding UTF8
        Write-Host "Done" -ForegroundColor Green

        # Download Version File
        try {
            $VersionContent = Invoke-RestMethod -Uri "$BaseUrl/version.txt" -UseBasicParsing
            Set-Content -Path "$InstallDir\$VersionFile" -Value $VersionContent.Trim() -Encoding UTF8
        } catch {
            # Fallback if version file missing in repo
            Set-Content -Path "$InstallDir\$VersionFile" -Value "unknown" -Encoding UTF8
        }

        # Create Launcher (Play.ps1) if missing or update it
        $LauncherPath = "$InstallDir\Play.ps1"
        $LauncherScript = @"
# Nil Game Launcher
& "$InstallDir\DoomEngine.ps1"
"@
        Set-Content -Path $LauncherPath -Value $LauncherScript -Encoding UTF8

        Write-Color "Installation Successful!" $Green
        Write-Host "Location: $InstallDir"
        Write-Host "To play, run: .\Play.ps1 inside the folder, or:"
        Write-Color "& '$InstallDir\DoomEngine.ps1'" $Cyan
        
        if ($IsInstalled) {
            Write-Color "Game updated from v$LocalVersion to v$RemoteVersion" $Green
        }

    } catch {
        Write-Color "Installation failed: $_" $Red
        exit 1
    }
}
