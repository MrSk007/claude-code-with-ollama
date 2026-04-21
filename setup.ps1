#Requires -Version 5.1
<#
.SYNOPSIS
    Claude Code + Ollama Setup Toolkit (Windows)

.DESCRIPTION
    Installs and configures Claude Code to use Ollama's native Anthropic-compatible API.

.PARAMETER Install
    Full guided setup (default).

.PARAMETER Silent
    Non-interactive mode, uses auto-detected defaults.

.PARAMETER Verify
    Run health check only.

.PARAMETER Force
    Overwrite existing Anthropic env var configuration.

.PARAMETER Help
    Show usage information.

.EXAMPLE
    .\setup.ps1
    .\setup.ps1 -Silent
    .\setup.ps1 -Verify
    .\setup.ps1 -Silent -Force
#>

[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install')]
    [switch]$Install,

    [Parameter()]
    [switch]$Silent,

    [Parameter(ParameterSetName = 'Verify')]
    [switch]$Verify,

    [Parameter()]
    [switch]$Force,

    [Parameter(ParameterSetName = 'Help')]
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$Script:VERSION = "1.0.0"
$Script:MIN_NODE_VERSION = [version]"18.0.0"
$Script:MIN_OLLAMA_VERSION = [version]"0.15.3"
$Script:OLLAMA_API_URL = "http://localhost:11434"
$Script:SENTINEL_START = "# >>> claude-code-ollama >>>"
$Script:SENTINEL_END = "# <<< claude-code-ollama <<<"
$Script:BACKUP_DIR = Join-Path $HOME ".claude-code-ollama-backup"
$Script:MODEL_NAME_REGEX = '^[a-zA-Z0-9_.-]+:[a-zA-Z0-9_.-]+$'

# Model recommendation table -- update here when models change
# Format: min_ram_gb, model, size_on_disk_gb, num_ctx
$Script:MODEL_TABLE = @(
    @{ MinRam = 0;  Model = "qwen2.5-coder:3b";        Size = "2";   NumCtx = 8192  }
    @{ MinRam = 8;  Model = "qwen2.5-coder:7b";        Size = "4.5"; NumCtx = 16384 }
    @{ MinRam = 12; Model = "qwen2.5-coder:14b";       Size = "9";   NumCtx = 32768 }
    @{ MinRam = 16; Model = "deepseek-coder-v2:16b";   Size = "10";  NumCtx = 49152 }
    @{ MinRam = 32; Model = "qwen2.5-coder:32b";       Size = "20";  NumCtx = 65536 }
)

# Cloud model options -- run on Ollama's infrastructure, no local download needed
$Script:CLOUD_MODELS = @(
    @{ Model = "kimi-k2.5:cloud";            Desc = "Kimi K2.5 -- fast cloud model" }
    @{ Model = "glm-5:cloud";               Desc = "GLM 5 -- strong general reasoning" }
    @{ Model = "minimax-m2.7:cloud";        Desc = "MiniMax M2.7 -- balanced cloud model" }
    @{ Model = "qwen3.5:cloud";             Desc = "Qwen 3.5 -- versatile cloud coding model" }
)

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

$Script:SelectedModel = ""
$Script:SelectedNumCtx = 0
$Script:SelectedSizeGb = ""
$Script:DetectedRamGb = 0
$Script:IsCloudModel = $false

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] " -ForegroundColor Blue -NoNewline
    Write-Host $Message
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] " -ForegroundColor Yellow -NoNewline
    Write-Host $Message
}

function Write-Err {
    param([string]$Message)
    Write-Host "[ERROR] " -ForegroundColor Red -NoNewline
    Write-Host $Message
}

