# LinguaPi installer for Windows
# Usage (PowerShell, run as Administrator for system-wide install):
#   irm https://raw.githubusercontent.com/chaoticfly/lingua-pi/master/scripts/install.ps1 | iex
#   or with a specific version:
#   $env:VERSION = "v1.0.0"; irm .../install.ps1 | iex

#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Version = $env:VERSION,
    [string]$InstallDir = "$env:LOCALAPPDATA\LinguaPi"
)

$ErrorActionPreference = 'Stop'
$Repo = "chaoticfly/lingua-pi"

function Write-Info    { Write-Host "[lingua-pi] $args" -ForegroundColor Cyan }
function Write-Success { Write-Host "[lingua-pi] $args" -ForegroundColor Green }
function Write-Warn    { Write-Host "[lingua-pi] $args" -ForegroundColor Yellow }
function Fail          { Write-Host "[lingua-pi] ERROR: $args" -ForegroundColor Red; exit 1 }

# ── detect architecture ──────────────────────────────────────────────────────
function Get-Arch {
    $a = $env:PROCESSOR_ARCHITECTURE
    if ($a -eq 'ARM64') { return 'arm64' }
    if ($a -match 'AMD64|x86_64') { return 'amd64' }
    Fail "Unsupported architecture: $a"
}

# ── resolve latest version from GitHub API ───────────────────────────────────
function Resolve-Version {
    if ($Version) { return $Version }
    Write-Info "Fetching latest release version..."
    try {
        $resp = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest"
        return $resp.tag_name
    } catch {
        Fail "Could not fetch latest release. Set `$env:VERSION manually. Error: $_"
    }
}

# ── add directory to user PATH (persistent) ──────────────────────────────────
function Add-ToUserPath([string]$Dir) {
    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($current -notlike "*$Dir*") {
        [Environment]::SetEnvironmentVariable('Path', "$current;$Dir", 'User')
        $env:Path += ";$Dir"
        Write-Info "Added $Dir to your PATH."
    }
}

# ── main ─────────────────────────────────────────────────────────────────────
$arch    = Get-Arch
$version = Resolve-Version

$archive = "lingua-pi-windows-$arch.zip"
$url     = "https://github.com/$Repo/releases/download/$version/$archive"
$tmpDir  = Join-Path $env:TEMP "lingua-pi-install-$(Get-Random)"

Write-Info "Installing LinguaPi $version for windows-$arch"
Write-Info "Downloading $archive..."

New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$zipPath = Join-Path $tmpDir $archive

try {
    Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
} catch {
    Fail "Download failed. Check that $version exists at https://github.com/$Repo/releases`nError: $_"
}

Write-Info "Extracting..."
Expand-Archive -Path $zipPath -DestinationPath $tmpDir -Force

$extractedDir = Join-Path $tmpDir "lingua-pi"

# ── install ──────────────────────────────────────────────────────────────────
Write-Info "Installing to $InstallDir..."

if (Test-Path $InstallDir) {
    # Keep config/db; only update the binary and static assets
    Remove-Item -Recurse -Force (Join-Path $InstallDir "static") -ErrorAction SilentlyContinue
    Remove-Item -Force (Join-Path $InstallDir "lingua-pi.exe") -ErrorAction SilentlyContinue
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Copy-Item (Join-Path $extractedDir "lingua-pi.exe") $InstallDir
Copy-Item -Recurse (Join-Path $extractedDir "static") $InstallDir

# ── launcher batch file (so the binary runs from its own directory) ───────────
$launcher = Join-Path $InstallDir "lingua-pi-launch.bat"
@"
@echo off
cd /d "%LOCALAPPDATA%\LinguaPi"
"%LOCALAPPDATA%\LinguaPi\lingua-pi.exe" %*
"@ | Set-Content $launcher -Encoding ASCII

# ── PATH ─────────────────────────────────────────────────────────────────────
Add-ToUserPath $InstallDir

# ── cleanup ──────────────────────────────────────────────────────────────────
Remove-Item -Recurse -Force $tmpDir

Write-Success "Installed! Open a new terminal and run: lingua-pi-launch"
Write-Host ""
Write-Host "  Config : $env:USERPROFILE\.linguapi\config.json  (created on first run)"
Write-Host "  Data   : $env:USERPROFILE\.linguapi\linguapi.db"
Write-Host ""
Write-Host "  Pull a model : ollama pull gemma3:4b"
Write-Host "  Then open    : http://localhost:8080"
Write-Host ""
Write-Warn "To uninstall: Remove-Item -Recurse -Force '$InstallDir'"
