#!/usr/bin/env bash
# scripts/release.sh — DevLoop unified release script
#
# Supports both v5 (devloop.sh bash script) and v6 (Go binary via GoReleaser).
#
# Usage:
#   ./scripts/release.sh v5 patch      # 5.1.8 → 5.1.9
#   ./scripts/release.sh v5 minor      # 5.1.8 → 5.2.0
#   ./scripts/release.sh v5 major      # 5.1.8 → 6.0.0
#   ./scripts/release.sh v5 5.2.0      # explicit version
#
#   ./scripts/release.sh v6 patch      # 6.0.2 → 6.0.3
#   ./scripts/release.sh v6 minor      # 6.0.2 → 6.1.0
#   ./scripts/release.sh v6 major      # 6.0.2 → 7.0.0
#   ./scripts/release.sh v6 6.1.0      # explicit version (no v prefix needed)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "  ${CYAN}▸${RESET} $*"; }
success() { echo -e "  ${GREEN}✓${RESET} $*"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET} $*"; }
error()   { echo -e "  ${RED}✗ ERROR:${RESET} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}$*${RESET}"; }

# ── arg validation ────────────────────────────────────────────────────────────
CHANNEL="${1:-}"
BUMP="${2:-}"

[[ -z "$CHANNEL" || -z "$BUMP" ]] && {
  echo "Usage: $0 <v5|v6> <patch|minor|major|X.Y.Z>"
  exit 1
}
[[ "$CHANNEL" != "v5" && "$CHANNEL" != "v6" ]] && error "Channel must be v5 or v6, got: $CHANNEL"

# ── version bump helper ───────────────────────────────────────────────────────
# Increments one of patch/minor/major in a semver string (no leading 'v')
_bump_semver() {
  local version="$1" bump="$2"
  local major minor patch
  # strip leading v if present
  version="${version#v}"
  IFS='.' read -r major minor patch <<< "$version"
  case "$bump" in
    patch) patch=$(( patch + 1 )) ;;
    minor) minor=$(( minor + 1 )); patch=0 ;;
    major) major=$(( major + 1 )); minor=0; patch=0 ;;
    *) echo "$bump" | sed 's/^v//' ;;  # explicit version — pass through
  esac
  echo "${major}.${minor}.${patch}"
}

# ── ask for confirmation ──────────────────────────────────────────────────────
_confirm() {
  local prompt="$1"
  read -r -p "$(echo -e "  ${YELLOW}?${RESET} ${prompt} [y/N] ")" REPLY
  [[ "${REPLY,,}" == "y" ]] || { echo "Aborted."; exit 0; }
}

