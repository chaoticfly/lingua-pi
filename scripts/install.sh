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

    success "Installed! Run with: lingua-pi"
    echo
    echo "  Config: ~/.linguapi/config.json (created on first run)"
    echo "  Data:   ~/.linguapi/linguapi.db"
    echo
    echo "  To start Ollama:   ollama serve"
    echo "  To pull a model:   ollama pull gemma3:4b"
    echo "  Then open:         http://localhost:8080"
    echo
    warn "To uninstall: sudo rm -rf ${INSTALL_DIR} ${BIN_LINK}"
}

main "$@"
