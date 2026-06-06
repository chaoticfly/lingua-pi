#!/usr/bin/env bash
# LinguaPi installer for macOS and Linux
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/chaoticfly/lingua-pi/master/scripts/install.sh | bash
#   or with a specific version:
#   VERSION=v1.0.0 bash install.sh

set -euo pipefail

REPO="chaoticfly/lingua-pi"
INSTALL_DIR="/opt/lingua-pi"
BIN_LINK="/usr/local/bin/lingua-pi"

LLAMAFILE_URL="https://huggingface.co/mozilla-ai/llamafile_0.10/resolve/main/gemma-4-E4B-it-Q5_K_M.llamafile"
LLAMAFILE_NAME="gemma-4-E4B-it-Q5_K_M.llamafile"
LLAMAFILE_MODEL="gemma-4-E4B-it-Q5_K_M"
LLAMAFILE_PORT="8081"
DEFAULT_OLLAMA_MODEL="gemma4:e4b"

# ── colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[lingua-pi]${NC} $*"; }
success() { echo -e "${GREEN}[lingua-pi]${NC} $*"; }
warn()    { echo -e "${YELLOW}[lingua-pi]${NC} $*"; }
die()     { echo -e "${RED}[lingua-pi] ERROR:${NC} $*" >&2; exit 1; }

# ── detect OS and arch ──────────────────────────────────────────────────────
detect_platform() {
    local os arch

    case "$(uname -s)" in
        Linux)  os="linux"  ;;
        Darwin) os="darwin" ;;
        *)      die "Unsupported OS: $(uname -s). Use the Windows installer (install.ps1) on Windows." ;;
    esac

    case "$(uname -m)" in
        x86_64 | amd64)    arch="amd64" ;;
        aarch64 | arm64)   arch="arm64" ;;
        armv7l)            die "ARMv7 is not supported. Use a 64-bit OS on your Raspberry Pi." ;;
        *)                 die "Unsupported architecture: $(uname -m)" ;;
    esac

    echo "${os}-${arch}"
}

# ── check dependencies ──────────────────────────────────────────────────────
check_deps() {
    for cmd in curl tar; do
        command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not installed."
    done
}

# ── resolve version ─────────────────────────────────────────────────────────
resolve_version() {
    if [[ -n "${VERSION:-}" ]]; then
        echo "$VERSION"
        return
    fi
    info "Fetching latest release version..."
    local version
    version=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
        | grep '"tag_name"' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
    [[ -n "$version" ]] || die "Could not determine latest release. Set VERSION= manually."
    echo "$version"
}

