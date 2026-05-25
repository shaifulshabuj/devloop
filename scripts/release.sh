#!/usr/bin/env bash
#
# release.sh — cut a DevLoop release on GitHub.
#
# What it does:
#   1. Validates the working tree is clean, on main, and up-to-date
#   2. Validates VERSION, devloop.sh VERSION, and CHANGELOG.md agree
#   3. Extracts the [<version>] section from CHANGELOG.md as release notes
#   4. Builds the Go TUI (sanity check; non-fatal warning if Go is missing)
#   5. Creates an annotated git tag
#   6. Pushes the tag
#   7. Creates a GitHub release with the extracted notes
#
# Modes:
#   release       Final release. Tag like v5.3.0, marked as Latest.
#   prerelease    Pre-release. Tag like v5.3.0-rc.1, marked as pre-release on GH.
#
# Usage:
#   scripts/release.sh release    [--dry-run] [--yes]
#   scripts/release.sh prerelease [--dry-run] [--yes]
#
# The version is always read from the VERSION file. To cut a release for a
# different version, edit VERSION + devloop.sh first.
#
# Examples:
#   scripts/release.sh release --dry-run        # show what would happen
#   scripts/release.sh release                  # interactive confirmation
#   scripts/release.sh release --yes            # CI-friendly, no prompts
#   scripts/release.sh prerelease               # cuts v<VERSION>-rc.<N>
#
set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

info()    { printf '%b\n' "${CYAN}ℹ${RESET}  $*"; }
ok()      { printf '%b\n' "${GREEN}✔${RESET}  $*"; }
warn()    { printf '%b\n' "${YELLOW}⚠${RESET}  $*"; }
err()     { printf '%b\n' "${RED}✖${RESET}  $*" >&2; }
section() { printf '\n%b\n' "${BOLD}$*${RESET}"; }

# ── Arg parsing ───────────────────────────────────────────────────────────────
MODE=""
DRY_RUN=false
YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    release|prerelease) MODE="$1"; shift ;;
    --dry-run)          DRY_RUN=true; shift ;;
    --yes|-y)           YES=true; shift ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) err "unknown argument: $1"; exit 2 ;;
  esac
done

if [[ -z "$MODE" ]]; then
  err "must specify a mode: 'release' or 'prerelease'"
  echo "       run 'scripts/release.sh --help' for usage"
  exit 2
fi

# ── Locate repo root ──────────────────────────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
  err "not inside a git repository"
  exit 1
fi
cd "$REPO_ROOT"

# ── Validate clean tree on main, up-to-date with remote ───────────────────────
section "Preflight"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" ]]; then
  err "must be on main; currently on '$BRANCH'"
  exit 1
fi
ok "on branch main"

# Refuse if any TRACKED file is modified or staged. Untracked files
# (?? lines) are fine — they aren't in the tag anyway.
DIRTY="$(git status --porcelain | grep -v '^??' || true)"
if [[ -n "$DIRTY" ]]; then
  err "tracked files are modified or staged — commit or stash first:"
  printf '%s\n' "$DIRTY" | sed 's/^/    /'
  exit 1
fi
ok "no modified tracked files"

UNTRACKED_COUNT="$(git status --porcelain | grep -c '^??' || true)"
if [[ "$UNTRACKED_COUNT" -gt 0 ]]; then
  warn "$UNTRACKED_COUNT untracked file(s) present — they won't be in the release"
fi

# Fetch + check we're up to date with origin/main.
git fetch --tags --quiet origin
LOCAL="$(git rev-parse HEAD)"
REMOTE="$(git rev-parse origin/main 2>/dev/null || echo "")"
if [[ -n "$REMOTE" && "$LOCAL" != "$REMOTE" ]]; then
  err "local main is not in sync with origin/main"
  echo "    local : $LOCAL"
  echo "    remote: $REMOTE"
  echo "    push or pull first, then re-run"
  exit 1
fi
ok "in sync with origin/main"

# ── Read version + validate consistency ───────────────────────────────────────
section "Version validation"

if [[ ! -f VERSION ]]; then
  err "VERSION file is missing"; exit 1
fi
VERSION="$(tr -d '[:space:]' < VERSION)"
if [[ -z "$VERSION" ]]; then
  err "VERSION file is empty"; exit 1
fi
ok "VERSION file: $VERSION"

