#!/usr/bin/env bash
#
# setup.sh -- Claude Code + Ollama Setup Toolkit (macOS/Linux)
#
# Installs and configures Claude Code to use Ollama's native Anthropic-compatible API.
# Usage: ./setup.sh [--install] [--silent] [--verify] [--help]
#
# See README.md for full documentation.

set -eu -o pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

readonly VERSION="1.0.0"
readonly MIN_NODE_VERSION="18"
readonly MIN_OLLAMA_VERSION="0.15.3"
readonly OLLAMA_API_URL="http://localhost:11434"
readonly SENTINEL_START="# >>> claude-code-ollama >>>"
readonly SENTINEL_END="# <<< claude-code-ollama <<<"
readonly BACKUP_DIR="$HOME/.claude-code-ollama-backup"
readonly MODEL_NAME_REGEX='^[a-zA-Z0-9_.-]+:[a-zA-Z0-9_.-]+$'

# Model recommendation table -- update here when models change
# Format: min_ram_gb:model:size_on_disk_gb:num_ctx
readonly -a MODEL_TABLE=(
    "0:qwen2.5-coder:3b:2:8192"
    "8:qwen2.5-coder:7b:4.5:16384"
    "12:qwen2.5-coder:14b:9:32768"
    "16:deepseek-coder-v2:16b:10:49152"
    "32:qwen2.5-coder:32b:20:65536"
)

# Cloud model options -- run on Ollama's infrastructure, no local download needed
# Format: model:description
readonly -a CLOUD_MODELS=(
    "kimi-k2.5:cloud:Kimi K2.5 -- fast cloud model"
    "glm-5:cloud:GLM 5 -- strong general reasoning"
    "minimax-m2.7:cloud:MiniMax M2.7 -- balanced cloud model"
    "qwen3.5:cloud:Qwen 3.5 -- versatile cloud coding model"
)

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

MODE="install"
SILENT=false
FORCE=false
SELECTED_MODEL=""
SELECTED_NUM_CTX=""
SELECTED_SIZE_GB=""
IS_CLOUD_MODEL=false
DETECTED_RAM_GB=0
SHELL_PROFILE=""

# ---------------------------------------------------------------------------
# Colors & Output
# ---------------------------------------------------------------------------

if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    BOLD=$(tput bold)
    RESET=$(tput sgr0)
else
    RED="" GREEN="" YELLOW="" BLUE="" BOLD="" RESET=""
fi

info()  { echo "${BLUE}[INFO]${RESET} $*"; }
warn()  { echo "${YELLOW}[WARN]${RESET} $*" >&2; }
error() { echo "${RED}[ERROR]${RESET} $*" >&2; }
success() { echo "${GREEN}[OK]${RESET} $*"; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --install)  MODE="install" ;;
            --silent)   SILENT=true ;;
            --verify)   MODE="verify" ;;
            --force)    FORCE=true ;;
            --help|-h)  MODE="help" ;;
            *)
                error "Unknown option: $1"
                echo "Run './setup.sh --help' for usage."
                exit 1
                ;;
        esac
        shift
    done
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

show_help() {
    cat <<EOF
${BOLD}Claude Code + Ollama Setup Toolkit v${VERSION}${RESET}

${BOLD}Usage:${RESET}
  ./setup.sh [OPTIONS]

${BOLD}Options:${RESET}
  --install     Full guided setup (default)
  --silent      Non-interactive mode, uses auto-detected defaults
  --verify      Run health check only
  --force       Overwrite existing Anthropic env var configuration
  --help, -h    Show this help message

${BOLD}Examples:${RESET}
  ./setup.sh                  # Interactive setup
  ./setup.sh --silent         # Automated setup with defaults
  ./setup.sh --verify         # Check if everything works
  ./setup.sh --silent --force # Overwrite existing config silently

${BOLD}More info:${RESET} https://github.com/YOUR_USERNAME/claude-code-ollama
EOF
}

# ---------------------------------------------------------------------------
# OS detection
# ---------------------------------------------------------------------------

