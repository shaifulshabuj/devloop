#!/usr/bin/env bash
# DevLoop installer — downloads the correct pre-built binary from GitHub Releases.
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/shaifulshabuj/devloop/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/shaifulshabuj/devloop/main/install.sh | bash -s -- --version v6.0.1
#   curl -fsSL https://raw.githubusercontent.com/shaifulshabuj/devloop/main/install.sh | bash -s -- --install-dir ~/.local/bin
set -euo pipefail

REPO="shaifulshabuj/devloop"
BINARY="devloop"
INSTALL_DIR="${DEVLOOP_INSTALL_DIR:-/usr/local/bin}"
VERSION="${DEVLOOP_VERSION:-}"

# ── colour helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "  ${CYAN}▸${RESET} $*"; }
success() { echo -e "  ${GREEN}✓${RESET} $*"; }
error()   { echo -e "  ${RED}✗ ERROR:${RESET} $*" >&2; exit 1; }

# ── parse flags ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)   VERSION="$2"; shift 2 ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

# ── detect OS / arch ─────────────────────────────────────────────────────────
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) error "Unsupported architecture: $ARCH" ;;
esac
case "$OS" in
  linux|darwin) ;;
  mingw*|msys*|cygwin*) OS="windows" ;;
  *) error "Unsupported OS: $OS" ;;
esac

# ── resolve version ───────────────────────────────────────────────────────────
if [[ -z "$VERSION" ]]; then
  if command -v curl &>/dev/null; then
    VERSION="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
  elif command -v wget &>/dev/null; then
    VERSION="$(wget -qO- "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
  else
    error "curl or wget is required"
  fi
fi
[[ -z "$VERSION" ]] && error "Could not determine latest release version"

echo ""
echo -e "${BOLD}DevLoop Installer${RESET}"
echo -e "  Version:  ${GREEN}${VERSION}${RESET}"
echo -e "  Platform: ${OS}/${ARCH}"
echo -e "  Target:   ${INSTALL_DIR}/${BINARY}"
echo ""

# ── build download URLs ───────────────────────────────────────────────────────
EXT="tar.gz"
[[ "$OS" == "windows" ]] && EXT="zip"
ARCHIVE="devloop_${VERSION}_${OS}_${ARCH}.${EXT}"
BASE_URL="https://github.com/${REPO}/releases/download/${VERSION}"
ARCHIVE_URL="${BASE_URL}/${ARCHIVE}"
CHECKSUM_URL="${BASE_URL}/devloop_${VERSION}_checksums.txt"

# ── download ──────────────────────────────────────────────────────────────────
TMP_DIR="$(mktemp -d /tmp/devloop-install.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

_download() {
  local url="$1" dest="$2"
  if command -v curl &>/dev/null; then
    curl -fsSL "$url" -o "$dest"
  else
    wget -qO "$dest" "$url"
  fi
}

info "Downloading ${ARCHIVE}..."
_download "$ARCHIVE_URL" "$TMP_DIR/$ARCHIVE" || error "Download failed: $ARCHIVE_URL"

info "Downloading checksums..."
_download "$CHECKSUM_URL" "$TMP_DIR/checksums.txt" || error "Download failed: $CHECKSUM_URL"

# ── verify checksum ───────────────────────────────────────────────────────────
info "Verifying checksum..."
pushd "$TMP_DIR" > /dev/null
# macOS ships a BSD sha256sum that lacks --check; prefer shasum (Perl) on Darwin
if [[ "$(uname -s)" == "Darwin" ]] && command -v shasum &>/dev/null; then
  grep "$ARCHIVE" checksums.txt | shasum -a 256 --check --status \
    || error "Checksum verification failed — download may be corrupt or tampered"
elif command -v sha256sum &>/dev/null; then
  grep "$ARCHIVE" checksums.txt | sha256sum --check --status \
    || error "Checksum verification failed — download may be corrupt or tampered"
elif command -v shasum &>/dev/null; then
  grep "$ARCHIVE" checksums.txt | shasum -a 256 --check --status \
    || error "Checksum verification failed — download may be corrupt or tampered"
else
  echo "  ⚠ sha256sum/shasum not found — skipping checksum verification"
fi
popd > /dev/null
success "Checksum OK"

# ── extract ───────────────────────────────────────────────────────────────────
info "Extracting..."
if [[ "$EXT" == "tar.gz" ]]; then
  tar -xzf "$TMP_DIR/$ARCHIVE" -C "$TMP_DIR" "$BINARY" 2>/dev/null \
    || tar -xzf "$TMP_DIR/$ARCHIVE" -C "$TMP_DIR"
else
  unzip -q "$TMP_DIR/$ARCHIVE" "$BINARY" -d "$TMP_DIR" 2>/dev/null \
    || unzip -q "$TMP_DIR/$ARCHIVE" -d "$TMP_DIR"
fi
EXTRACTED="$(find "$TMP_DIR" -name "$BINARY" -not -name "*.tar.gz" | head -1)"
[[ -z "$EXTRACTED" ]] && error "Could not find '$BINARY' binary after extraction"
chmod +x "$EXTRACTED"

# ── install ───────────────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"
DEST="$INSTALL_DIR/$BINARY"
if [[ -w "$INSTALL_DIR" ]]; then
  mv "$EXTRACTED" "$DEST"
else
  info "Requesting sudo to install to ${INSTALL_DIR}..."
  sudo mv "$EXTRACTED" "$DEST"
fi

echo ""
success "Installed ${BOLD}devloop ${VERSION}${RESET} → ${CYAN}${DEST}${RESET}"
echo ""
echo -e "  Run ${CYAN}devloop version${RESET} to confirm."
echo -e "  Run ${CYAN}devloop --help${RESET} to get started."
echo ""

# ── PATH hint ─────────────────────────────────────────────────────────────────
if ! command -v devloop &>/dev/null 2>&1; then
  echo -e "  ${RED}⚠${RESET}  ${CYAN}${INSTALL_DIR}${RESET} is not in your PATH."
  echo -e "     Add this to your shell profile:"
  echo -e "     ${BOLD}export PATH=\"${INSTALL_DIR}:\$PATH\"${RESET}"
  echo ""
fi
