#!/usr/bin/env bash
# LinguaPi Raspberry Pi Installer
#
# Does everything in one shot:
#   1. Downloads the latest linux-arm64 release binary
#   2. Installs to /opt/lingua-pi/
#   3. Creates and enables a systemd service
#   4. Downloads a starter corpus (Gutenberg + Wikisource)
#   5. Sets up an LLM backend: llamafile (default) or Ollama
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/chaoticfly/lingua-pi/master/scripts/install-pi.sh | bash
#
#   With options:
#   VERSION=v1.0.0 BOOKS_PER_LANG=25 bash install-pi.sh
#   SKIP_CORPUS=1  bash install-pi.sh   # skip corpus download
#   SKIP_OLLAMA=1  bash install-pi.sh   # skip LLM setup entirely
#
# Requires: curl, python3, systemd

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
REPO="chaoticfly/lingua-pi"
INSTALL_DIR="/opt/lingua-pi"
SERVICE_NAME="linguapi"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
BIN_LINK="/usr/local/bin/lingua-pi"
BOOKS_PER_LANG="${BOOKS_PER_LANG:-10}"
SKIP_CORPUS="${SKIP_CORPUS:-0}"
SKIP_OLLAMA="${SKIP_OLLAMA:-0}"
DEFAULT_MODEL="gemma4:e4b"

LLAMAFILE_URL="https://huggingface.co/mozilla-ai/llamafile_0.10/resolve/main/gemma-4-E4B-it-Q5_K_M.llamafile"
LLAMAFILE_NAME="gemma-4-E4B-it-Q5_K_M.llamafile"
LLAMAFILE_MODEL="gemma-4-E4B-it-Q5_K_M"
LLAMAFILE_PORT="8081"

# Set by prompt_llm_backend(); used across steps
LLM_BACKEND="llamafile"

# ── Colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
info()    { echo -e "${CYAN}  >>  ${NC}$*"; }
success() { echo -e "${GREEN}  OK  ${NC}$*"; }
warn()    { echo -e "${YELLOW}  !!  ${NC}$*"; }
die()     { echo -e "${RED}  ERR ${NC}$*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}$*${NC}"; }

# ── Temp dir (cleaned up on exit) ───────────────────────────────────────────
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ── Helpers ──────────────────────────────────────────────────────────────────
check_deps() {
    for cmd in curl python3; do
        command -v "$cmd" >/dev/null 2>&1 \
            || die "'$cmd' not found. Run: sudo apt-get install -y $cmd"
    done
    command -v systemctl >/dev/null 2>&1 \
        || die "systemd is required. This installer is designed for Raspberry Pi OS."
}

detect_arch() {
    case "$(uname -m)" in
        aarch64 | arm64) echo "arm64" ;;
        x86_64  | amd64) echo "amd64" ;;
        *) die "Unsupported architecture: $(uname -m). Pi 4/5 require a 64-bit OS." ;;
    esac
}

resolve_version() {
    if [[ -n "${VERSION:-}" ]]; then echo "$VERSION"; return; fi
    info "Resolving latest release..."
    local v
    v=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null) \
        || die "Could not fetch latest version. Set VERSION= manually."
    [[ -n "$v" ]] || die "GitHub returned an empty tag. Set VERSION= manually."
    echo "$v"
}

# Determine which user to run the service as (not root)
service_user() {
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        echo "$SUDO_USER"
    elif id pi &>/dev/null; then
        echo "pi"
    else
        echo "$(logname 2>/dev/null || echo root)"
    fi
}

