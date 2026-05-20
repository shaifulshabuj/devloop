#!/usr/bin/env bash
# scripts/pre-release-check.sh — DevLoop pre-release validation
#
# Checks both v5 (devloop.sh) and v6 (Go binary) before any release.
# Outputs PASS / WARN / FAIL lines, then a final RESULT line.
#
# Usage:
#   ./scripts/pre-release-check.sh          # auto-detects v5 + v6
#   ./scripts/pre-release-check.sh v5       # v5 (devloop.sh) only
#   ./scripts/pre-release-check.sh v6       # v6 (Go binary) only
#   ./scripts/pre-release-check.sh both     # explicit both

set -euo pipefail

TARGET="${1:-both}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
PASS() { echo -e "PASS  ${GREEN}$*${RESET}"; }
FAIL() { echo -e "FAIL  ${RED}$*${RESET}"; FAILURES=$((FAILURES+1)); }
WARN() { echo -e "WARN  ${YELLOW}$*${RESET}"; }
INFO() { echo -e "      ${CYAN}$*${RESET}"; }

FAILURES=0
LAST_TAG="$(git tag --sort=-version:refname | head -1)"

echo ""
echo -e "${BOLD}DevLoop Pre-Release Check${RESET}  (last tag: ${CYAN}${LAST_TAG}${RESET})"
echo "────────────────────────────────────────────────────────"

# ── COMMON CHECKS ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[COMMON]${RESET}"

# Git clean
if [[ -z "$(git status --porcelain)" ]]; then
  PASS "git working tree is clean"
else
  FAIL "git working tree is dirty — commit or stash changes first"
  git status --short
fi

# On main
BRANCH="$(git branch --show-current)"
if [[ "$BRANCH" == "main" ]]; then
  PASS "on main branch"
else
  WARN "not on main branch (current: $BRANCH) — release should be from main"
fi

# No unpushed commits
if git status -sb | grep -q '^##.*ahead'; then
  FAIL "unpushed commits — run 'git push origin main'"
else
  PASS "no unpushed commits"
fi

# Secret scan — commits since last tag
echo ""
INFO "Scanning for secrets in commits since ${LAST_TAG}..."
SECRET_HITS="$(git log --no-pager -p "${LAST_TAG}..HEAD" -- \
    ':!scripts/pre-release-check.sh' 2>/dev/null \
  | grep -iE '(password|secret|api_key|token|private_key)\s*=' \
  | grep -v '^\-\-\-\|^+++\|^@@' | head -5 || true)"
if [[ -n "$SECRET_HITS" ]]; then
  FAIL "potential secrets found in commits since ${LAST_TAG}:"
  echo "$SECRET_HITS" | head -5
else
  PASS "no secrets detected in commits since ${LAST_TAG}"
fi

# CHANGELOG has at least one version entry
LATEST_CL_VERSION="$(grep -m1 '^## \[' CHANGELOG.md 2>/dev/null | sed 's/## \[\([0-9.]*\)\].*/\1/' || true)"
if [[ -n "$LATEST_CL_VERSION" ]]; then
  PASS "CHANGELOG.md has entries (latest: ${LATEST_CL_VERSION})"
else
  WARN "CHANGELOG.md missing or no version entries found"
fi