# Compare against devloop.sh's embedded VERSION constant.
SH_VERSION="$(grep -E '^VERSION=' devloop.sh | head -1 | sed -E 's/^VERSION="([^"]+)"$/\1/')"
if [[ "$VERSION" != "$SH_VERSION" ]]; then
  err "VERSION mismatch:"
  echo "    VERSION file : $VERSION"
  echo "    devloop.sh   : $SH_VERSION"
  echo "    sync both files before releasing"
  exit 1
fi
ok "devloop.sh VERSION agrees: $SH_VERSION"

# Find a CHANGELOG section for this version.
if ! grep -q "^## \[${VERSION}\]" CHANGELOG.md; then
  err "no '## [${VERSION}]' section found in CHANGELOG.md"
  echo "    add release notes under '## [${VERSION}] — YYYY-MM-DD' first"
  exit 1
fi
ok "CHANGELOG.md has a [${VERSION}] section"

# ── Resolve final tag name (handles prerelease rc bumping) ────────────────────
section "Tag selection"

if [[ "$MODE" == "release" ]]; then
  TAG="v${VERSION}"
  GH_PRE_FLAG=""
  KIND="release"
else
  # Find the highest existing -rc.N tag for this version and bump.
  HIGHEST_RC="$(git tag --list "v${VERSION}-rc.*" \
    | sed -E "s/^v${VERSION}-rc\.([0-9]+)$/\1/" \
    | sort -n | tail -1)"
  if [[ -z "$HIGHEST_RC" ]]; then
    NEXT_RC=1
  else
    NEXT_RC=$((HIGHEST_RC + 1))
  fi
  TAG="v${VERSION}-rc.${NEXT_RC}"
  GH_PRE_FLAG="--prerelease"
  KIND="pre-release (rc.${NEXT_RC})"
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
  err "tag '$TAG' already exists locally"
  echo "    delete it (git tag -d $TAG; git push --delete origin $TAG) or"
  echo "    bump VERSION before re-running"
  exit 1
fi
ok "tag to create: $TAG"
ok "kind: $KIND"

# ── Cross-build the Go TUI release binaries ───────────────────────────────────
# Produces one binary per OS/arch into $TUI_DIR. These get uploaded as release
# assets after the GitHub release is created; `devloop update` downloads the
# binary matching the user's platform. Empty $TUI_DIR ⇒ nothing to upload.
section "Build TUI binaries"

TUI_TARGETS=( "darwin/arm64" "darwin/amd64" "linux/amd64" "linux/arm64" )
TUI_DIR=""

if command -v go >/dev/null 2>&1; then
  TUI_DIR="$(mktemp -d /tmp/devloop-tui-rel.XXXXXX)"
  for t in "${TUI_TARGETS[@]}"; do
    os="${t%/*}"; arch="${t#*/}"
    out="$TUI_DIR/devloop-tui-${os}-${arch}"
    if (cd cmd/devloop-tui && \
        GOOS="$os" GOARCH="$arch" CGO_ENABLED=0 \
        go build -trimpath -ldflags "-s -w -X main.Version=${VERSION}" -o "$out" . 2>&1); then
      ok "built devloop-tui-${os}-${arch} ($(du -h "$out" | cut -f1 | tr -d ' '))"
    else
      err "cross-build failed for ${os}/${arch} — fix before releasing"
      rm -rf "$TUI_DIR"
      exit 1
    fi
  done
  # Checksums for verification / supply-chain hygiene.
  ( cd "$TUI_DIR" && shasum -a 256 devloop-tui-* > SHA256SUMS )
  ok "wrote SHA256SUMS for $(ls "$TUI_DIR" | grep -c '^devloop-tui-') binaries"
else
  warn "go not installed; TUI binaries will NOT be attached to this release"
  warn "users on this version must build with: make tui-install"
fi

# Sanity: bash syntax check on devloop.sh.
if bash -n devloop.sh 2>&1; then
  ok "bash -n devloop.sh passes"
else
  err "bash syntax error in devloop.sh"
  exit 1
fi

# ── Extract release notes from CHANGELOG ──────────────────────────────────────
section "Release notes"

# Extract the section starting at `## [VERSION]` up to the NEXT `## [` heading.
NOTES_FILE="$(mktemp /tmp/devloop-notes.XXXXXX)"
awk -v ver="$VERSION" '
  $0 ~ "^## \\[" ver "\\]" { capture=1; next }
  capture && /^## \[/      { capture=0 }
  capture                  { print }
' CHANGELOG.md > "$NOTES_FILE"

NOTES_LINES="$(wc -l < "$NOTES_FILE" | tr -d ' ')"
if [[ "$NOTES_LINES" -lt 3 ]]; then
  err "CHANGELOG section for [${VERSION}] is suspiciously short ($NOTES_LINES lines)"
  exit 1
fi
ok "extracted ${NOTES_LINES} lines of release notes from CHANGELOG"

if [[ "$MODE" == "prerelease" ]]; then
  # Prepend a pre-release marker to the notes.
  TMP="$(mktemp /tmp/devloop-notes.XXXXXX)"
  {
    echo "> **Pre-release** \`${TAG}\` cut from \`$(git rev-parse --short HEAD)\`."
    echo "> Not yet promoted to Latest. See \`## [${VERSION}]\` in CHANGELOG.md for the full release notes."
    echo ""
    cat "$NOTES_FILE"
  } > "$TMP"
  mv "$TMP" "$NOTES_FILE"
fi

# ── Preview + confirm ─────────────────────────────────────────────────────────
section "Preview"

cat <<EOF
  Repo       : $(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo '(gh unavailable)')
  Mode       : $KIND
  Tag        : $TAG
  Commit     : $(git rev-parse --short HEAD) — $(git log -1 --pretty=%s)
  Notes head : $(head -1 "$NOTES_FILE" | cut -c1-72)…
  Notes      : ${NOTES_LINES} lines (in $NOTES_FILE)
EOF

if [[ "$DRY_RUN" == "true" ]]; then
  warn "dry-run requested — stopping before any side effects"
  info "release notes saved at: $NOTES_FILE"
  [[ -n "$TUI_DIR" ]] && info "TUI binaries built (not uploaded) in: $TUI_DIR"
  exit 0
fi

if [[ "$YES" != "true" ]]; then
  printf "%b" "${YELLOW}? Proceed with tagging + pushing + GH release? [y/N]: ${RESET}"
  read -r reply
  case "${reply,,}" in
    y|yes) : ;;
    *) err "aborted"; rm -f "$NOTES_FILE"; exit 1 ;;
  esac