# ── LLM backend prompt ───────────────────────────────────────────────────────
# Asks the user which backend to use and sets LLM_BACKEND="llamafile"|"ollama".
# Called before the service install so the systemd unit can reference the right dep.
prompt_llm_backend() {
    if [[ "$SKIP_OLLAMA" == "1" ]]; then
        LLM_BACKEND="skip"
        return
    fi

    echo ""
    if command -v ollama &>/dev/null; then
        success "Ollama detected: $(ollama --version 2>/dev/null || echo 'installed')"
        echo ""
        echo "  LinguaPi supports two local LLM backends:"
        echo "    [L] llamafile  — 3-4× faster, lower power, single .llamafile executable"
        echo "    [O] Ollama     — already installed, familiar 'ollama pull' workflow"
        read -r -p "  Which backend do you want to use? [L/o] " choice
    else
        echo "  No LLM backend detected. Choose one to set up:"
        echo "    [L] llamafile  — fast single executable, no separate server to manage"
        echo "    [O] Ollama     — install Ollama and pull ${DEFAULT_MODEL} (~2.5 GB)"
        read -r -p "  Which backend do you want to use? [L/o] " choice
    fi

    choice="${choice:-L}"
    if [[ "$choice" =~ ^[Oo] ]]; then
        LLM_BACKEND="ollama"
    else
        LLM_BACKEND="llamafile"
    fi
    info "Selected backend: ${LLM_BACKEND}"
}

# ── Step 1: Download & install binary ───────────────────────────────────────
install_binary() {
    local version="$1" arch="$2"
    local archive="lingua-pi-linux-${arch}.tar.gz"
    local url="https://github.com/${REPO}/releases/download/${version}/${archive}"

    info "Downloading ${archive}..."
    curl -fsSL --progress-bar "$url" -o "${WORK}/${archive}" \
        || die "Download failed. Does ${version} exist? https://github.com/${REPO}/releases"

    info "Extracting..."
    tar -xzf "${WORK}/${archive}" -C "$WORK"

    info "Installing to ${INSTALL_DIR}..."
    sudo mkdir -p "$INSTALL_DIR"
    sudo cp "${WORK}/lingua-pi/lingua-pi"     "${INSTALL_DIR}/lingua-pi"
    sudo chmod +x "${INSTALL_DIR}/lingua-pi"
    sudo cp -r "${WORK}/lingua-pi/static"     "${INSTALL_DIR}/static"

    sudo tee "$BIN_LINK" > /dev/null <<WRAPPER
#!/usr/bin/env bash
cd ${INSTALL_DIR}
exec ${INSTALL_DIR}/lingua-pi "\$@"
WRAPPER
    sudo chmod +x "$BIN_LINK"
    success "Binary installed: ${INSTALL_DIR}/lingua-pi"
}

# ── Step 2: Systemd service ──────────────────────────────────────────────────
install_service() {
    local svc_user="$1"
    local svc_home
    svc_home="$(eval echo "~${svc_user}")"

    # Build the After= / Wants= lines based on chosen backend
    local after_dep="network.target"
    local wants_dep=""
    if [[ "$LLM_BACKEND" == "ollama" ]]; then
        after_dep="network.target ollama.service"
        wants_dep="Wants=ollama.service"
    elif [[ "$LLM_BACKEND" == "llamafile" ]]; then
        after_dep="network.target llamafile.service"
        wants_dep="Wants=llamafile.service"
    fi

    info "Creating service (user: ${svc_user})..."
    sudo tee "$SERVICE_FILE" > /dev/null <<SERVICE
[Unit]
Description=LinguaPi Language Learning Server
After=${after_dep}
${wants_dep}

[Service]
ExecStart=${INSTALL_DIR}/lingua-pi
WorkingDirectory=${INSTALL_DIR}
Restart=on-failure
RestartSec=5
User=${svc_user}
Environment=HOME=${svc_home}

[Install]
WantedBy=multi-user.target
SERVICE

    sudo systemctl daemon-reload
    sudo systemctl enable "$SERVICE_NAME"
    success "Service enabled: ${SERVICE_NAME}"
}

# ── Step 3: Download corpus ──────────────────────────────────────────────────
download_corpus() {
    local version="$1"
    local corpus_script="${WORK}/download-corpus.sh"

    info "Fetching corpus download script (${version})..."

    local raw_base="https://raw.githubusercontent.com/${REPO}"
    curl -fsSL "${raw_base}/${version}/scripts/download-corpus.sh" -o "$corpus_script" 2>/dev/null \
        || curl -fsSL "${raw_base}/master/scripts/download-corpus.sh"  -o "$corpus_script" \
        || { warn "Could not fetch corpus script — skipping corpus download."; return; }

    chmod +x "$corpus_script"
    echo ""
    BOOKS_PER_LANG="$BOOKS_PER_LANG" bash "$corpus_script"
}