# ── V5 CHECKS ─────────────────────────────────────────────────────────────────
if [[ "$TARGET" == "v5" || "$TARGET" == "both" ]]; then
  echo ""
  echo -e "${BOLD}[V5 — devloop.sh]${RESET}"

  if [[ ! -f devloop.sh ]]; then
    FAIL "devloop.sh not found"
  else
    # bash -n with system bash (critical: must pass bash 3.2)
    if /usr/bin/env bash -n devloop.sh 2>&1; then
      PASS "bash -n devloop.sh passed (bash: $(/usr/bin/env bash --version | head -1))"
    else
      FAIL "bash -n devloop.sh failed — syntax error in devloop.sh"
    fi

    # VERSION consistency: devloop.sh ↔ VERSION file
    V5_SH="$(grep '^VERSION=' devloop.sh | head -1 | tr -d '"' | cut -d= -f2)"
    V5_FILE="$(cat VERSION 2>/dev/null || echo 'MISSING')"
    if [[ "$V5_SH" == "$V5_FILE" ]]; then
      PASS "VERSION consistent: devloop.sh=$V5_SH, VERSION file=$V5_FILE"
    else
      FAIL "VERSION mismatch: devloop.sh='$V5_SH' vs VERSION file='$V5_FILE'"
    fi

    # File size sanity
    V5_SIZE="$(wc -c < devloop.sh)"
    if [[ "$V5_SIZE" -ge 50000 ]]; then
      PASS "devloop.sh size OK (${V5_SIZE} bytes)"
    else
      FAIL "devloop.sh too small (${V5_SIZE} bytes) — may be truncated"
    fi

    # Check VERSION is not already tagged
    if git tag | grep -qx "v${V5_SH}"; then
      WARN "tag v${V5_SH} already exists — you may need to bump the version"
    else
      PASS "v${V5_SH} is a fresh version (not yet tagged)"
    fi
  fi
fi

# ── V6 CHECKS ─────────────────────────────────────────────────────────────────
if [[ "$TARGET" == "v6" || "$TARGET" == "both" ]]; then
  echo ""
  echo -e "${BOLD}[V6 — Go binary]${RESET}"

  if [[ ! -f go.mod ]]; then
    FAIL "go.mod not found — not in a Go module root"
  else
    # Module path
    MOD_PATH="$(head -1 go.mod | awk '{print $2}')"
    if [[ "$MOD_PATH" == "github.com/shaifulshabuj/devloop/v6" ]]; then
      PASS "module path correct: $MOD_PATH"
    else
      FAIL "unexpected module path: $MOD_PATH (expected github.com/shaifulshabuj/devloop/v6)"
    fi

    # Version consistency: main.go ↔ Makefile
    V6_MAIN="$(grep 'var version' cmd/devloop/main.go 2>/dev/null | sed 's/.*"\(.*\)".*/\1/' || echo 'MISSING')"
    V6_MAKE="$(grep '^VERSION :=' Makefile 2>/dev/null | awk '{print $3}' || echo 'MISSING')"
    if [[ "$V6_MAIN" == "$V6_MAKE" ]]; then
      PASS "version consistent: main.go=$V6_MAIN, Makefile=$V6_MAKE"
    else
      WARN "version mismatch: main.go='$V6_MAIN' vs Makefile='$V6_MAKE' (GoReleaser injects from tag, OK if using tags)"
    fi

    # Check version not already tagged
    if git tag | grep -qx "${V6_MAIN}"; then
      WARN "tag ${V6_MAIN} already exists — bump version before release"
    else
      PASS "${V6_MAIN} is a fresh version (not yet tagged)"
    fi

    # CGO_ENABLED=0 (pure Go)
    if grep -q 'CGO_ENABLED=0' .goreleaser.yml 2>/dev/null; then
      PASS "goreleaser uses CGO_ENABLED=0 (pure-Go SQLite)"
    else
      WARN ".goreleaser.yml missing CGO_ENABLED=0 — cross-compile may fail"
    fi

    # Build check
    INFO "Building (CGO_ENABLED=0 go build ./...)..."
    if CGO_ENABLED=0 go build ./... 2>&1; then
      PASS "go build ./... succeeded"
    else
      FAIL "go build ./... failed — fix build errors before releasing"
    fi

    # Test suite
    INFO "Running tests (CGO_ENABLED=0 go test ./... -race -count=1)..."
    if CGO_ENABLED=0 go test ./... -race -count=1 2>&1 | tee /tmp/devloop-test-out.txt | tail -12; then
      PASS "go test -race ./... all green"
    else
      FAIL "go test ./... had failures — fix before releasing"
      cat /tmp/devloop-test-out.txt | grep FAIL
    fi
  fi
fi

# ── RESULT ────────────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────"
if [[ $FAILURES -eq 0 ]]; then
  echo -e "RESULT  ${GREEN}${BOLD}ALL CHECKS PASSED${RESET} — ready to release"
  exit 0
else
  echo -e "RESULT  ${RED}${BOLD}${FAILURES} CHECK(S) FAILED${RESET} — fix above before releasing"
  exit 1
fi