fi

# ── Tag + push + create release ───────────────────────────────────────────────
section "Cutting release"

git tag -a "$TAG" -m "DevLoop ${TAG}"
ok "annotated tag created: $TAG"

git push origin "$TAG"
ok "tag pushed to origin"

if ! command -v gh >/dev/null 2>&1; then
  warn "gh CLI not installed; tag is pushed but no GitHub release was created"
  info "create the release manually: https://github.com/$(git config --get remote.origin.url | sed -E 's|.*github.com[:/]([^/]+/[^.]+).*|\1|')/releases/new?tag=$TAG"
  rm -f "$NOTES_FILE"
  exit 0
fi

GH_TITLE="DevLoop ${TAG}"
if [[ "$MODE" == "release" ]]; then
  # Mark as Latest by NOT passing --prerelease.
  gh release create "$TAG" \
    --title "$GH_TITLE" \
    --notes-file "$NOTES_FILE"
  ok "GitHub release created (marked Latest): $GH_TITLE"
else
  gh release create "$TAG" \
    --title "$GH_TITLE" \
    --notes-file "$NOTES_FILE" \
    --prerelease
  ok "GitHub pre-release created: $GH_TITLE"
fi

rm -f "$NOTES_FILE"

# ── Attach the CLI script itself ──────────────────────────────────────────────
# `devloop update`'s preferred path is `gh release download --pattern devloop.sh`
# (works for private repos); raw-main is only the fallback. Attach it so the
# preferred path succeeds.
section "Uploading CLI script"
if gh release upload "$TAG" devloop.sh --clobber; then
  ok "attached devloop.sh to $TAG"
else
  warn "failed to upload devloop.sh — `devloop update` will use the raw-main fallback"
fi

# ── Attach TUI binaries as release assets ─────────────────────────────────────
# `devloop update` downloads the binary matching the user's OS/arch from here.
if [[ -n "$TUI_DIR" ]]; then
  section "Uploading TUI binaries"
  if gh release upload "$TAG" "$TUI_DIR"/devloop-tui-* "$TUI_DIR/SHA256SUMS" --clobber; then
    ok "attached $(ls "$TUI_DIR" | grep -c '^devloop-tui-') TUI binaries + SHA256SUMS to $TAG"
  else
    err "failed to upload TUI binaries — release exists but has no TUI assets"
    warn "retry manually: gh release upload $TAG $TUI_DIR/devloop-tui-* $TUI_DIR/SHA256SUMS --clobber"
  fi
  rm -rf "$TUI_DIR"
else
  warn "no TUI binaries to upload (go was not installed at build time)"
fi

section "Done"
ok "$TAG is live"
info "verify: gh release view $TAG"
info "users will pick it up via: devloop update"
