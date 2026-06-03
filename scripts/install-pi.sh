#!/usr/bin/env bash
# LinguaPi Raspberry Pi Installer
#
# Does everything in one shot:
#   1. Downloads the latest linux-arm64 release binary
#   2. Installs to /opt/lingua-pi/
#   3. Creates and enables a systemd service
#   4. Downloads a starter corpus (Gutenberg + Wikisource)
#   5. Optionally installs Ollama and pulls a model
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/chaoticfly/lingua-pi/master/scripts/install-pi.sh | bash
#
#   With options:
#   VERSION=v1.0.0 BOOKS_PER_LANG=25 bash install-pi.sh
#   SKIP_CORPUS=1  bash install-pi.sh   # skip corpus download
#   SKIP_OLLAMA=1  bash install-pi.sh   # skip Ollama prompt
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
DEFAULT_MODEL="gemma3:4b"

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
    # SUDO_USER is set when the script is invoked with sudo
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        echo "$SUDO_USER"
    elif id pi &>/dev/null; then
        echo "pi"
    else
        echo "$(logname 2>/dev/null || echo root)"
    fi
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

    # Wrapper at /usr/local/bin so users can type `lingua-pi` from anywhere
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

    info "Creating service (user: ${svc_user})..."
    sudo tee "$SERVICE_FILE" > /dev/null <<SERVICE
[Unit]
Description=LinguaPi Language Learning Server
After=network.target ollama.service
Wants=ollama.service

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

    # Try the exact release tag first, fall back to master
    local raw_base="https://raw.githubusercontent.com/${REPO}"
    curl -fsSL "${raw_base}/${version}/scripts/download-corpus.sh" -o "$corpus_script" 2>/dev/null \
        || curl -fsSL "${raw_base}/master/scripts/download-corpus.sh"  -o "$corpus_script" \
        || { warn "Could not fetch corpus script — skipping corpus download."; return; }

    chmod +x "$corpus_script"
    echo ""
    BOOKS_PER_LANG="$BOOKS_PER_LANG" bash "$corpus_script"
}

# ── Step 4: Optional Ollama install ─────────────────────────────────────────
maybe_install_ollama() {
    if command -v ollama &>/dev/null; then
        success "Ollama already installed: $(ollama --version 2>/dev/null || echo 'unknown version')"
        return
    fi

    echo ""
    read -r -p "  Install Ollama now? (recommended) [Y/n] " reply
    reply="${reply:-Y}"
    if [[ "$reply" =~ ^[Yy] ]]; then
        info "Installing Ollama..."
        curl -fsSL https://ollama.com/install.sh | sh
        success "Ollama installed."

        echo ""
        read -r -p "  Pull default model '${DEFAULT_MODEL}'? (~2.5 GB) [Y/n] " mreply
        mreply="${mreply:-Y}"
        if [[ "$mreply" =~ ^[Yy] ]]; then
            info "Pulling ${DEFAULT_MODEL} (this will take a few minutes)..."
            ollama pull "$DEFAULT_MODEL"
            success "Model ready: ${DEFAULT_MODEL}"
        fi
    else
        warn "Skipping Ollama install. Pull a model later with: ollama pull ${DEFAULT_MODEL}"
    fi
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

    echo ""
    echo "  Version      : ${version}"
    echo "  Architecture : linux-${arch}"
    echo "  Install dir  : ${INSTALL_DIR}"
    echo "  Service user : ${svc_user}"
    echo "  Corpus books : ${BOOKS_PER_LANG} per language"
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

    # 4. Ollama
    if [[ "$SKIP_OLLAMA" != "1" ]]; then
        step "Step 4/4 — Ollama LLM backend"
        maybe_install_ollama
    else
        warn "Step 4/4 — Ollama setup skipped (SKIP_OLLAMA=1)"
    fi

    # Start service
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
    echo -e "${DIM}  Model can be changed any time from the Settings panel in the UI.${NC}"
    echo ""
}

main "$@"