detect_os() {
    case "$(uname -s)" in
        Linux*)  OS="linux" ;;
        Darwin*) OS="macos" ;;
        *)
            error "Unsupported operating system: $(uname -s)"
            error "This script supports macOS and Linux only. For Windows, use setup.ps1."
            exit 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Version comparison
# ---------------------------------------------------------------------------

version_gte() {
    # Returns 0 if $1 >= $2
    [ "$(printf '%s\n%s' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------

check_prerequisites() {
    info "Checking prerequisites..."

    # Warn if running as root
    if [ "$(id -u)" -eq 0 ]; then
        warn "Running as root. This is not recommended -- Ollama and Claude Code"
        warn "should be installed as your normal user to avoid permission issues."
    fi

    # Node.js
    if ! command -v node >/dev/null 2>&1; then
        error "Node.js is not installed."
        error "Claude Code requires Node.js ${MIN_NODE_VERSION}+."
        error "Install from: https://nodejs.org"
        exit 1
    fi

    local node_version
    node_version="$(node --version | sed 's/^v//')"
    local node_major
    node_major="$(echo "$node_version" | cut -d. -f1)"

    if [ "$node_major" -lt "$MIN_NODE_VERSION" ]; then
        error "Node.js ${MIN_NODE_VERSION}+ required. Current: v${node_version}"
        error "Upgrade at: https://nodejs.org"
        exit 1
    fi
    success "Node.js v${node_version}"
}

# ---------------------------------------------------------------------------
# Ollama installation
# ---------------------------------------------------------------------------

get_ollama_version() {
    ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

download_and_run_ollama_installer() {
    info "Downloading Ollama installer..."
    local tmpdir
    tmpdir="$(mktemp -d /tmp/ollama-install.XXXXXX)"
    local tmpfile="$tmpdir/install.sh"
    curl -fSL "https://ollama.com/install.sh" -o "$tmpfile"
    chmod +x "$tmpfile"
    bash "$tmpfile"
    rm -rf "$tmpdir"
}

install_ollama() {
    if command -v ollama >/dev/null 2>&1; then
        local ollama_version
        ollama_version="$(get_ollama_version)"
        if [ -n "$ollama_version" ] && version_gte "$ollama_version" "$MIN_OLLAMA_VERSION"; then
            success "Ollama v${ollama_version} already installed"
            return 0
        fi
        warn "Ollama needs upgrading to v${MIN_OLLAMA_VERSION}+"
    fi

    info "Installing/upgrading Ollama..."

    if [ "$OS" = "macos" ] && command -v brew >/dev/null 2>&1; then
        info "Using Homebrew..."
        brew install ollama || brew upgrade ollama
    else
        download_and_run_ollama_installer
    fi

    # Verify installation
    if ! command -v ollama >/dev/null 2>&1; then
        error "Ollama installation failed. Install manually from https://ollama.com"
        exit 3
    fi

    local ollama_version
    ollama_version="$(get_ollama_version)"
    if [ -n "$ollama_version" ] && version_gte "$ollama_version" "$MIN_OLLAMA_VERSION"; then
        success "Ollama v${ollama_version} installed"
    else
        error "Ollama v${MIN_OLLAMA_VERSION}+ required after install. Got: v${ollama_version:-unknown}"
        error "Try upgrading manually: https://ollama.com"
        exit 3
    fi
}

# ---------------------------------------------------------------------------
# Hardware detection
# ---------------------------------------------------------------------------

detect_hardware() {
    info "Detecting hardware..."

    if [ "$OS" = "linux" ]; then
        DETECTED_RAM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
    elif [ "$OS" = "macos" ]; then
        local ram_bytes
        ram_bytes="$(sysctl -n hw.memsize)"
        DETECTED_RAM_GB=$(( ram_bytes / 1073741824 ))
    fi

    info "Detected RAM: ${DETECTED_RAM_GB} GB"

    if [ "$DETECTED_RAM_GB" -lt 8 ]; then
        warn "Less than 8 GB RAM detected. Local model performance will be limited."
        warn "You can proceed, but expect slow responses and reduced capabilities."
    fi
}

# ---------------------------------------------------------------------------
# Model selection
# ---------------------------------------------------------------------------

recommend_model() {
    local recommended_model="" recommended_ctx="" recommended_size=""
    local min_ram model size ctx

    for entry in "${MODEL_TABLE[@]}"; do
        IFS=: read -r min_ram model_name model_tag size ctx <<< "$entry"
        model="${model_name}:${model_tag}"

        if [ "$DETECTED_RAM_GB" -ge "$min_ram" ]; then
            recommended_model="$model"
            recommended_size="$size"
            recommended_ctx="$ctx"
        fi
    done

    if [ -z "$recommended_model" ]; then
        recommended_model="qwen2.5-coder:3b"
        recommended_size="2"
        recommended_ctx="8192"
    fi

    echo ""
    info "${BOLD}Recommended local model: ${recommended_model}${RESET}"
    info "  Download size: ~${recommended_size} GB"
    info "  Context window: ${recommended_ctx} tokens"
    echo ""
    info "Cloud models (run on Ollama's servers, no download):"
    local cloud_index=1
    for cloud_entry in "${CLOUD_MODELS[@]}"; do
        local cloud_model cloud_desc
        # Format: model_name:model_tag:description
        cloud_model="$(echo "$cloud_entry" | cut -d: -f1-2)"
        cloud_desc="$(echo "$cloud_entry" | cut -d: -f3-)"
        echo "  ${cloud_index}. ${cloud_model}  -- ${cloud_desc}"
        cloud_index=$((cloud_index + 1))
    done
    echo ""

    if [ "$SILENT" = true ]; then
        SELECTED_MODEL="$recommended_model"
        SELECTED_NUM_CTX="$recommended_ctx"
        SELECTED_SIZE_GB="$recommended_size"
        return 0
    fi

    # Interactive mode: ask user
    printf "%s" "Use ${BOLD}${recommended_model}${RESET}? [Y/n/cloud/custom]: "
    local answer
    read -r answer

    case "$answer" in
        ""|[Yy]|[Yy]es)
            SELECTED_MODEL="$recommended_model"
            SELECTED_NUM_CTX="$recommended_ctx"
            SELECTED_SIZE_GB="$recommended_size"
            ;;
        cloud|[Cc]loud)
            echo ""
            printf "Select a cloud model (1-%d) or enter a name (e.g., kimi-k2.5:cloud): " "${#CLOUD_MODELS[@]}"
            local cloud_choice
            read -r cloud_choice
            if [[ "$cloud_choice" =~ ^[0-9]+$ ]] && [ "$cloud_choice" -ge 1 ] && [ "$cloud_choice" -le "${#CLOUD_MODELS[@]}" ]; then
                local chosen_entry="${CLOUD_MODELS[$((cloud_choice - 1))]}"
                SELECTED_MODEL="$(echo "$chosen_entry" | cut -d: -f1-2)"
            elif [[ "$cloud_choice" =~ $MODEL_NAME_REGEX ]]; then
                SELECTED_MODEL="$cloud_choice"
            else
                error "Invalid selection. Expected: number (1-${#CLOUD_MODELS[@]}) or model name (e.g., kimi-k2.5:cloud)"
                exit 1
            fi
            IS_CLOUD_MODEL=true
            SELECTED_NUM_CTX="65536"
            SELECTED_SIZE_GB=""
            info "Cloud models run at full context length on Ollama's servers."
            ;;
        [Nn]|[Nn]o|custom)
            printf "Enter model name (e.g., qwen2.5-coder:14b or kimi-k2.5:cloud): "
            read -r custom_model
            if [[ ! "$custom_model" =~ $MODEL_NAME_REGEX ]]; then
                error "Invalid model name format. Expected: name:tag (e.g., qwen2.5-coder:7b)"
                exit 1
            fi
            SELECTED_MODEL="$custom_model"
            if [[ "$custom_model" =~ :.*cloud$ ]]; then
                IS_CLOUD_MODEL=true
                SELECTED_NUM_CTX="65536"
                SELECTED_SIZE_GB=""
                info "Cloud model detected. Runs on Ollama's servers."
            else
                SELECTED_NUM_CTX="$recommended_ctx"
                SELECTED_SIZE_GB="$recommended_size"
                warn "Using custom model. Context window set to ${recommended_ctx}. Override with OLLAMA_NUM_CTX env var if needed."
            fi
            ;;
        *)
            if [[ "$answer" =~ $MODEL_NAME_REGEX ]]; then
                SELECTED_MODEL="$answer"
                if [[ "$answer" =~ :.*cloud$ ]]; then
                    IS_CLOUD_MODEL=true
                    SELECTED_NUM_CTX="65536"
                    SELECTED_SIZE_GB=""
                else
                    SELECTED_NUM_CTX="$recommended_ctx"
                    SELECTED_SIZE_GB="$recommended_size"
                fi
            else
                error "Invalid model name format. Expected: name:tag (e.g., qwen2.5-coder:7b)"
                exit 1
            fi
            ;;
    esac

    if [ "$IS_CLOUD_MODEL" = true ]; then
        success "Selected model: ${SELECTED_MODEL} (cloud)"
    else
        success "Selected model: ${SELECTED_MODEL}"
    fi
}