# ── write ~/.linguapi/config.json ────────────────────────────────────────────
write_config() {
    local provider="$1" endpoint="$2" model="$3"
    local config_dir="${HOME}/.linguapi"
    local config_path="${config_dir}/config.json"

    mkdir -p "$config_dir"
    if [[ -f "$config_path" ]]; then
        warn "Config already exists at ${config_path} — leaving unchanged."
        warn "Edit manually to set: provider=${provider}, endpoint=${endpoint}, model=${model}"
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

# ── LLM backend setup ────────────────────────────────────────────────────────
setup_llm() {
    local llamafile_path="${HOME}/.linguapi/${LLAMAFILE_NAME}"

    echo ""

    local use_llamafile=0
    if command -v ollama &>/dev/null; then
        success "Ollama already installed: $(ollama --version 2>/dev/null || echo 'installed')"
        echo ""
        echo "  LinguaPi can use either:"
        echo "    [L] llamafile  — 3-4× faster, single executable, no separate server to manage"
        echo "    [O] Ollama     — already installed, familiar 'ollama pull' workflow"
        printf "  Which backend? [L/o] "; read -r choice
        choice="${choice:-L}"
        [[ "$choice" =~ ^[Oo] ]] && use_llamafile=0 || use_llamafile=1
    else
        echo "  No LLM backend detected. Choose one to set up:"
        echo "    [L] llamafile  — fast single executable, runs ${LLAMAFILE_MODEL}"
        echo "    [O] Ollama     — install Ollama + pull ${DEFAULT_OLLAMA_MODEL} (~2.5 GB)"
        printf "  Which backend? [L/o] "; read -r choice
        choice="${choice:-L}"
        [[ "$choice" =~ ^[Oo] ]] && use_llamafile=0 || use_llamafile=1
    fi

    if [[ "$use_llamafile" -eq 1 ]]; then
        mkdir -p "${HOME}/.linguapi"
        if [[ -f "$llamafile_path" ]]; then
            success "llamafile already present: ${llamafile_path}"
        else
            info "Downloading ${LLAMAFILE_NAME} (~3 GB)..."
            curl -fsSL --progress-bar "$LLAMAFILE_URL" -o "$llamafile_path" \
                || die "Download failed. Check your connection or download manually to ${llamafile_path}"
            success "llamafile downloaded."
        fi
        chmod +x "$llamafile_path"
        write_config "llamafile" "http://localhost:${LLAMAFILE_PORT}" "$LLAMAFILE_MODEL"
        echo ""
        success "llamafile ready: ${llamafile_path}"
        echo ""
        echo "  Start the server with:"
        echo "    ${llamafile_path} --server --port ${LLAMAFILE_PORT}"
    else
        if ! command -v ollama &>/dev/null; then
            info "Installing Ollama..."
            curl -fsSL https://ollama.com/install.sh | sh
            success "Ollama installed."
        fi

        if ollama list 2>/dev/null | grep -q "${DEFAULT_OLLAMA_MODEL}"; then
            success "Model already available: ${DEFAULT_OLLAMA_MODEL}"
        else
            printf "  Pull model '%s'? (~2.5 GB) [Y/n] " "$DEFAULT_OLLAMA_MODEL"; read -r mreply
            mreply="${mreply:-Y}"
            if [[ "$mreply" =~ ^[Yy] ]]; then
                info "Pulling ${DEFAULT_OLLAMA_MODEL}..."
                ollama pull "$DEFAULT_OLLAMA_MODEL"
                success "Model ready: ${DEFAULT_OLLAMA_MODEL}"
            else
                warn "Skipping model pull. Run later: ollama pull ${DEFAULT_OLLAMA_MODEL}"
            fi
        fi
        write_config "ollama" "http://localhost:11434" "$DEFAULT_OLLAMA_MODEL"
    fi
}

# ── main ────────────────────────────────────────────────────────────────────
main() {
    check_deps

    local platform
    platform=$(detect_platform)

    local version
    version=$(resolve_version)

    local archive="lingua-pi-${platform}.tar.gz"
    local url="https://github.com/${REPO}/releases/download/${version}/${archive}"
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT

    info "Installing LinguaPi ${version} for ${platform}"
    info "Downloading ${archive}..."
    curl -fsSL --progress-bar "$url" -o "${tmpdir}/${archive}" \
        || die "Download failed. Check that ${version} exists at https://github.com/${REPO}/releases"

    info "Extracting..."
    tar -xzf "${tmpdir}/${archive}" -C "$tmpdir"

    # ── install ──────────────────────────────────────────────────────────────
    if [[ "$EUID" -ne 0 ]]; then
        warn "Not running as root — using sudo for system-wide install."
        SUDO="sudo"
    else
        SUDO=""
    fi

    info "Installing to ${INSTALL_DIR}..."
    $SUDO mkdir -p "$INSTALL_DIR"
    $SUDO cp "${tmpdir}/lingua-pi/lingua-pi" "${INSTALL_DIR}/lingua-pi"
    $SUDO chmod +x "${INSTALL_DIR}/lingua-pi"
    $SUDO cp -r "${tmpdir}/lingua-pi/static" "${INSTALL_DIR}/static"

    # ── wrapper script so the binary runs from its own directory ─────────────
    $SUDO tee "${BIN_LINK}" > /dev/null <<'EOF'
#!/usr/bin/env bash
cd /opt/lingua-pi
exec /opt/lingua-pi/lingua-pi "$@"
EOF
    $SUDO chmod +x "$BIN_LINK"

    success "LinguaPi ${version} installed."

    # ── LLM backend ──────────────────────────────────────────────────────────
    setup_llm

    echo
    echo "  Config: ~/.linguapi/config.json"
    echo "  Data:   ~/.linguapi/linguapi.db"
    echo "  Run:    lingua-pi"
    echo "  Open:   http://localhost:8080"
    echo
    warn "To uninstall: sudo rm -rf ${INSTALL_DIR} ${BIN_LINK}"
}

main "$@"
