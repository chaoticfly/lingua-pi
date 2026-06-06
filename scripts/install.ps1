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

$LlamafileUrl   = "https://huggingface.co/mozilla-ai/llamafile_0.10/resolve/main/gemma-4-E4B-it-Q5_K_M.llamafile"
$LlamafileName  = "gemma-4-E4B-it-Q5_K_M.llamafile"
$LlamafileModel = "gemma-4-E4B-it-Q5_K_M"
$LlamafilePort  = "8081"
$DefaultOllamaModel = "gemma4:e4b"

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

# ── write %USERPROFILE%\.linguapi\config.json ────────────────────────────────
function Write-LinguaConfig {
    param([string]$Provider, [string]$Endpoint, [string]$Model)

    $configDir  = Join-Path $env:USERPROFILE ".linguapi"
    $configPath = Join-Path $configDir "config.json"

    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }
    if (Test-Path $configPath) {
        Write-Warn "Config already exists at $configPath — leaving unchanged."
        Write-Warn "Edit manually to set: provider=$Provider, endpoint=$Endpoint, model=$Model"
        return
    }

    @"
{
  "server_port": 8080,
  "language": "Spanish",
  "llm_provider": "$Provider",
  "llm_endpoint": "$Endpoint",
  "llm_model": "$Model",
  "llm_api_key": ""
}
"@ | Set-Content $configPath -Encoding UTF8
    Write-Info "Config written: $configPath"
}

# ── LLM backend setup ────────────────────────────────────────────────────────
function Setup-LLM {
    $linguapiDir   = Join-Path $env:USERPROFILE ".linguapi"
    $llamafilePath = Join-Path $linguapiDir $LlamafileName

    Write-Host ""

    $ollamaInstalled = $null -ne (Get-Command ollama -ErrorAction SilentlyContinue)
    $useLlamafile    = $true

    if ($ollamaInstalled) {
        $ollamaVer = try { & ollama --version 2>$null } catch { "installed" }
        Write-Success "Ollama already installed: $ollamaVer"
        Write-Host ""
        Write-Host "  LinguaPi can use either:"
        Write-Host "    [L] llamafile  — 3-4x faster, single .llamafile executable"
        Write-Host "    [O] Ollama     — already installed, familiar 'ollama pull' workflow"
        $choice = Read-Host "  Which backend? [L/o]"
    } else {
        Write-Host "  No LLM backend detected. Choose one to set up:"
        Write-Host "    [L] llamafile  — fast single executable, runs $LlamafileModel"
        Write-Host "    [O] Ollama     — download Ollama + pull $DefaultOllamaModel (~2.5 GB)"
        $choice = Read-Host "  Which backend? [L/o]"
    }

    if (-not $choice) { $choice = "L" }
    if ($choice -match '^[Oo]') { $useLlamafile = $false }

    if ($useLlamafile) {
        # ── llamafile path ────────────────────────────────────────────────────
        if (-not (Test-Path $linguapiDir)) {
            New-Item -ItemType Directory -Path $linguapiDir -Force | Out-Null
        }

        if (Test-Path $llamafilePath) {
            Write-Success "llamafile already present: $llamafilePath"
        } else {
            Write-Info "Downloading $LlamafileName (~3 GB)..."
            try {
                Invoke-WebRequest -Uri $LlamafileUrl -OutFile $llamafilePath -UseBasicParsing
                Write-Success "llamafile downloaded."
            } catch {
                Fail "Download failed. Check your connection or download manually to $llamafilePath`nError: $_"
            }
        }

        Write-LinguaConfig -Provider "llamafile" -Endpoint "http://localhost:$LlamafilePort" -Model $LlamafileModel
        Write-Host ""
        Write-Success "llamafile ready: $llamafilePath"
        Write-Host ""
        Write-Host "  Start the server with:"
        Write-Host "    & '$llamafilePath' --server --port $LlamafilePort"

    } else {
        # ── Ollama path ───────────────────────────────────────────────────────
        if (-not $ollamaInstalled) {
            Write-Info "Downloading Ollama installer..."
            $ollamaInstaller = Join-Path $env:TEMP "OllamaSetup.exe"
            try {
                Invoke-WebRequest -Uri "https://ollama.com/download/OllamaSetup.exe" -OutFile $ollamaInstaller -UseBasicParsing
            } catch {
                Fail "Could not download Ollama installer: $_"
            }
            Write-Info "Running Ollama installer (follow the prompts)..."
            Start-Process $ollamaInstaller -Wait
            Write-Success "Ollama installed."
        }

        $modelPresent = $false
        try {
            $list = & ollama list 2>$null
            $modelPresent = ($list -join "`n") -match [regex]::Escape($DefaultOllamaModel)
        } catch {}

        if ($modelPresent) {
            Write-Success "Model already available: $DefaultOllamaModel"
        } else {
            $mreply = Read-Host "  Pull model '$DefaultOllamaModel'? (~2.5 GB) [Y/n]"
            if (-not $mreply -or $mreply -match '^[Yy]') {
                Write-Info "Pulling $DefaultOllamaModel (this may take a few minutes)..."
                & ollama pull $DefaultOllamaModel
                Write-Success "Model ready: $DefaultOllamaModel"
            } else {
                Write-Warn "Skipping model pull. Run later: ollama pull $DefaultOllamaModel"
            }
        }

        Write-LinguaConfig -Provider "ollama" -Endpoint "http://localhost:11434" -Model $DefaultOllamaModel
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

Write-Success "LinguaPi $version installed."

# ── LLM backend ──────────────────────────────────────────────────────────────
Setup-LLM

Write-Host ""
Write-Host "  Config : $env:USERPROFILE\.linguapi\config.json"
Write-Host "  Data   : $env:USERPROFILE\.linguapi\linguapi.db"
Write-Host "  Run    : Open a new terminal and run: lingua-pi-launch"
Write-Host "  Open   : http://localhost:8080"
Write-Host ""
Write-Warn "To uninstall: Remove-Item -Recurse -Force '$InstallDir'"