# ---------------------------------------------------------------------------
# Model pull
# ---------------------------------------------------------------------------

check_disk_space() {
    local required_gb="$1"
    local target_dir="${OLLAMA_MODELS:-$HOME/.ollama}"
    # Ensure directory exists for df check
    [ -d "$target_dir" ] || target_dir="$HOME"
    local available_gb
    available_gb="$(df -k "$target_dir" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1048576}')"
    if [ -n "$available_gb" ] && [ "$available_gb" -lt "$required_gb" ]; then
        error "Insufficient disk space. Need ~${required_gb} GB, have ${available_gb} GB available."
        exit 3
    fi
}

pull_model() {
    # Cloud models run on Ollama's servers -- no local pull needed
    if [ "$IS_CLOUD_MODEL" = true ]; then
        info "Cloud model selected -- no local download needed."
        info "Ensuring you are signed in to Ollama..."
        if ollama whoami >/dev/null 2>&1; then
            success "Signed in to Ollama"
        else
            warn "You need to sign in to Ollama to use cloud models."
            info "Run: ollama signin"
            if ! ollama signin; then
                error "Ollama sign-in failed. Sign in manually with: ollama signin"
                exit 3
            fi
            success "Signed in to Ollama"
        fi
        return 0
    fi

    if ollama list 2>/dev/null | grep -qF "$SELECTED_MODEL"; then
        success "Model ${SELECTED_MODEL} already pulled"
        return 0
    fi

    # Check disk space before downloading
    if [ -n "$SELECTED_SIZE_GB" ]; then
        check_disk_space "${SELECTED_SIZE_GB%%.*}"
    fi

    info "Pulling model ${SELECTED_MODEL}... (this may take a while)"
    if ! ollama pull "$SELECTED_MODEL"; then
        error "Model download failed. Check your internet connection and disk space."
        exit 3
    fi
    success "Model ${SELECTED_MODEL} pulled successfully"
}