function Write-Success {
    param([string]$Message)
    Write-Host "[OK] " -ForegroundColor Green -NoNewline
    Write-Host $Message
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

function Show-Help {
    Write-Host ""
    Write-Host "Claude Code + Ollama Setup Toolkit v$Script:VERSION" -ForegroundColor White
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor White
    Write-Host "  .\setup.ps1 [OPTIONS]"
    Write-Host ""
    Write-Host "Options:" -ForegroundColor White
    Write-Host "  -Install     Full guided setup (default)"
    Write-Host "  -Silent      Non-interactive mode, uses auto-detected defaults"
    Write-Host "  -Verify      Run health check only"
    Write-Host "  -Force       Overwrite existing Anthropic env var configuration"
    Write-Host "  -Help        Show this help message"
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor White
    Write-Host "  .\setup.ps1                  # Interactive setup"
    Write-Host "  .\setup.ps1 -Silent          # Automated setup with defaults"
    Write-Host "  .\setup.ps1 -Verify          # Check if everything works"
    Write-Host "  .\setup.ps1 -Silent -Force   # Overwrite existing config silently"
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Version comparison
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------

function Get-OllamaVersion {
    $Output = ollama --version 2>&1 | Out-String
    if ($Output -match '(\d+\.\d+\.\d+)') {
        return [version]$Matches[1]
    }
    return $null
}

function Test-Prerequisites {
    Write-Info "Checking prerequisites..."

    # Warn if running as Administrator
    $IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($IsAdmin) {
        Write-Warn "Running as Administrator. This is not recommended - Ollama and Claude Code"
        Write-Warn "should be installed as your normal user to avoid permission issues."
    }

    # Node.js
    try {
        $null = Get-Command node -ErrorAction Stop
    }
    catch {
        Write-Err "Node.js is not installed."
        Write-Err "Claude Code requires Node.js $($Script:MIN_NODE_VERSION.Major)+."
        Write-Err "Install from: https://nodejs.org"
        exit 1
    }

    $NodeVersionStr = (node --version) -replace '^v', ''
    $NodeVersion = [version]$NodeVersionStr

    if ($NodeVersion.Major -lt $Script:MIN_NODE_VERSION.Major) {
        Write-Err "Node.js $($Script:MIN_NODE_VERSION.Major)+ required. Current: v$NodeVersionStr"
        Write-Err "Upgrade at: https://nodejs.org"
        exit 1
    }
    Write-Success "Node.js v$NodeVersionStr"

    # Git Bash (required by Claude Code on Windows)
    $GitBashPath = $env:CLAUDE_CODE_GIT_BASH_PATH
    if (-not $GitBashPath) {
        # Check common install locations
        $CommonPaths = @(
            "C:\Program Files\Git\bin\bash.exe",
            "C:\Program Files (x86)\Git\bin\bash.exe",
            (Join-Path $env:LOCALAPPDATA "Programs\Git\bin\bash.exe")
        )
        foreach ($Path in $CommonPaths) {
            if (Test-Path $Path) {
                $GitBashPath = $Path
                break
            }
        }
    }

    if (-not $GitBashPath -or -not (Test-Path $GitBashPath)) {
        # Also check if git is in PATH (bash.exe is usually alongside it)
        try {
            $GitCmd = Get-Command git -ErrorAction Stop
            $GitBinDir = Split-Path (Split-Path $GitCmd.Source -Parent) -Parent
            $GitBashCandidate = Join-Path $GitBinDir "bin\bash.exe"
            if (Test-Path $GitBashCandidate) {
                $GitBashPath = $GitBashCandidate
            }
        }
        catch {}
    }

    if ($GitBashPath -and (Test-Path $GitBashPath)) {
        Write-Success "Git Bash found: $GitBashPath"
        if (-not $env:CLAUDE_CODE_GIT_BASH_PATH) {
            $env:CLAUDE_CODE_GIT_BASH_PATH = $GitBashPath
            Write-Info "Set CLAUDE_CODE_GIT_BASH_PATH=$GitBashPath for this session"
        }
    }
    else {
        Write-Err "Git Bash is not installed."
        Write-Err "Claude Code on Windows requires Git Bash."
        Write-Err "Install from: https://git-scm.com/downloads/win"
        Write-Err "If already installed, set: `$env:CLAUDE_CODE_GIT_BASH_PATH = 'C:\Program Files\Git\bin\bash.exe'"
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Ollama installation
# ---------------------------------------------------------------------------

function Install-Ollama {
    # Check if already installed and sufficient version
    try {
        $null = Get-Command ollama -ErrorAction Stop
        $OllamaVersion = Get-OllamaVersion
        if ($OllamaVersion -and $OllamaVersion -ge $Script:MIN_OLLAMA_VERSION) {
            Write-Success "Ollama v$OllamaVersion already installed"
            return
        }
        Write-Warn "Ollama needs upgrading to v$Script:MIN_OLLAMA_VERSION+"
    }
    catch {
        # Not installed
    }

    Write-Info "Installing/upgrading Ollama..."

    # Prefer winget
    try {
        $null = Get-Command winget -ErrorAction Stop
        Write-Info "Using winget..."
        winget install Ollama.Ollama --accept-package-agreements --accept-source-agreements
    }
    catch {
        # Fallback: download installer
        Write-Info "Downloading Ollama installer..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        $TempInstaller = Join-Path $env:TEMP "OllamaSetup.exe"
        try {
            $OldProgress = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri "https://ollama.com/download/OllamaSetup.exe" -OutFile $TempInstaller -UseBasicParsing
            $ProgressPreference = $OldProgress
            Write-Info "Running installer (this may take a moment)..."
            $InstallerProcess = Start-Process -FilePath $TempInstaller -ArgumentList "/VERYSILENT" -PassThru
            # Don't use -Wait: Ollama installer launches a tray app/service that keeps child processes alive
            if (-not $InstallerProcess.WaitForExit(120000)) {
                Write-Warn "Installer still running after 120 seconds -- continuing anyway."
            }
        }
        finally {
            # Installer may still be locked by spawned tray app -- don't let cleanup kill the script
            Remove-Item $TempInstaller -Force -ErrorAction SilentlyContinue
        }
    }

    # Refresh PATH
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

    # Verify
    try {
        $null = Get-Command ollama -ErrorAction Stop
        $OllamaVersion = Get-OllamaVersion
        if ($OllamaVersion -and $OllamaVersion -ge $Script:MIN_OLLAMA_VERSION) {
            Write-Success "Ollama v$OllamaVersion installed"
            return
        }
        Write-Err "Ollama v$Script:MIN_OLLAMA_VERSION+ required. Try upgrading manually: https://ollama.com"
        exit 3
    }
    catch {
        Write-Err "Ollama installation failed. Install manually from https://ollama.com"
        exit 3
    }
}

# ---------------------------------------------------------------------------
# Hardware detection
# ---------------------------------------------------------------------------

function Get-DetectedHardware {
    Write-Info "Detecting hardware..."

    $Script:DetectedRamGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)

    Write-Info "Detected RAM: $Script:DetectedRamGb GB"

    if ($Script:DetectedRamGb -lt 8) {
        Write-Warn "Less than 8 GB RAM detected. Local model performance will be limited."
        Write-Warn "You can proceed, but expect slow responses and reduced capabilities."
    }
}

# ---------------------------------------------------------------------------
# Model selection
# ---------------------------------------------------------------------------

function Select-Model {
    $RecommendedModel = ""
    $RecommendedSize = ""
    $RecommendedCtx = 0

    foreach ($Entry in $Script:MODEL_TABLE) {
        if ($Script:DetectedRamGb -ge $Entry.MinRam) {
            $RecommendedModel = $Entry.Model
            $RecommendedSize = $Entry.Size
            $RecommendedCtx = $Entry.NumCtx
        }
    }

    if (-not $RecommendedModel) {
        $RecommendedModel = "qwen2.5-coder:3b"
        $RecommendedSize = "2"
        $RecommendedCtx = 8192
    }

    Write-Host ""
    Write-Info "Recommended local model: $RecommendedModel"
    Write-Info "  Download size: ~${RecommendedSize} GB"
    Write-Info "  Context window: $RecommendedCtx tokens"
    Write-Host ""
    Write-Info "Cloud models (run on Ollama's servers, no download):"
    $CloudIndex = 1
    foreach ($Cloud in $Script:CLOUD_MODELS) {
        Write-Host "  ${CloudIndex}. $($Cloud.Model)  -- $($Cloud.Desc)"
        $CloudIndex++
    }
    Write-Host ""

    if ($Silent) {
        $Script:SelectedModel = $RecommendedModel
        $Script:SelectedNumCtx = $RecommendedCtx
        $Script:SelectedSizeGb = $RecommendedSize
        return
    }

    # Interactive mode
    $Answer = Read-Host "Use ${RecommendedModel}? [Y/n/cloud/custom]"

    switch -Regex ($Answer) {
        '^$|^[Yy]' {
            $Script:SelectedModel = $RecommendedModel
            $Script:SelectedNumCtx = $RecommendedCtx
            $Script:SelectedSizeGb = $RecommendedSize
        }
        '^[Cc]loud|^cloud$' {
            Write-Host ""
            Write-Host "Select a cloud model (1-$($Script:CLOUD_MODELS.Count)) or enter a name (e.g., kimi-k2.5:cloud):"
            $CloudChoice = Read-Host "Choice"
            if ($CloudChoice -match '^\d+$' -and [int]$CloudChoice -ge 1 -and [int]$CloudChoice -le $Script:CLOUD_MODELS.Count) {
                $Script:SelectedModel = $Script:CLOUD_MODELS[[int]$CloudChoice - 1].Model
            }
            elseif ($CloudChoice -match $Script:MODEL_NAME_REGEX) {
                $Script:SelectedModel = $CloudChoice
            }
            else {
                Write-Err "Invalid selection. Expected: number (1-$($Script:CLOUD_MODELS.Count)) or model name (e.g., kimi-k2.5:cloud)"
                exit 1
            }
            $Script:IsCloudModel = $true
            $Script:SelectedNumCtx = 65536
            $Script:SelectedSizeGb = ""
            Write-Info "Cloud models run at full context length on Ollama's servers."
        }
        '^[Nn]|^custom' {
            $CustomModel = Read-Host "Enter model name (e.g., qwen2.5-coder:14b or kimi-k2.5:cloud)"
            if ($CustomModel -notmatch $Script:MODEL_NAME_REGEX) {
                Write-Err "Invalid model name format. Expected: name:tag (e.g., qwen2.5-coder:7b)"
                exit 1
            }
            $Script:SelectedModel = $CustomModel
            if ($CustomModel -match ':.*cloud$') {
                $Script:IsCloudModel = $true
                $Script:SelectedNumCtx = 65536
                $Script:SelectedSizeGb = ""
                Write-Info "Cloud model detected. Runs on Ollama's servers."
            }
            else {
                $Script:SelectedNumCtx = $RecommendedCtx
                $Script:SelectedSizeGb = $RecommendedSize
                Write-Warn "Using custom model. Context window set to $RecommendedCtx. Override with OLLAMA_NUM_CTX env var if needed."
            }
        }
        default {
            if ($Answer -match $Script:MODEL_NAME_REGEX) {
                $Script:SelectedModel = $Answer
                if ($Answer -match ':.*cloud$') {
                    $Script:IsCloudModel = $true
                    $Script:SelectedNumCtx = 65536
                    $Script:SelectedSizeGb = ""
                }
                else {
                    $Script:SelectedNumCtx = $RecommendedCtx
                    $Script:SelectedSizeGb = $RecommendedSize
                }
            }
            else {
                Write-Err "Invalid model name format. Expected: name:tag (e.g., qwen2.5-coder:7b)"
                exit 1
            }
        }
    }

    Write-Success "Selected model: $($Script:SelectedModel)$(if ($Script:IsCloudModel) { ' (cloud)' })"
}

# ---------------------------------------------------------------------------
# Model pull
# ---------------------------------------------------------------------------

function Save-Model {
    # Cloud models run on Ollama's servers -- no local pull needed
    if ($Script:IsCloudModel) {
        Write-Info "Cloud model selected -- no local download needed."
        Write-Info "Ensuring you are signed in to Ollama..."
        try {
            $WhoamiOutput = ollama whoami 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0 -or $WhoamiOutput -match 'not signed in|no account') {
                throw "not signed in"
            }
            Write-Success "Signed in to Ollama"
        }
        catch {
            Write-Warn "You need to sign in to Ollama to use cloud models."
            Write-Info "Run: ollama signin"
            ollama signin
            if ($LASTEXITCODE -ne 0) {
                Write-Err "Ollama sign-in failed. Sign in manually with: ollama signin"
                exit 3
            }
            Write-Success "Signed in to Ollama"
        }
        return
    }

    $ExistingModels = ollama list 2>&1 | Out-String
    if ($ExistingModels -match [regex]::Escape($Script:SelectedModel)) {
        Write-Success "Model $($Script:SelectedModel) already pulled"
        return
    }

    # Check disk space before downloading
    if ($Script:SelectedSizeGb) {
        $Drive = (Split-Path $env:USERPROFILE -Qualifier)
        $FreeGb = [math]::Round((Get-PSDrive $Drive.TrimEnd(':')).Free / 1GB)
        $RequiredGb = [math]::Ceiling([double]$Script:SelectedSizeGb)
        if ($FreeGb -lt $RequiredGb) {
            Write-Err "Insufficient disk space. Need ~${RequiredGb} GB, have ${FreeGb} GB free."
            exit 3
        }
    }

    Write-Info "Pulling model $($Script:SelectedModel)... (this may take a while)"
    try {
        ollama pull $Script:SelectedModel
        if ($LASTEXITCODE -ne 0) { throw "ollama pull failed" }
    }
    catch {
        Write-Err "Model download failed. Check your internet connection and disk space."
        exit 3
    }
    Write-Success "Model $($Script:SelectedModel) pulled successfully"
}

# ---------------------------------------------------------------------------
# Claude Code installation
# ---------------------------------------------------------------------------

function Install-ClaudeCode {
    try {
        $null = Get-Command claude -ErrorAction Stop
        Write-Success "Claude Code already installed"
        return
    }
    catch {
        # Not installed
    }

    Write-Info "Installing Claude Code..."
    try {
        npm install -g @anthropic-ai/claude-code
        if ($LASTEXITCODE -ne 0) { throw "npm install failed" }
    }
    catch {
        Write-Err "Claude Code installation failed."
        Write-Err "Try manually: npm install -g @anthropic-ai/claude-code"
        exit 3
    }

    # Refresh PATH
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

    # Verify
    try {
        $null = Get-Command claude -ErrorAction Stop
    }
    catch {
        Write-Warn "Claude Code installed but 'claude' not found in PATH."
        Write-Warn "You may need to restart your terminal."
        $NpmGlobalBin = (npm root -g) -replace 'node_modules$', ''
        Write-Warn "Expected location: $NpmGlobalBin"
    }
    Write-Success "Claude Code installed"
}

# ---------------------------------------------------------------------------
# Environment variable configuration
# ---------------------------------------------------------------------------

function Set-EnvVars {
    Write-Info "Configuring environment variables..."

    # Check for existing env vars
    $HasExisting = $false
    $ExistingBaseUrl = [System.Environment]::GetEnvironmentVariable("ANTHROPIC_BASE_URL", "User")
    $ExistingApiKey = [System.Environment]::GetEnvironmentVariable("ANTHROPIC_API_KEY", "User")
    $ExistingAuthToken = [System.Environment]::GetEnvironmentVariable("ANTHROPIC_AUTH_TOKEN", "User")

    if ($ExistingBaseUrl -or $ExistingApiKey -or $ExistingAuthToken) {
        $HasExisting = $true
    }

    # Check for sentinel in PowerShell profile
    $HasSentinel = $false
    if ((Test-Path $PROFILE) -and (Get-Content $PROFILE -Raw) -match [regex]::Escape($Script:SENTINEL_START)) {
        $HasSentinel = $true
    }

    if ($HasExisting) {
        Write-Warn "Existing Anthropic API configuration detected."
        if ($ExistingBaseUrl) { Write-Warn "  ANTHROPIC_BASE_URL=$ExistingBaseUrl" }
        if ($ExistingApiKey) { Write-Warn "  ANTHROPIC_API_KEY=<set>" }

        # Backup
        if (-not (Test-Path $Script:BACKUP_DIR)) {
            New-Item -Path $Script:BACKUP_DIR -ItemType Directory -Force | Out-Null
        }
        $BackupFile = Join-Path $Script:BACKUP_DIR "env-backup-$(Get-Date -Format 'yyyyMMddHHmmss')"
        @(
            "# Backup created: $(Get-Date)"
            "ANTHROPIC_BASE_URL=$ExistingBaseUrl"
            "ANTHROPIC_API_KEY=$ExistingApiKey"
            "ANTHROPIC_AUTH_TOKEN=$ExistingAuthToken"
        ) | Set-Content $BackupFile
        Write-Info "Existing values backed up to $Script:BACKUP_DIR/"

        if ($Silent -and -not $Force) {
            Write-Err "Existing Anthropic configuration detected. Use -Force to overwrite."
            exit 2
        }

        if (-not $Silent -and -not $Force) {
            $Confirm = Read-Host "Overwrite existing configuration? [y/N]"
            if ($Confirm -ne 'y' -and $Confirm -ne 'Y') {
                Write-Err "Aborted. Existing configuration preserved."
                exit 2
            }
        }
    }

    # Set env vars for current session
    $env:ANTHROPIC_BASE_URL = $Script:OLLAMA_API_URL
    $env:ANTHROPIC_AUTH_TOKEN = "ollama"
    $env:ANTHROPIC_API_KEY = ""
    $env:OLLAMA_NUM_CTX = $Script:SelectedNumCtx.ToString()

    # Persist to PowerShell profile with sentinel markers
    if (-not (Test-Path $PROFILE)) {
        $ProfileDir = Split-Path $PROFILE -Parent
        if (-not (Test-Path $ProfileDir)) {
            New-Item -Path $ProfileDir -ItemType Directory -Force | Out-Null
        }
        New-Item -Path $PROFILE -ItemType File -Force | Out-Null
    }
    else {
        # Backup profile
        Copy-Item $PROFILE "$PROFILE.claude-backup.$(Get-Date -Format 'yyyyMMddHHmmss')"
    }

    # Remove existing sentinel block if present
    if ($HasSentinel) {
        $ProfileContent = Get-Content $PROFILE -Raw
        $Pattern = "(?s)$([regex]::Escape($Script:SENTINEL_START)).*?$([regex]::Escape($Script:SENTINEL_END))\r?\n?"
        $ProfileContent = $ProfileContent -replace $Pattern, ''
        Set-Content $PROFILE $ProfileContent -NoNewline
    }

    # Append new sentinel block
    $GitBashLine = ""
    if ($env:CLAUDE_CODE_GIT_BASH_PATH) {
        $GitBashLine = "`n`$env:CLAUDE_CODE_GIT_BASH_PATH = `"$($env:CLAUDE_CODE_GIT_BASH_PATH)`""
    }
    $EnvBlock = @"

$($Script:SENTINEL_START)
`$env:ANTHROPIC_BASE_URL = "$($Script:OLLAMA_API_URL)"
`$env:ANTHROPIC_AUTH_TOKEN = "ollama"
`$env:ANTHROPIC_API_KEY = ""
`$env:OLLAMA_NUM_CTX = "$($Script:SelectedNumCtx)"$GitBashLine
$($Script:SENTINEL_END)
"@

    try {
        Add-Content -Path $PROFILE -Value $EnvBlock
    }
    catch {
        Write-Err "Cannot write to $PROFILE."
        Write-Err "Manually add these lines to your PowerShell profile:"
        Write-Host ""
        Write-Host "  `$env:ANTHROPIC_BASE_URL = `"$($Script:OLLAMA_API_URL)`""
        Write-Host "  `$env:ANTHROPIC_AUTH_TOKEN = `"ollama`""
        Write-Host "  `$env:ANTHROPIC_API_KEY = `"`""
        Write-Host "  `$env:OLLAMA_NUM_CTX = `"$($Script:SelectedNumCtx)`""
        exit 5
    }

    Write-Success "Environment variables configured in $PROFILE"
}

# ---------------------------------------------------------------------------
# Ollama service management
# ---------------------------------------------------------------------------

function Start-OllamaService {
    Write-Info "Ensuring Ollama is running..."

    # Check if already running
    try {
        $null = Invoke-RestMethod -Uri "$Script:OLLAMA_API_URL/api/version" -TimeoutSec 3 -ErrorAction Stop
        Write-Success "Ollama is already running"
        return
    }
    catch {
        # Not running
    }

    # Start Ollama
    Write-Info "Starting Ollama..."
    Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden

    # Wait with exponential backoff
    if (-not (Wait-ForOllama)) {
        Write-Err "Ollama failed to start within 30 seconds."
        Write-Err "Try running 'ollama serve' manually and check for errors."
        exit 3
    }
    Write-Success "Ollama is running"
}

function Wait-ForOllama {
    $MaxWait = 30
    $Waited = 0
    $Interval = 1

    while ($Waited -lt $MaxWait) {
        try {
            $null = Invoke-RestMethod -Uri "$Script:OLLAMA_API_URL/api/version" -TimeoutSec 2 -ErrorAction Stop
            return $true
        }
        catch {
            Start-Sleep -Seconds $Interval
            $Waited += $Interval
            $Interval = [math]::Min($Interval * 2, 8)
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Two-phase verification
# ---------------------------------------------------------------------------

function Invoke-Verify {
    Write-Info "Running verification..."

    # Ensure env vars are set
    if (-not $env:ANTHROPIC_BASE_URL) { $env:ANTHROPIC_BASE_URL = $Script:OLLAMA_API_URL }
    if (-not $env:ANTHROPIC_AUTH_TOKEN) { $env:ANTHROPIC_AUTH_TOKEN = "ollama" }
    if ($null -eq $env:ANTHROPIC_API_KEY) { $env:ANTHROPIC_API_KEY = "" }

    # Detect model if not set (standalone -Verify)
    if (-not $Script:SelectedModel) {
        $ModelList = ollama list 2>&1 | Out-String
        $Lines = $ModelList.Trim().Split("`n")
        if ($Lines.Count -gt 1) {
            $Script:SelectedModel = ($Lines[1].Trim() -split '\s+')[0]
        }
        if (-not $Script:SelectedModel) {
            Write-Err "No models found. Run '.\setup.ps1' first."
            exit 4
        }
        Write-Info "Using model: $($Script:SelectedModel)"
    }

    # Check Ollama is running
    try {
        $null = Invoke-RestMethod -Uri "$Script:OLLAMA_API_URL/api/version" -TimeoutSec 5 -ErrorAction Stop
    }
    catch {
        Write-Err "Ollama is not responding at $Script:OLLAMA_API_URL"
        Write-Err "Start Ollama with: ollama serve"
        exit 4
    }
    Write-Success "Ollama is responding"

    # Phase 1: Model warm-up (skip for cloud models -- they run on remote infra)
    if ($Script:IsCloudModel) {
        Write-Info "Phase 1: Skipping local warm-up (cloud model)"
    }
    else {
        Write-Info "Phase 1: Warming up model $($Script:SelectedModel)..."
        Write-Info "(This may take 30-180 seconds on first run as the model loads into memory)"

        try {
            $Body = @{ model = $Script:SelectedModel; prompt = "hi"; stream = $false } | ConvertTo-Json
            $null = Invoke-RestMethod -Uri "$Script:OLLAMA_API_URL/api/generate" -Method Post -Body $Body -ContentType "application/json" -TimeoutSec 180 -ErrorAction Stop
        }
        catch {
            Write-Err "Model warm-up failed (timeout or error)."
            Write-Err "Your hardware may not have enough RAM for $($Script:SelectedModel)."
            Write-Host ""
            Write-Err "Diagnostics:"
            Write-Host "  Model: $($Script:SelectedModel)"
            Write-Host "  RAM: $Script:DetectedRamGb GB"
            try { Write-Host "  Ollama status: $(ollama ps 2>&1)" } catch { Write-Host "  Ollama status: unavailable" }
            exit 4
        }
        Write-Success "Model loaded and responding"
    }

    # Phase 2: Claude Code end-to-end test
    Write-Info "Phase 2: Testing Claude Code integration..."
    $VerifyTimeoutMs = if ($Script:IsCloudModel) { 120000 } else { 60000 }
    $VerifyTimeoutSec = $VerifyTimeoutMs / 1000

    try {
        # claude is a .ps1 wrapper on Windows -- must run through powershell.exe, not Start-Process directly
        $ClaudeCmd = "claude -p 'respond with OK' --model '$($Script:SelectedModel)'"
        $Process = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile", "-Command", $ClaudeCmd -NoNewWindow -PassThru -RedirectStandardOutput "$env:TEMP\claude-verify-out.txt" -RedirectStandardError "$env:TEMP\claude-verify-err.txt"

        if (-not $Process.WaitForExit($VerifyTimeoutMs)) {
            $Process.Kill()
            throw "Claude Code timed out after $VerifyTimeoutSec seconds"
        }

        if ($null -ne $Process.ExitCode -and $Process.ExitCode -ne 0) {
            $ErrorOutput = Get-Content "$env:TEMP\claude-verify-err.txt" -Raw -ErrorAction SilentlyContinue
            throw "Claude Code exited with code $($Process.ExitCode): $ErrorOutput"
        }
    }
    catch {
        Write-Err "Claude Code verification failed."
        Write-Err "$_"
        Write-Host ""
        # Show captured stderr/stdout for debugging
        $StderrContent = Get-Content "$env:TEMP\claude-verify-err.txt" -Raw -ErrorAction SilentlyContinue
        $StdoutContent = Get-Content "$env:TEMP\claude-verify-out.txt" -Raw -ErrorAction SilentlyContinue
        if ($StderrContent) {
            Write-Err "stderr: $($StderrContent.Trim())"
        }
        if ($StdoutContent) {
            Write-Info "stdout: $($StdoutContent.Trim())"
        }
        Write-Host ""
        Write-Err "Diagnostics:"
        try { $null = Invoke-RestMethod -Uri "$Script:OLLAMA_API_URL/api/version" -TimeoutSec 3; Write-Host "  1. Ollama: responding" } catch { Write-Host "  1. Ollama: NOT responding" }
        try { Write-Host "  2. Model loaded: $(ollama ps 2>&1 | Select-String $Script:SelectedModel)" } catch { Write-Host "  2. Model loaded: unknown" }
        Write-Host "  3. ANTHROPIC_BASE_URL=$env:ANTHROPIC_BASE_URL"
        Write-Host "  4. ANTHROPIC_AUTH_TOKEN=$env:ANTHROPIC_AUTH_TOKEN"
        Write-Host "  5. CLAUDE_CODE_GIT_BASH_PATH=$env:CLAUDE_CODE_GIT_BASH_PATH"
        Write-Host ""
        Write-Err "Try running manually: claude -p 'respond with OK' --model $($Script:SelectedModel)"
        exit 4
    }
    finally {
        Remove-Item "$env:TEMP\claude-verify-out.txt" -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:TEMP\claude-verify-err.txt" -Force -ErrorAction SilentlyContinue
    }

    Write-Success "Claude Code is working with $($Script:SelectedModel)!"
    Write-Host ""
    Write-Host "Setup complete!" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Run Claude Code:  " -NoNewline; Write-Host "claude" -ForegroundColor White
    if ($Script:IsCloudModel) {
        Write-Host "  Or use shortcut:  " -NoNewline; Write-Host "ollama launch claude --model $($Script:SelectedModel)" -ForegroundColor White
    }
    Write-Host "  Verify later:     " -NoNewline; Write-Host ".\setup.ps1 -Verify" -ForegroundColor White
    Write-Host ""
    Write-Host "  Note: Open a new PowerShell window to apply env vars." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Main install flow
# ---------------------------------------------------------------------------

function Invoke-Install {
    Write-Host ""
    Write-Host "Claude Code + Ollama Setup Toolkit v$Script:VERSION" -ForegroundColor White
    Write-Host "==========================================="
    Write-Host ""

    Test-Prerequisites
    Install-Ollama
    Get-DetectedHardware
    Select-Model
    Save-Model
    Install-ClaudeCode
    Set-EnvVars
    Start-OllamaService
    Invoke-Verify
}

# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------

if ($Help) {
    Show-Help
}
elseif ($Verify) {
    Invoke-Verify
}
else {
    Invoke-Install
}