# ── Step 4: LLM backend setup ────────────────────────────────────────────────

# Write ~/.linguapi/config.json for the given service user (skips if file exists)
write_config() {
    local svc_home="$1" provider="$2" endpoint="$3" model="$4"
    local config_dir="${svc_home}/.linguapi"
    local config_path="${config_dir}/config.json"

    mkdir -p "$config_dir"
    if [[ -f "$config_path" ]]; then
        warn "Config already exists at ${config_path} — leaving it unchanged."
        warn "Edit it manually to set: provider=${provider}, endpoint=${endpoint}, model=${model}"
        return
    fi

    cat > "$config_path" <<CONF
{
  "server_port": 8080,
  "language": "Spanish",
  "llm_provider": "${provider}",
  "llm_endpoint": "${endpoint}",
  "llm_model": "${model}",
  "llm_api_key": ""
}
CONF
    success "Config written: ${config_path}"
}

# Install a systemd service that launches the llamafile server
install_llamafile_service() {
    local svc_user="$1" svc_home="$2" llamafile_path="$3"
    local llamafile_service="/etc/systemd/system/llamafile.service"

    info "Creating llamafile systemd service..."
    sudo tee "$llamafile_service" > /dev/null <<SERVICE
[Unit]
Description=Llamafile LLM Server (${LLAMAFILE_MODEL})
After=network.target

[Service]
ExecStart=${llamafile_path} --server --port ${LLAMAFILE_PORT} --host 127.0.0.1 -ngl 0
WorkingDirectory=${svc_home}
Restart=on-failure
RestartSec=5
User=${svc_user}
Environment=HOME=${svc_home}

[Install]
WantedBy=multi-user.target
SERVICE

    sudo systemctl daemon-reload
    sudo systemctl enable llamafile
    success "Llamafile service enabled (port ${LLAMAFILE_PORT})."
}

setup_llamafile_backend() {
    local svc_user="$1"
    local svc_home
    svc_home="$(eval echo "~${svc_user}")"
    local llamafile_path="${svc_home}/.linguapi/${LLAMAFILE_NAME}"

    mkdir -p "${svc_home}/.linguapi"

    if [[ -f "$llamafile_path" ]]; then
        success "llamafile already present: ${llamafile_path}"
    else
        info "Downloading ${LLAMAFILE_NAME} (~3 GB) from HuggingFace..."
        info "URL: ${LLAMAFILE_URL}"
        curl -fsSL --progress-bar "$LLAMAFILE_URL" -o "$llamafile_path" \
            || die "Failed to download llamafile. Check your connection or download manually to ${llamafile_path}"
        success "llamafile downloaded."
    fi

    chmod +x "$llamafile_path"
    success "llamafile executable: ${llamafile_path}"

    write_config "$svc_home" "llamafile" "http://localhost:${LLAMAFILE_PORT}" "$LLAMAFILE_MODEL"
    install_llamafile_service "$svc_user" "$svc_home" "$llamafile_path"
}