# ---------------------------------------------------------------------------
# Claude Code installation
# ---------------------------------------------------------------------------

install_claude_code() {
    if command -v claude >/dev/null 2>&1; then
        success "Claude Code already installed"
        return 0
    fi

    info "Installing Claude Code..."
    if ! npm install -g @anthropic-ai/claude-code; then
        warn "npm install failed (may need elevated permissions)."
        if [ "$SILENT" = true ]; then
            error "Claude Code installation failed. Try: sudo npm install -g @anthropic-ai/claude-code"
            exit 3
        fi
        printf "Retry with sudo? [y/N]: "
        local retry
        read -r retry
        if [ "$retry" = "y" ] || [ "$retry" = "Y" ]; then
            if ! sudo npm install -g @anthropic-ai/claude-code; then
                error "Claude Code installation failed."
                exit 3
            fi
        else
            error "Claude Code installation failed."
            error "Try manually: sudo npm install -g @anthropic-ai/claude-code"
            exit 3
        fi
    fi

    # Verify installation -- resolve full path to avoid PATH issues
    local claude_bin
    claude_bin="$(npm root -g)/.bin/claude"
    if [ ! -f "$claude_bin" ] && ! command -v claude >/dev/null 2>&1; then
        error "Claude Code installed but 'claude' binary not found in PATH."
        error "You may need to restart your terminal or add npm global bin to PATH."
        exit 3
    fi
    success "Claude Code installed"
}