# ══════════════════════════════════════════════════════════════════════════════
# V5 RELEASE — devloop.sh bash script
# ══════════════════════════════════════════════════════════════════════════════
release_v5() {
  local bump="$1"

  step "── DevLoop v5 Release ──────────────────────────────"

  # Current version
  local current; current="$(grep '^VERSION=' devloop.sh | head -1 | tr -d '"' | cut -d= -f2)"
  info "Current version: ${current}"

  # Compute new version
  local new_ver; new_ver="$(_bump_semver "$current" "$bump")"
  info "New version: ${GREEN}${new_ver}${RESET}"
  echo ""
  _confirm "Release v5 ${current} → ${new_ver}?"

  # ── pre-release check
  step "1. Pre-release checks"
  bash scripts/pre-release-check.sh v5 || error "Pre-release check failed — fix issues above"

  # ── bump version
  step "2. Bump version"
  sed -i '' "s/^VERSION=\"[^\"]*\"/VERSION=\"${new_ver}\"/" devloop.sh
  echo "${new_ver}" > VERSION
  grep '^VERSION=' devloop.sh | head -1
  success "Updated devloop.sh + VERSION file"

  # ── bash -n after edit
  step "3. Syntax check after edit"
  /usr/bin/env bash -n devloop.sh && success "bash -n passed"

  # ── update CHANGELOG
  step "4. Update CHANGELOG.md"
  local today; today="$(date +%Y-%m-%d)"
  local cl_entry="## [${new_ver}] — ${today}

### Added / Fixed
- <!-- fill in before committing -->

---

"
  # prepend after the header line (after "---\n")
  python3 - "$cl_entry" <<'PYEOF'
import sys, re
entry = sys.argv[1]
with open("CHANGELOG.md", "r") as f:
    content = f.read()
# Insert after the first "---\n" separator
content = re.sub(r'(---\n\n)', r'\1' + entry, content, count=1)
with open("CHANGELOG.md", "w") as f:
    f.write(content)
print("  Inserted changelog entry for", entry.split("\n")[0])
PYEOF
  warn "Edit CHANGELOG.md to fill in the change details, then press Enter"
  read -r -p "  Press Enter when CHANGELOG is ready: "

  # ── commit
  step "5. Commit"
  git add devloop.sh VERSION CHANGELOG.md
  git commit -m "chore: bump devloop.sh to v${new_ver}

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
  success "Committed"

  # ── push + tag
  step "6. Push + tag"
  git push origin main
  git tag -a "v${new_ver}" -m "DevLoop v${new_ver}"
  git push origin "v${new_ver}"
  success "Pushed tag v${new_ver}"

  # ── GitHub Release with devloop.sh asset
  step "7. GitHub Release"
  gh release create "v${new_ver}" devloop.sh \
    --title "DevLoop v${new_ver}" \
    --notes "## DevLoop v${new_ver}

See [CHANGELOG.md](https://github.com/shaifulshabuj/devloop/blob/main/CHANGELOG.md) for details.

### Update (existing v5 users)
\`\`\`bash
devloop update
\`\`\`

### Fresh install
\`\`\`bash
curl -fsSL https://raw.githubusercontent.com/shaifulshabuj/devloop/main/devloop.sh -o devloop.sh
sudo cp devloop.sh /usr/local/bin/devloop
chmod +x /usr/local/bin/devloop
\`\`\`" \
    --latest
  success "GitHub Release created: v${new_ver}"

  echo ""
  echo -e "${GREEN}${BOLD}✅ v5 Release complete: v${new_ver}${RESET}"
  echo ""
  echo "  Run self-improvement step:"
  echo -e "  ${CYAN}bash ~/.copilot/skills/devloop-release-skill/update-skill.sh${RESET}"
}

# ══════════════════════════════════════════════════════════════════════════════
# V6 RELEASE — Go binary via GoReleaser CI
# ══════════════════════════════════════════════════════════════════════════════
release_v6() {
  local bump="$1"

  step "── DevLoop v6 Release ──────────────────────────────"

  # Current version — from latest git tag
  local current_tag; current_tag="$(git tag --sort=-version:refname | grep '^v6\.' | head -1)"
  local current; current="${current_tag#v}"
  info "Current tag:  ${current_tag}"

  # Compute new version
  local new_ver; new_ver="$(_bump_semver "$current" "$bump")"
  local new_tag="v${new_ver}"
  info "New version:  ${GREEN}${new_tag}${RESET}"
  echo ""
  info "GoReleaser will automatically build and publish:"
  info "  darwin/arm64, darwin/amd64, linux/arm64, linux/amd64, windows/amd64"
  echo ""
  _confirm "Release v6 ${current_tag} → ${new_tag}?"

  # ── pre-release check
  step "1. Pre-release checks"
  bash scripts/pre-release-check.sh v6 || error "Pre-release check failed — fix issues above"

  # ── bump version in source files
  step "2. Bump version in source"
  # main.go: var version = "v6.x.y"
  sed -i '' "s/var version = \"v[^\"]*\"/var version = \"${new_tag}\"/" cmd/devloop/main.go
  # Makefile: VERSION := v6.x.y
  sed -i '' "s/^VERSION := v[0-9.]*/VERSION := ${new_tag}/" Makefile

  grep 'var version' cmd/devloop/main.go
  grep '^VERSION :=' Makefile
  success "Updated cmd/devloop/main.go + Makefile"

  # ── rebuild to verify
  step "3. Rebuild binary"
  make build
  ./devloop version
  success "Binary built: $(./devloop version)"

  # ── update CHANGELOG
  step "4. Update CHANGELOG.md"
  local today; today="$(date +%Y-%m-%d)"
  local cl_entry="## [${new_ver}] — ${today}

### Added / Fixed
- <!-- fill in before committing -->

---

"
  python3 - "$cl_entry" <<'PYEOF'
import sys, re
entry = sys.argv[1]
with open("CHANGELOG.md", "r") as f:
    content = f.read()
content = re.sub(r'(---\n\n)', r'\1' + entry, content, count=1)
with open("CHANGELOG.md", "w") as f:
    f.write(content)
print("  Inserted changelog entry for", entry.split("\n")[0])
PYEOF
  warn "Edit CHANGELOG.md to fill in the change details, then press Enter"
  read -r -p "  Press Enter when CHANGELOG is ready: "

  # ── commit
  step "5. Commit version bump"
  git add cmd/devloop/main.go Makefile CHANGELOG.md devloop
  git commit -m "chore: bump version to ${new_tag}

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
  success "Committed"

  # ── push main
  step "6. Push main"
  git push origin main
  success "Pushed main"

  # ── tag + push (triggers GoReleaser CI)
  step "7. Tag + push (triggers GoReleaser CI)"
  git tag -a "${new_tag}" -m "DevLoop ${new_tag} — see CHANGELOG.md"
  git push origin "${new_tag}"
  success "Pushed tag ${new_tag} — GoReleaser CI is now running"

  # ── watch CI
  step "8. Monitor GoReleaser"
  info "Watching release workflow (Ctrl+C to detach)..."
  sleep 5
  gh run list --repo shaifulshabuj/devloop --limit 3 2>/dev/null || true
  echo ""
  info "Full CI logs: gh run watch --repo shaifulshabuj/devloop"
  info "Release URL:  https://github.com/shaifulshabuj/devloop/releases/tag/${new_tag}"

  echo ""
  echo -e "${GREEN}${BOLD}✅ v6 Release triggered: ${new_tag}${RESET}"
  echo ""
  echo "  GoReleaser CI will attach all 5 platform binaries automatically."
  echo "  Run self-improvement step after CI completes:"
  echo -e "  ${CYAN}bash ~/.copilot/skills/devloop-release-skill/update-skill.sh${RESET}"
}

# ── dispatch ──────────────────────────────────────────────────────────────────
case "$CHANNEL" in
  v5) release_v5 "$BUMP" ;;
  v6) release_v6 "$BUMP" ;;
esac
