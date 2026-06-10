#!/usr/bin/env bash
# scripts/dev-container.sh
#
# Launch devloop isolated development container via Apple Container.
#
# Usage:
#   ./scripts/dev-container.sh              # Interactive bash session
#   ./scripts/dev-container.sh -- go test ./...          # Run a command
#   ./scripts/dev-container.sh -- bash -c "devloop doctor"
#
# What this does:
#   1. Checks Apple Container system is running (starts it if not)
#   2. Builds devloop-dev image if missing
#   3. Runs container with ONLY these mounts from host:
#      - /workspace  ← this repo (read-write, your actual code changes)
#      - /root/.claude  ← claude credentials (read-only, no modifications)
#      - /root/.config/gh  ← gh CLI credentials (read-only)
#      - /root/.gitconfig  ← git identity (read-only)
#   4. Everything else is isolated (no host file access, no host processes)
#
# Security model:
#   The agent cannot read ~/.ssh, ~/.aws, ~/.zshrc, other projects, system
#   files, or anything not explicitly mounted. It can only commit/push via
#   GH_TOKEN passed as env var.

set -euo pipefail

IMAGE="devloop-dev:latest"
CONTAINER_NAME="devloop-dev"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}▶${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

# ── 1. Check Apple Container is installed ─────────────────────────────────────
if ! command -v container &>/dev/null; then
    fail "Apple Container not installed. Run: brew install container"
fi

# ── 2. Start container system if not running ──────────────────────────────────
SYSTEM_STATUS="$(container system status 2>/dev/null || echo "stopped")"
if ! echo "$SYSTEM_STATUS" | grep -q "running"; then
    log "Starting Apple Container system (first run downloads Linux kernel ~100MB)..."
    echo "Y" | container system start
    sleep 3
fi
ok "Container system running"

# ── 3. Build image if not present ─────────────────────────────────────────────
if ! container image list 2>/dev/null | grep -q "devloop-dev"; then
    log "Building devloop-dev image (first build: ~5 min, downloads Go + CLIs)..."
    container build \
        --tag "$IMAGE" \
        --file "$REPO_DIR/Dockerfile.dev" \
        "$REPO_DIR" \
    || fail "Image build failed. Check Dockerfile.dev."
    ok "Image built: $IMAGE"
else
    ok "Image ready: $IMAGE"
fi

# ── 4. Remove stale container if exists ───────────────────────────────────────
if container list 2>/dev/null | grep -q "$CONTAINER_NAME"; then
    log "Removing existing container: $CONTAINER_NAME"
    container stop "$CONTAINER_NAME" 2>/dev/null || true
    container delete "$CONTAINER_NAME" 2>/dev/null || true
fi

# ── 5. Resolve credential paths ───────────────────────────────────────────────
CLAUDE_DIR="$HOME/.claude"
GH_CONFIG_DIR="$HOME/.config/gh"
GIT_CONFIG="$HOME/.gitconfig"

MOUNTS=()
MOUNTS+=("--volume" "$REPO_DIR:/workspace")

if [[ -d "$CLAUDE_DIR" ]]; then
    MOUNTS+=("--volume" "$CLAUDE_DIR:/root/.claude:ro")
    ok "Mounted claude credentials (read-only)"
else
    warn "No ~/.claude found — Claude CLI will need auth inside container"
fi

if [[ -d "$GH_CONFIG_DIR" ]]; then
    MOUNTS+=("--volume" "$GH_CONFIG_DIR:/root/.config/gh:ro")
    ok "Mounted gh credentials (read-only)"
else
    warn "No ~/.config/gh found — run 'gh auth login' inside container"
fi

if [[ -f "$GIT_CONFIG" ]]; then
    MOUNTS+=("--volume" "$GIT_CONFIG:/root/.gitconfig:ro")
    ok "Mounted git config (read-only)"
fi

# ── 6. Resolve token ──────────────────────────────────────────────────────────
GITHUB_TOKEN_VAL="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [[ -z "$GITHUB_TOKEN_VAL" ]]; then
    warn "GH_TOKEN / GITHUB_TOKEN not set — git push will use mounted gh credentials"
fi

# ── 7. Determine command ──────────────────────────────────────────────────────
if [[ "${1:-}" == "--" ]]; then
    shift
    CONTAINER_CMD=("$@")
else
    CONTAINER_CMD=("/bin/bash" "--login")
fi

# ── 8. Launch container ───────────────────────────────────────────────────────
echo ""
log "Launching isolated dev container: $CONTAINER_NAME"
echo "   Workspace : $REPO_DIR → /workspace"
echo "   Image     : $IMAGE"
echo "   Command   : ${CONTAINER_CMD[*]}"
echo "   Host access: ONLY mounted paths above"
echo ""

container run \
    --name "$CONTAINER_NAME" \
    "${MOUNTS[@]}" \
    --env "GH_TOKEN=${GITHUB_TOKEN_VAL}" \
    --env "GITHUB_TOKEN=${GITHUB_TOKEN_VAL}" \
    --env "HOME=/root" \
    --env "TERM=xterm-256color" \
    "$IMAGE" \
    "${CONTAINER_CMD[@]}"