setup_ollama_backend() {
    local svc_user="$1"
    local svc_home
    svc_home="$(eval echo "~${svc_user}")"

    if ! command -v ollama &>/dev/null; then
        info "Installing Ollama..."
        curl -fsSL https://ollama.com/install.sh | sh
        success "Ollama installed."
    fi

    # Check if the default model is already pulled
    local model_present=0
    if ollama list 2>/dev/null | grep -q "${DEFAULT_MODEL}"; then
        model_present=1
    fi

    if [[ "$model_present" -eq 1 ]]; then
        success "Model already available: ${DEFAULT_MODEL}"
    else
        echo ""
        read -r -p "  Pull model '${DEFAULT_MODEL}'? (~2.5 GB) [Y/n] " mreply
        mreply="${mreply:-Y}"
        if [[ "$mreply" =~ ^[Yy] ]]; then
            info "Pulling ${DEFAULT_MODEL} (this will take a few minutes)..."
            ollama pull "$DEFAULT_MODEL"
            success "Model ready: ${DEFAULT_MODEL}"
        else
            warn "Skipping model pull. Run later: ollama pull ${DEFAULT_MODEL}"
        fi
    fi

    write_config "$svc_home" "ollama" "http://localhost:11434" "$DEFAULT_MODEL"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BOLD}============================================${NC}"
    echo -e "${BOLD}  LinguaPi — Raspberry Pi Installer${NC}"
    echo -e "${BOLD}============================================${NC}"

    check_deps

    local arch; arch=$(detect_arch)
    local version; version=$(resolve_version)
    local svc_user; svc_user=$(service_user)
    local local_ip; local_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")

    # Prompt for LLM backend choice before any steps so the service unit
    # can reference the correct dependency (llamafile.service or ollama.service)
    if [[ "$SKIP_OLLAMA" != "1" ]]; then
        prompt_llm_backend
    else
        LLM_BACKEND="skip"
    fi

    echo ""
    echo "  Version      : ${version}"
    echo "  Architecture : linux-${arch}"
    echo "  Install dir  : ${INSTALL_DIR}"
    echo "  Service user : ${svc_user}"
    echo "  Corpus books : ${BOOKS_PER_LANG} per language"
    echo "  LLM backend  : ${LLM_BACKEND}"
    echo ""

    # 1. Binary
    step "Step 1/4 — Installing binary"
    install_binary "$version" "$arch"

    # 2. Service
    step "Step 2/4 — Configuring systemd service"
    install_service "$svc_user"

    # 3. Corpus
    if [[ "$SKIP_CORPUS" != "1" ]]; then
        step "Step 3/4 — Downloading language corpus"
        info "Downloading ~${BOOKS_PER_LANG} texts per language from Gutenberg and Wikisource."
        info "Set SKIP_CORPUS=1 to skip, or BOOKS_PER_LANG=N to change the count."
        download_corpus "$version"
    else
        warn "Step 3/4 — Corpus download skipped (SKIP_CORPUS=1)"
        info "Run later: bash /opt/lingua-pi/scripts/download-corpus.sh"
    fi

    # 4. LLM backend
    step "Step 4/4 — LLM backend setup"
    if [[ "$LLM_BACKEND" == "llamafile" ]]; then
        setup_llamafile_backend "$svc_user"
    elif [[ "$LLM_BACKEND" == "ollama" ]]; then
        setup_ollama_backend "$svc_user"
    else
        warn "LLM setup skipped (SKIP_OLLAMA=1)"
        info "Configure manually via the Settings panel or ~/.linguapi/config.json"
    fi

    # Start llamafile service first if applicable
    if [[ "$LLM_BACKEND" == "llamafile" ]]; then
        echo ""
        info "Starting llamafile service..."
        sudo systemctl start llamafile || warn "llamafile service failed to start — check: sudo journalctl -u llamafile -f"
    fi

    # Start LinguaPi
    echo ""
    info "Starting LinguaPi service..."
    sudo systemctl start "$SERVICE_NAME"

    echo ""
    echo -e "${BOLD}${GREEN}============================================${NC}"
    echo -e "${BOLD}${GREEN}  LinguaPi is running!${NC}"
    echo -e "${BOLD}${GREEN}============================================${NC}"
    echo ""
    echo -e "  Open in browser : ${BOLD}http://${local_ip}:8080${NC}"
    echo ""
    echo "  Config   : ~/.linguapi/config.json"
    echo "  Logs     : sudo journalctl -u ${SERVICE_NAME} -f"
    echo "  Restart  : sudo systemctl restart ${SERVICE_NAME}"
    echo "  Stop     : sudo systemctl stop ${SERVICE_NAME}"
    echo "  Uninstall: sudo rm -rf ${INSTALL_DIR} ${BIN_LINK} ${SERVICE_FILE}"
    echo ""
    if [[ "$LLM_BACKEND" == "llamafile" ]]; then
        echo "  Llamafile logs   : sudo journalctl -u llamafile -f"
        echo "  Llamafile restart: sudo systemctl restart llamafile"
        echo ""
    fi
    echo -e "${DIM}  Provider and model can be changed any time from the Settings panel in the UI.${NC}"
    echo ""
}

main "$@"