# ---------------------------------------------------------------------------
# Shell profile detection
# ---------------------------------------------------------------------------

detect_shell_profile() {
    if [ -n "${SHELL:-}" ]; then
        case "$SHELL" in
            */zsh)
                SHELL_PROFILE="$HOME/.zshrc"
                ;;
            */bash)
                if [ -f "$HOME/.bashrc" ]; then
                    SHELL_PROFILE="$HOME/.bashrc"
                elif [ -f "$HOME/.bash_profile" ]; then
                    SHELL_PROFILE="$HOME/.bash_profile"
                else
                    SHELL_PROFILE="$HOME/.bashrc"
                fi
                ;;
            *)
                SHELL_PROFILE="$HOME/.profile"
                ;;
        esac
    else
        SHELL_PROFILE="$HOME/.profile"
    fi
}

# ---------------------------------------------------------------------------
# Environment variable configuration
# ---------------------------------------------------------------------------

configure_env_vars() {
    detect_shell_profile
    info "Configuring environment variables in ${SHELL_PROFILE}..."

    # Check for existing Anthropic env vars in current session
    local has_existing=false
    if [ -n "${ANTHROPIC_BASE_URL:-}" ] || [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
        has_existing=true
    fi

    # Check for existing sentinel block in profile
    local has_sentinel=false
    if [ -f "$SHELL_PROFILE" ] && grep -qF "$SENTINEL_START" "$SHELL_PROFILE"; then
        has_sentinel=true
    fi

    # Check for existing ANTHROPIC_ vars in profile (outside our sentinel block)
    local has_profile_vars=false
    if [ -f "$SHELL_PROFILE" ] && grep -q 'export ANTHROPIC_' "$SHELL_PROFILE" && [ "$has_sentinel" = false ]; then
        has_profile_vars=true
    fi

    if [ "$has_existing" = true ] || [ "$has_profile_vars" = true ]; then
        warn "Existing Anthropic API configuration detected."
        if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
            warn "  ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}"
        fi
        if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
            warn "  ANTHROPIC_API_KEY=<set>"
        fi

        # Backup existing values with restrictive permissions
        mkdir -p "$BACKUP_DIR"
        chmod 700 "$BACKUP_DIR"
        local backup_file="$BACKUP_DIR/env-backup-$(date +%s)"
        {
            echo "# Backup created: $(date)"
            echo "# Original profile: ${SHELL_PROFILE}"
            [ -n "${ANTHROPIC_BASE_URL:-}" ] && echo "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}"
            [ -n "${ANTHROPIC_API_KEY:-}" ] && echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}"
            [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] && echo "ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN}"
        } > "$backup_file"
        chmod 600 "$backup_file"
        info "Existing values backed up to ${BACKUP_DIR}/"

        if [ "$SILENT" = true ] && [ "$FORCE" = false ]; then
            error "Existing Anthropic configuration detected. Use --force to overwrite."
            exit 2
        fi

        if [ "$SILENT" = false ] && [ "$FORCE" = false ]; then
            printf "Overwrite existing configuration? [y/N]: "
            local confirm
            read -r confirm
            if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                error "Aborted. Existing configuration preserved."
                exit 2
            fi
        fi
    fi

    # Create profile backup
    if [ -f "$SHELL_PROFILE" ]; then
        cp "$SHELL_PROFILE" "${SHELL_PROFILE}.claude-backup.$(date +%s)"
    fi

    # Remove existing sentinel block if present (idempotent update)
    if [ "$has_sentinel" = true ]; then
        # Use sed to remove old block
        sed -i.bak "/${SENTINEL_START}/,/${SENTINEL_END}/d" "$SHELL_PROFILE"
        rm -f "${SHELL_PROFILE}.bak"
    fi

    # Append new sentinel block
    {
        echo ""
        echo "$SENTINEL_START"
        echo "export ANTHROPIC_BASE_URL=\"${OLLAMA_API_URL}\""
        echo "export ANTHROPIC_AUTH_TOKEN=\"ollama\""
        echo "export ANTHROPIC_API_KEY=\"\""
        echo "export OLLAMA_NUM_CTX=\"${SELECTED_NUM_CTX}\""
        echo "$SENTINEL_END"
    } >> "$SHELL_PROFILE" || {
        error "Cannot write to ${SHELL_PROFILE}."
        error "Manually add these lines to your shell profile:"
        echo ""
        echo "  export ANTHROPIC_BASE_URL=\"${OLLAMA_API_URL}\""
        echo "  export ANTHROPIC_AUTH_TOKEN=\"ollama\""
        echo "  export ANTHROPIC_API_KEY=\"\""
        echo "  export OLLAMA_NUM_CTX=${SELECTED_NUM_CTX}"
        exit 5
    }

    # Set in current session
    export ANTHROPIC_BASE_URL="${OLLAMA_API_URL}"
    export ANTHROPIC_AUTH_TOKEN="ollama"
    export ANTHROPIC_API_KEY=""
    export OLLAMA_NUM_CTX="${SELECTED_NUM_CTX}"

    success "Environment variables configured in ${SHELL_PROFILE}"
}

# ---------------------------------------------------------------------------
# Ollama service management
# ---------------------------------------------------------------------------

start_ollama_service() {
    info "Ensuring Ollama is running..."

    # Check if already running
    if curl -sf "${OLLAMA_API_URL}/api/version" >/dev/null 2>&1; then
        success "Ollama is already running"
        return 0
    fi

    # Start Ollama in the background
    info "Starting Ollama..."
    ollama serve >/dev/null 2>&1 &

    # Wait with exponential backoff
    if ! wait_for_ollama; then
        error "Ollama failed to start within 30 seconds."
        error "Try running 'ollama serve' manually and check for errors."
        exit 3
    fi
    success "Ollama is running"
}

wait_for_ollama() {
    local max_wait=30 waited=0 interval=1
    while ! curl -sf "${OLLAMA_API_URL}/api/version" >/dev/null 2>&1; do
        sleep "$interval"
        waited=$((waited + interval))
        interval=$((interval * 2 > 8 ? 8 : interval * 2))
        if [ "$waited" -ge "$max_wait" ]; then
            return 1
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# Two-phase verification
# ---------------------------------------------------------------------------

do_verify() {
    info "Running verification..."

    # Ensure env vars are set for this session (may have been sourced from profile)
    export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-${OLLAMA_API_URL}}"
    export ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-ollama}"
    export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"

    # Detect model if not already set (for standalone --verify)
    if [ -z "$SELECTED_MODEL" ]; then
        # Try to find a model from ollama list
        SELECTED_MODEL="$(ollama list 2>/dev/null | awk 'NR>1 {print $1; exit}')"
        if [ -z "$SELECTED_MODEL" ]; then
            error "No models found. Run './setup.sh --install' first."
            exit 4
        fi
        info "Using model: ${SELECTED_MODEL}"
    fi

    # Check Ollama is running
    if ! curl -sf "${OLLAMA_API_URL}/api/version" >/dev/null 2>&1; then
        error "Ollama is not responding at ${OLLAMA_API_URL}"
        error "Start Ollama with: ollama serve"
        exit 4
    fi
    success "Ollama is responding"

    # Phase 1: Model warm-up (skip for cloud models -- they run on remote infra)
    if [ "$IS_CLOUD_MODEL" = true ]; then
        info "Phase 1: Skipping local warm-up (cloud model)"
    else
        info "Phase 1: Warming up model ${SELECTED_MODEL}..."
        info "(This may take 30-180 seconds on first run as the model loads into memory)"

        local warmup_response
        if ! warmup_response="$(curl -sf -X POST "${OLLAMA_API_URL}/api/generate" \
            -H "Content-Type: application/json" \
            -d "{\"model\": \"${SELECTED_MODEL}\", \"prompt\": \"hi\", \"stream\": false}" \
            --max-time 180 2>&1)"; then
            error "Model warm-up failed (timeout or error)."
            error "Your hardware may not have enough RAM for ${SELECTED_MODEL}."
            echo ""
            error "Diagnostics:"
            echo "  Model: ${SELECTED_MODEL}"
            echo "  RAM: ${DETECTED_RAM_GB:-unknown} GB"
            echo "  Ollama status: $(ollama ps 2>/dev/null || echo 'unavailable')"
            exit 4
        fi
        success "Model loaded and responding"
    fi

    # Phase 2: Claude Code end-to-end test
    info "Phase 2: Testing Claude Code integration..."

    local claude_bin
    claude_bin="$(command -v claude 2>/dev/null || echo "$(npm root -g 2>/dev/null)/.bin/claude")"

    if [ ! -x "$claude_bin" ] && ! command -v claude >/dev/null 2>&1; then
        error "Claude Code binary not found. Install with: npm install -g @anthropic-ai/claude-code"
        exit 4
    fi

    local claude_response
    if ! claude_response="$(timeout 60 claude -p "respond with OK" --model "$SELECTED_MODEL" 2>&1)"; then
        error "Claude Code verification failed."
        echo ""
        error "Diagnostics:"
        echo "  1. Ollama: $(curl -sf "${OLLAMA_API_URL}/api/version" 2>/dev/null && echo "responding" || echo "NOT responding")"
        echo "  2. Model loaded: $(ollama ps 2>/dev/null | grep -c "$SELECTED_MODEL" || echo "unknown")"
        echo "  3. ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL:-unset}"
        echo "  4. ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN:-unset}"
        echo ""
        error "Try running manually: claude --model ${SELECTED_MODEL}"
        exit 4
    fi

    success "Claude Code is working with ${SELECTED_MODEL}!"
    echo ""
    echo "${GREEN}${BOLD}Setup complete!${RESET}"
    echo ""
    echo "  Run Claude Code:  ${BOLD}claude${RESET}"
    if [ "$IS_CLOUD_MODEL" = true ]; then
        echo "  Or use shortcut:  ${BOLD}ollama launch claude --model ${SELECTED_MODEL}${RESET}"
    fi
    echo "  Verify later:     ${BOLD}./setup.sh --verify${RESET}"
    echo ""
    if [ -n "$SHELL_PROFILE" ]; then
        echo "  ${YELLOW}Note: Run 'source ${SHELL_PROFILE}' or open a new terminal to apply env vars.${RESET}"
    fi
}

# ---------------------------------------------------------------------------
# Main install flow
# ---------------------------------------------------------------------------

do_install() {
    echo ""
    echo "${BOLD}Claude Code + Ollama Setup Toolkit v${VERSION}${RESET}"
    echo "==========================================="
    echo ""

    detect_os
    check_prerequisites
    install_ollama
    detect_hardware
    recommend_model
    pull_model
    install_claude_code
    configure_env_vars
    start_ollama_service
    do_verify
}

# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"
    case "$MODE" in
        install) do_install ;;
        verify)  detect_os; do_verify ;;
        help)    show_help ;;
    esac
}

main "$@"
