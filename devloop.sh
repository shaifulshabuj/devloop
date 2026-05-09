#!/usr/bin/env bash
# =============================================================================
# devloop — Claude Code + Copilot CLI orchestration tool with provider routing
#
# Install globally:
#   curl -fsSL https://raw.githubusercontent.com/you/devloop/main/devloop \
#     -o /usr/local/bin/devloop && chmod +x /usr/local/bin/devloop
#
# Or manually:
#   chmod +x devloop && sudo mv devloop /usr/local/bin/devloop
#
# Usage:
#   devloop init                — set up a project (agents, CLAUDE.md, config)
#   devloop start               — launch provider session + orchestrator agent (Claude: remote; Copilot: local)
#   devloop architect "feature"
#   devloop work [TASK-ID]
#   devloop review [TASK-ID]
#   devloop fix [TASK-ID]
#   devloop tasks
#   devloop status [TASK-ID]
#   devloop open [TASK-ID]      — open spec in $EDITOR
#   devloop block [TASK-ID]     — print Copilot Instructions Block
#   devloop clean [--days N]    — remove finalized specs older than N days
#   devloop update              — self-upgrade (requires DEVLOOP_SOURCE_URL)
# =============================================================================

set -euo pipefail

VERSION="4.8.0"
DEVLOOP_DIR=".devloop"
SPECS_DIR="$DEVLOOP_DIR/specs"
PROMPTS_DIR="$DEVLOOP_DIR/prompts"
AGENTS_DIR=".claude/agents"
CONFIG_FILE="devloop.config.sh"
# GitHub source — used by default for version checks and self-update (no config needed)
DEVLOOP_GITHUB_REPO="${DEVLOOP_GITHUB_REPO:-shaifulshabuj/devloop}"
DEVLOOP_SOURCE_URL="${DEVLOOP_SOURCE_URL:-}"   # override to use a custom script URL

# ── Colors ────────────────────────────────────────────────────────────────────
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
GRAY='\033[0;90m'
BOLD='\033[1m'
RESET='\033[0m'

header() {
  echo -e "\n${CYAN}${BOLD}🔁 DevLoop${RESET} ${GRAY}v$VERSION${RESET}\n"
}
info()    { echo -e "${CYAN}ℹ${RESET}  $*"; }
success() { echo -e "${GREEN}✔${RESET}  $*"; }
warn()    { echo -e "${YELLOW}⚠${RESET}  $*"; }
error()   { echo -e "${RED}✖${RESET}  $*" >&2; }
step()    { echo -e "\n${BOLD}$*${RESET}"; }
divider() { echo -e "${GRAY}$(printf '─%.0s' {1..60})${RESET}"; }

# ── Helpers ───────────────────────────────────────────────────────────────────

normalize_verdict_token() {
  local raw="${1:-}"
  local cleaned=""

  cleaned="$(printf '%s' "$raw" \
    | tr '[:lower:]' '[:upper:]' \
    | sed -E 's/[#*_`>|:]+/ /g; s/[^A-Z_[:space:]-]+/ /g; s/-/ /g; s/[[:space:]]+/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//')"

  if [[ "$cleaned" =~ (^|[[:space:]])NEEDS([[:space:]_])*WORK($|[[:space:]]) ]]; then
    echo "NEEDS_WORK"
  elif [[ "$cleaned" =~ (^|[[:space:]])APPROVED($|[[:space:]]) ]]; then
    echo "APPROVED"
  elif [[ "$cleaned" =~ (^|[[:space:]])REJECTED($|[[:space:]]) ]]; then
    echo "REJECTED"
  else
    echo "UNKNOWN"
  fi
}

parse_review_verdict() {
  local review_file="$1"
  local candidate
  local verdict

  [[ -f "$review_file" ]] || { echo "UNKNOWN"; return; }

  # Canonical line always wins, even if malformed.
  candidate="$(
    awk '
      /^[[:space:]]*Verdict:[[:space:]]*/ {
        line=$0
        sub(/^[[:space:]]*Verdict:[[:space:]]*/, "", line)
        print "__FOUND__" line
        exit
      }
    ' "$review_file" 2>/dev/null \
      || true
  )"
  if [[ "$candidate" == __FOUND__* ]]; then
    verdict="$(normalize_verdict_token "${candidate#__FOUND__}")"
    echo "$verdict"
    return
  fi

  # Fallback: markdown heading style.
  candidate="$(
    awk '
      /^[[:space:]]*#{1,6}[[:space:]]*Verdict:[[:space:]]*/ {
        line=$0
        sub(/^[[:space:]]*#{1,6}[[:space:]]*Verdict:[[:space:]]*/, "", line)
        print line
        exit
      }
    ' "$review_file" 2>/dev/null \
      || true
  )"
  if [[ -n "$candidate" ]]; then
    verdict="$(normalize_verdict_token "$candidate")"
    [[ "$verdict" != "UNKNOWN" ]] && { echo "$verdict"; return; }
  fi

  # Fallback: markdown bold label style.
  candidate="$(
    awk '
      /^[[:space:]]*\*\*[[:space:]]*Verdict:[[:space:]]*\*\*[[:space:]]*/ {
        line=$0
        sub(/^[[:space:]]*\*\*[[:space:]]*Verdict:[[:space:]]*\*\*[[:space:]]*/, "", line)
        print line
        exit
      }
    ' "$review_file" 2>/dev/null \
      || true
  )"
  if [[ -n "$candidate" ]]; then
    verdict="$(normalize_verdict_token "$candidate")"
    [[ "$verdict" != "UNKNOWN" ]] && { echo "$verdict"; return; }
  fi

  # Fallback: standalone verdict token anywhere in output.
  candidate="$(
    grep -Eio '(APPROVED|REJECTED|NEEDS[[:space:]_-]*WORK)' "$review_file" 2>/dev/null \
      | head -1 || true
  )"
  if [[ -n "$candidate" ]]; then
    verdict="$(normalize_verdict_token "$candidate")"
    [[ "$verdict" != "UNKNOWN" ]] && { echo "$verdict"; return; }
  fi

  echo "UNKNOWN"
}

find_project_root() {
  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    [[ -f "$dir/$CONFIG_FILE" || -d "$dir/.git" ]] && echo "$dir" && return
    dir="$(dirname "$dir")"
  done
  echo "$PWD"
}

load_config() {
  local root
  root="$(find_project_root)"
  CONFIG_PATH="$root/$CONFIG_FILE"
  SPECS_PATH="$root/$SPECS_DIR"
  PROMPTS_PATH="$root/$PROMPTS_DIR"
  AGENTS_PATH="$root/$AGENTS_DIR"

  PROJECT_NAME="$(basename "$root")"
  PROJECT_STACK="Unknown stack"
  PROJECT_PATTERNS="SOLID, Clean Architecture"
  PROJECT_CONVENTIONS="Use async/await, handle all errors explicitly"
  TEST_FRAMEWORK="default"
  CLAUDE_MODEL="sonnet"
  CLAUDE_MAIN_MODEL=""   # if set, overrides CLAUDE_MODEL for main roles (architect/reviewer/orchestrator)
  CLAUDE_WORKER_MODEL="" # if set, overrides CLAUDE_MODEL for worker/fix roles
  DEVLOOP_MAIN_PROVIDER="claude"
  DEVLOOP_WORKER_PROVIDER="copilot"
  DEVLOOP_WORKER_MODE="cli"
  DEVLOOP_VERSION_URL=""
  DEVLOOP_FAILOVER_ENABLED="true"
  DEVLOOP_PROBE_INTERVAL="5"    # minutes between availability probes when a provider is limited
  DEVLOOP_PERMISSION_MODE="smart"   # off | auto | smart | strict
  DEVLOOP_PERMISSION_TIMEOUT="60"   # seconds to wait for user response on escalated permissions
  DEVLOOP_FIX_STRATEGY="escalate"  # escalate (deep fix + respec) | standard (hard cap, no escalation)

  if [[ -f "$CONFIG_PATH" ]]; then source "$CONFIG_PATH"; fi
}

ensure_dirs() {
  mkdir -p "$SPECS_PATH" "$PROMPTS_PATH" "$AGENTS_PATH"
  local root; root="$(find_project_root)"
  mkdir -p "$root/$DEVLOOP_DIR/permission-queue"
}

check_deps() {
  local missing=()
  # Always require git
  command -v git &>/dev/null || missing+=("git     → https://git-scm.com")

  # Require the configured providers (or defaults if config not loaded yet)
  local main_p="${DEVLOOP_MAIN_PROVIDER:-claude}"
  local worker_p="${DEVLOOP_WORKER_PROVIDER:-copilot}"

  case "$main_p" in
    claude)  command -v claude  &>/dev/null || missing+=("claude  → curl -fsSL https://claude.ai/install.sh | bash") ;;
    copilot) command -v copilot &>/dev/null || missing+=("copilot → npm install -g @github/copilot") ;;
  esac

  case "$worker_p" in
    claude)   command -v claude   &>/dev/null || missing+=("claude   → curl -fsSL https://claude.ai/install.sh | bash") ;;
    copilot)  command -v copilot  &>/dev/null || missing+=("copilot  → npm install -g @github/copilot") ;;
    opencode) command -v opencode &>/dev/null || missing+=("opencode → npm install -g opencode-ai  or  https://opencode.ai") ;;
    pi)       command -v pi       &>/dev/null || missing+=("pi       → https://pi.dev/docs/latest") ;;
  esac

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing required tools:"
    for m in "${missing[@]}"; do echo -e "    ${GRAY}$m${RESET}"; done
    exit 1
  fi
}

# FIX #3: Use seconds precision to prevent same-minute task ID collisions
task_id() { echo "TASK-$(date +%Y%m%d-%H%M%S)"; }

# Note: load_config must be called before latest_task so $SPECS_PATH is set
latest_task() {
  ls -1t "$SPECS_PATH"/*.md 2>/dev/null \
    | grep -v '\-review\.md' \
    | head -1 \
    | xargs basename 2>/dev/null \
    | sed 's/\.md//' \
    || echo ""
}

normalize_provider() {
  # Main-role providers only (support remote control / session piping)
  local provider="${1:-}"
  provider="$(printf '%s' "$provider" | tr '[:upper:]' '[:lower:]')"
  case "$provider" in
    claude|copilot) echo "$provider" ;;
    opencode|pi)
      error "Provider '${provider}' is a worker-only provider (no remote control)."
      error "Set DEVLOOP_MAIN_PROVIDER to: claude or copilot"
      exit 1
      ;;
    *)
      error "Invalid DevLoop provider: ${provider:-<empty>}"
      error "Expected one of: claude, copilot"
      exit 1
      ;;
  esac
}

normalize_worker_provider() {
  # Worker-role providers (local CLI execution, no remote control required)
  local provider="${1:-}"
  provider="$(printf '%s' "$provider" | tr '[:upper:]' '[:lower:]')"
  case "$provider" in
    claude|copilot|opencode|pi) echo "$provider" ;;
    *)
      error "Invalid DevLoop worker provider: ${provider:-<empty>}"
      error "Expected one of: claude, copilot, opencode, pi"
      exit 1
      ;;
  esac
}

provider_label() {
  case "$1" in
    claude)    echo "Claude" ;;
    copilot)   echo "Copilot" ;;
    opencode)  echo "OpenCode" ;;
    pi)        echo "Pi" ;;
    *)         echo "$1" ;;
  esac
}

main_provider() {
  normalize_provider "${DEVLOOP_MAIN_PROVIDER:-claude}"
}

worker_provider() {
  normalize_worker_provider "${DEVLOOP_WORKER_PROVIDER:-copilot}"
}

# ── Provider Health / Auto-Failover ──────────────────────────────────────────
# State file lives at <project-root>/.devloop/provider-health.sh
# Shell-sourced vars; human-readable; gitignored at init time.

_health_file() {
  local root; root="$(find_project_root)"
  echo "$root/$DEVLOOP_DIR/provider-health.sh"
}

_health_load() {
  # Set safe defaults then source the file if it exists
  HEALTH_MAIN_LIMITED_SINCE=""
  HEALTH_MAIN_OVERRIDE=""
  HEALTH_MAIN_LAST_PROBE=""
  HEALTH_WORKER_LIMITED_SINCE=""
  HEALTH_WORKER_OVERRIDE=""
  HEALTH_WORKER_LAST_PROBE=""
  local hf; hf="$(_health_file)"
  [[ -f "$hf" ]] && source "$hf" 2>/dev/null || true
}

_health_save() {
  local hf; hf="$(_health_file)"
  local dir; dir="$(dirname "$hf")"
  mkdir -p "$dir"
  cat > "$hf" <<EOF
# DevLoop provider health state — auto-managed, do not edit manually
HEALTH_MAIN_LIMITED_SINCE="${HEALTH_MAIN_LIMITED_SINCE:-}"
HEALTH_MAIN_OVERRIDE="${HEALTH_MAIN_OVERRIDE:-}"
HEALTH_MAIN_LAST_PROBE="${HEALTH_MAIN_LAST_PROBE:-}"
HEALTH_WORKER_LIMITED_SINCE="${HEALTH_WORKER_LIMITED_SINCE:-}"
HEALTH_WORKER_OVERRIDE="${HEALTH_WORKER_OVERRIDE:-}"
HEALTH_WORKER_LAST_PROBE="${HEALTH_WORKER_LAST_PROBE:-}"
EOF
}

_health_mark_limited() {
  # Usage: _health_mark_limited main|worker fallback_provider
  local role="$1"
  local fallback="$2"
  _health_load
  local ts; ts="$(date +%s)"
  if [[ "$role" == "main" ]]; then
    HEALTH_MAIN_LIMITED_SINCE="$ts"
    HEALTH_MAIN_OVERRIDE="$fallback"
  else
    HEALTH_WORKER_LIMITED_SINCE="$ts"
    HEALTH_WORKER_OVERRIDE="$fallback"
  fi
  _health_save
}

_health_clear() {
  # Usage: _health_clear main|worker
  local role="$1"
  _health_load
  if [[ "$role" == "main" ]]; then
    HEALTH_MAIN_LIMITED_SINCE=""
    HEALTH_MAIN_OVERRIDE=""
  else
    HEALTH_WORKER_LIMITED_SINCE=""
    HEALTH_WORKER_OVERRIDE=""
  fi
  _health_save
}

_is_rate_limit_error() {
  local text="$1"
  echo "$text" | grep -qiE \
    "hit your (usage )?limit|rate.?limit|usage limit reached|429|Too Many Requests|overloaded|try again later|exceeded.*quota|quota.*exceeded"
}

_probe_provider() {
  local provider="$1"
  local tmp; tmp="$(mktemp /tmp/devloop-probe-XXXXXX)"
  local rc=0
  case "$provider" in
    claude)
      if ! echo "Reply with exactly: OK" | claude -p --model "${CLAUDE_MODEL:-sonnet}" > "$tmp" 2>&1; then
        rc=1
      fi
      _is_rate_limit_error "$(cat "$tmp")" && rc=1
      ;;
    copilot)
      if ! copilot --allow-all-tools --allow-all-paths -p "Reply with exactly: OK" > "$tmp" 2>&1; then
        rc=1
      fi
      _is_rate_limit_error "$(cat "$tmp")" && rc=1
      ;;
    *)
      rc=1
      ;;
  esac
  rm -f "$tmp"
  return $rc
}

_fallback_main() {
  # Return the next main provider in the failover chain
  local current="$1"
  case "$current" in
    claude)   echo "copilot" ;;
    copilot)  echo "" ;;  # no further fallback
    *)        echo "" ;;
  esac
}

_fallback_worker() {
  # Return the next worker provider in the failover chain
  local current="$1"
  case "$current" in
    copilot)  echo "opencode" ;;
    claude)   echo "opencode" ;;
    opencode) echo "pi" ;;
    pi)       echo "" ;;
    *)        echo "" ;;
  esac
}

_maybe_recover() {
  # Called at start of work/architect/review — probes limited providers and
  # restores them the moment they are available again.
  # Probes run at most every DEVLOOP_PROBE_INTERVAL minutes (default: 5) to
  # avoid hammering the provider API.
  _health_load
  local probe_secs=$(( ${DEVLOOP_PROBE_INTERVAL:-5} * 60 ))
  local now; now="$(date +%s)"

  if [[ -n "$HEALTH_MAIN_OVERRIDE" ]]; then
    local orig; orig="$(main_provider)"
    local last_probe="${HEALTH_MAIN_LAST_PROBE:-0}"
    local since_probe=$(( now - last_probe ))
    if (( since_probe >= probe_secs )); then
      info "Probing $(provider_label "$orig") for availability..."
      HEALTH_MAIN_LAST_PROBE="$now"
      _health_save
      if _probe_provider "$orig"; then
        success "$(provider_label "$orig") is available — restoring as main provider"
        _health_clear main
      else
        info "$(provider_label "$orig") still limited — keeping override: $(provider_label "$HEALTH_MAIN_OVERRIDE")"
      fi
    else
      local wait_sec=$(( probe_secs - since_probe ))
      info "$(provider_label "$HEALTH_MAIN_OVERRIDE") active (next probe for $(provider_label "$orig") in ${wait_sec}s)"
    fi
  fi

  if [[ -n "$HEALTH_WORKER_OVERRIDE" ]]; then
    local orig; orig="$(worker_provider)"
    local last_probe="${HEALTH_WORKER_LAST_PROBE:-0}"
    local since_probe=$(( now - last_probe ))
    if (( since_probe >= probe_secs )); then
      info "Probing $(provider_label "$orig") worker for availability..."
      HEALTH_WORKER_LAST_PROBE="$now"
      _health_save
      if _probe_provider "$orig"; then
        success "$(provider_label "$orig") is available — restoring as worker provider"
        _health_clear worker
      else
        info "$(provider_label "$orig") worker still limited — keeping override: $(provider_label "$HEALTH_WORKER_OVERRIDE")"
      fi
    else
      local wait_sec=$(( probe_secs - since_probe ))
      info "$(provider_label "$HEALTH_WORKER_OVERRIDE") active worker (next probe for $(provider_label "$orig") in ${wait_sec}s)"
    fi
  fi
}

effective_main_provider() {
  _health_load
  if [[ "${DEVLOOP_FAILOVER_ENABLED:-true}" == "true" && -n "$HEALTH_MAIN_OVERRIDE" ]]; then
    echo "$HEALTH_MAIN_OVERRIDE"
  else
    main_provider
  fi
}

effective_worker_provider() {
  _health_load
  if [[ "${DEVLOOP_FAILOVER_ENABLED:-true}" == "true" && -n "$HEALTH_WORKER_OVERRIDE" ]]; then
    echo "$HEALTH_WORKER_OVERRIDE"
  else
    worker_provider
  fi
}

# ── Version checking ──────────────────────────────────────────────────────────

# Fetch latest release version from GitHub API (no config required).
# Prefers gh CLI (authenticated, works for private repos); falls back to curl.
# Prints the version string (e.g. "4.3.0") or empty string on failure.
_gh_latest_version() {
  local repo="${DEVLOOP_GITHUB_REPO:-shaifulshabuj/devloop}"
  local ver=""
  # Prefer gh CLI — authenticated, works for both public and private repos
  if command -v gh &>/dev/null; then
    ver="$(gh api "repos/$repo/releases/latest" --jq '.tag_name' 2>/dev/null \
      | tr -d '[:space:]' | sed 's/^v//')"
    [[ -n "$ver" ]] && { echo "$ver"; return; }
  fi
  # Fallback: unauthenticated curl/wget (public repos only)
  local api_url="https://api.github.com/repos/$repo/releases/latest"
  local tmp; tmp="$(mktemp /tmp/devloop-ghapi.XXXXXX)"
  if command -v curl &>/dev/null; then
    curl -fsSL "$api_url" -o "$tmp" 2>/dev/null || { rm -f "$tmp"; echo ""; return; }
  elif command -v wget &>/dev/null; then
    wget -qO "$tmp" "$api_url" 2>/dev/null || { rm -f "$tmp"; echo ""; return; }
  else
    rm -f "$tmp"; echo ""; return
  fi
  if command -v python3 &>/dev/null; then
    ver="$(python3 -c "
import json, sys
try:
    d = json.load(open('$tmp'))
    print(d.get('tag_name','').lstrip('v'))
except Exception:
    pass
" 2>/dev/null)"
  else
    ver="$(grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' "$tmp" 2>/dev/null \
      | sed 's/.*"v\{0,1\}\([0-9][^"]*\)".*/\1/' | head -1)"
  fi
  rm -f "$tmp"
  echo "$ver"
}

# Returns the URL to download the latest devloop.sh from GitHub.
_gh_script_url() {
  local repo="${DEVLOOP_GITHUB_REPO:-shaifulshabuj/devloop}"
  echo "https://raw.githubusercontent.com/$repo/main/devloop.sh"
}

# Show the version hint banner if one is pending (non-blocking, safe to call anywhere).
_maybe_show_version_hint() {
  local root; root="$(find_project_root 2>/dev/null || echo ".")"
  local hint_file="$root/$DEVLOOP_DIR/.version-hint"
  if [[ -f "$hint_file" ]]; then
    local remote_ver; remote_ver="$(cat "$hint_file" 2>/dev/null | tr -d '[:space:]')"
    rm -f "$hint_file"
    if [[ -n "$remote_ver" && "$remote_ver" != "$VERSION" ]]; then
      warn "DevLoop ${GREEN}v${remote_ver}${RESET} available (you have v${VERSION}) — run ${CYAN}devloop update${RESET}"
      echo ""
    fi
  fi
  # Also fire off a fresh background probe so the hint is ready next time
  _check_version_bg
}

_check_version_bg() {
  local root; root="$(find_project_root 2>/dev/null || echo ".")"
  local hint_file="$root/$DEVLOOP_DIR/.version-hint"
  local url="${DEVLOOP_VERSION_URL:-}"
  (
    local remote_ver=""
    if [[ -n "$url" ]]; then
      # Custom VERSION file (plain semver text)
      local tmp; tmp="$(mktemp /tmp/devloop-ver.XXXXXX)"
      if command -v curl &>/dev/null; then
        curl -fsSL "$url" -o "$tmp" 2>/dev/null || { rm -f "$tmp"; exit 0; }
      elif command -v wget &>/dev/null; then
        wget -qO "$tmp" "$url" 2>/dev/null || { rm -f "$tmp"; exit 0; }
      else
        rm -f "$tmp"; exit 0
      fi
      remote_ver="$(head -1 "$tmp" | tr -d '[:space:]')"
      rm -f "$tmp"
    else
      # Default: GitHub releases API
      remote_ver="$(_gh_latest_version 2>/dev/null)"
    fi
    if [[ -n "$remote_ver" && "$remote_ver" != "$VERSION" ]]; then
      mkdir -p "$(dirname "$hint_file")"
      echo "$remote_ver" > "$hint_file"
    fi
  ) >/dev/null 2>&1 &
}

cmd_check() {
  load_config
  step "🔍 Checking for DevLoop updates..."
  info "Local:  ${BOLD}v$VERSION${RESET}"
  echo ""

  local remote_ver=""
  local url="${DEVLOOP_VERSION_URL:-}"

  if [[ -n "$url" ]]; then
    info "Source: custom URL (${GRAY}$url${RESET})"
    local tmp; tmp="$(mktemp /tmp/devloop-ver.XXXXXX)"
    if command -v curl &>/dev/null; then
      curl -fsSL "$url" -o "$tmp" 2>/dev/null || { warn "Could not reach $url"; rm -f "$tmp"; return; }
    elif command -v wget &>/dev/null; then
      wget -qO "$tmp" "$url" 2>/dev/null || { warn "Could not reach $url"; rm -f "$tmp"; return; }
    else
      error "Neither curl nor wget found"; rm -f "$tmp"; return
    fi
    remote_ver="$(head -1 "$tmp" | tr -d '[:space:]')"
    rm -f "$tmp"
  else
    local repo="${DEVLOOP_GITHUB_REPO:-shaifulshabuj/devloop}"
    info "Source: GitHub releases (${GRAY}$repo${RESET})"
    remote_ver="$(_gh_latest_version)"
  fi

  echo ""
  if [[ -z "$remote_ver" ]]; then
    warn "Could not determine remote version — check your internet connection"
    return
  fi

  if [[ "$remote_ver" == "$VERSION" ]]; then
    success "Up to date — ${BOLD}v$VERSION${RESET} ✅"
  else
    warn "Update available: ${BOLD}v$VERSION${RESET} → ${GREEN}v$remote_ver${RESET}"
    echo -e "  Run: ${CYAN}devloop update${RESET}"
  fi
  echo ""
}

# ── Self-improvement ──────────────────────────────────────────────────────────

cmd_learn() {
  load_config
  ensure_dirs
  check_deps

  local id="${1:-$(latest_task)}"
  [[ -z "$id" ]] && { error "No task found."; exit 1; }

  local review_file="$SPECS_PATH/$id-review.md"
  local spec_file="$SPECS_PATH/$id.md"

  [[ ! -f "$review_file" ]] && { error "No review found for $id. Run: devloop review $id"; exit 1; }

  step "🧠 Learning from: ${BOLD}$id${RESET}"
  divider

  local provider; provider="$(effective_main_provider)"
  learn_prompt="You are analyzing a code review to extract reusable lessons for future development.

## Task spec (excerpt)
$(head -60 "$spec_file" 2>/dev/null)

## Code review outcome
$(cat "$review_file")

## Your task
Extract 2-5 specific, reusable lessons from this review. Format each as a Markdown list item.
Focus on:
- Anti-patterns found (what NOT to do next time)
- Patterns that worked well
- Common mistakes to avoid in this stack
- Conventions that were enforced

Output ONLY the Markdown list items, one per line, starting with '-'. No headers, no prose, no intro sentence."

  local lessons_file; lessons_file="$(mktemp /tmp/devloop-lessons.XXXXXX)"
  info "Calling $(provider_label "$provider") to extract lessons..."
  run_provider_prompt "$provider" "$learn_prompt" "$lessons_file"
  local lessons; lessons="$(cat "$lessons_file")"
  rm -f "$lessons_file"

  if [[ -z "$lessons" ]]; then
    warn "Could not extract lessons from review"
    return
  fi

  echo ""
  info "Extracted lessons:"
  echo -e "${GRAY}$lessons${RESET}"
  echo ""

  local root; root="$(find_project_root)"
  local claude_md="$root/CLAUDE.md"

  if [[ ! -f "$claude_md" ]]; then
    warn "CLAUDE.md not found — creating it"
    echo "# Claude Code — DevLoop Project" > "$claude_md"
  fi

  if grep -q '^## Learned Patterns' "$claude_md"; then
    {
      printf '\n### From %s (%s)\n' "$id" "$(date +%Y-%m-%d)"
      printf '%s\n' "$lessons"
    } >> "$claude_md"
  else
    {
      printf '\n## Learned Patterns\n'
      printf '_Auto-updated by `devloop learn`. Applied to future architect prompts._\n'
      printf '\n### From %s (%s)\n' "$id" "$(date +%Y-%m-%d)"
      printf '%s\n' "$lessons"
    } >> "$claude_md"
  fi

  success "Lessons appended to ${CYAN}CLAUDE.md${RESET}"
  info "Claude will apply these patterns in future architect sessions"
  echo ""
}

# ── Agent Doc Sync ────────────────────────────────────────────────────────────

AGENT_DOCS_DIR=".devloop/agent-docs"

_agent_doc_url() {
  case "$1" in
    claude)   echo "https://code.claude.com/docs/en/overview" ;;
    copilot)  echo "https://docs.github.com/en/copilot/github-copilot-in-the-cli/using-github-copilot-in-the-cli" ;;
    opencode) echo "https://opencode.ai/docs/cli/" ;;
    pi)       echo "https://pi.dev/docs/latest" ;;
  esac
}

_agent_npm_package() {
  case "$1" in
    copilot)  echo "@github/copilot" ;;
    opencode) echo "opencode" ;;
  esac
}

_agent_docs_stale() {
  local file="$1"
  local max_age_seconds="${2:-86400}"  # default 24h
  [[ ! -f "$file" ]] && return 0
  local mtime now age
  mtime="$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  age=$(( now - mtime ))
  [[ $age -gt $max_age_seconds ]]
}

_agent_check_version() {
  local provider="$1"
  local installed="" latest=""
  case "$provider" in
    claude)
      installed="$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || echo "")"
      ;;
    copilot)
      installed="$(copilot --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")"
      latest="$(npm show @github/copilot version 2>/dev/null | tr -d ' \n' || echo "")"
      ;;
    opencode)
      installed="$(opencode --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")"
      latest="$(npm show opencode version 2>/dev/null | tr -d ' \n' || echo "")"
      ;;
    pi)
      installed="$(pi --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")"
      ;;
  esac
  local label; label="$(provider_label "$provider")"
  if [[ -z "$installed" ]]; then
    warn "  $(provider_label "$provider"): not installed or version unknown"
    return
  fi
  if [[ -n "$latest" && "$latest" != "$installed" ]]; then
    warn "  $label: v$installed → v$latest available"
    case "$provider" in
      copilot)  echo -e "     ${GRAY}→ npm install -g @github/copilot${RESET}" ;;
      opencode) echo -e "     ${GRAY}→ npm install -g opencode${RESET}" ;;
    esac
  else
    success "  $label: v$installed${latest:+ (latest)}"
  fi
}

_agent_fetch_docs() {
  local provider="$1"
  local docs_dir="$2"
  local doc_cache="$docs_dir/${provider}-docs.md"
  local url; url="$(_agent_doc_url "$provider")"

  [[ -z "$url" ]] && return 1
  command -v curl &>/dev/null || { warn "curl not found — skipping doc fetch"; return 1; }

  info "  Fetching $(provider_label "$provider") docs from $url ..."
  local tmp_html; tmp_html="$(mktemp /tmp/devloop-docs-XXXXXX.html)"
  if curl -fsSL --max-time 15 "$url" -o "$tmp_html" 2>/dev/null; then
    {
      echo "# $(provider_label "$provider") — CLI Reference"
      echo "# Source: $url"
      echo "# Fetched: $(date '+%Y-%m-%d %H:%M %Z')"
      echo ""
      # Strip HTML tags, collapse whitespace, remove blank lines, limit to 300 lines
      sed 's/<[^>]*>//g; s/&lt;/</g; s/&gt;/>/g; s/&amp;/\&/g; s/&#39;/'"'"'/g; s/&quot;/"/g' "$tmp_html" \
        | tr -s ' \t' ' ' \
        | sed '/^[[:space:]]*$/d' \
        | head -300
    } > "$doc_cache"
    rm -f "$tmp_html"
    return 0
  else
    warn "  Could not fetch docs for $(provider_label "$provider") (network error)"
    rm -f "$tmp_html"
    return 1
  fi
}

_agent_write_context() {
  local docs_dir="$1"
  local main_p="$2"
  local worker_p="$3"
  local context_file="$docs_dir/provider-context.md"
  {
    echo "# DevLoop Provider Context"
    echo "# Auto-generated by \`devloop agent-sync\` — $(date '+%Y-%m-%d %H:%M')"
    echo ""
    echo "## Active Configuration"
    echo "- **Main provider** (orchestrator/architect/reviewer): $(provider_label "$main_p")"
    echo "- **Worker provider** (work/fix): $(provider_label "$worker_p")"
    echo "- **Claude main model:** ${CLAUDE_MAIN_MODEL:-${CLAUDE_MODEL:-sonnet}} (architect/reviewer/orchestrator)"
    echo "- **Claude worker model:** ${CLAUDE_WORKER_MODEL:-${CLAUDE_MODEL:-sonnet}} (work/fix)"
    echo "- **Copilot model:** determined by GitHub subscription (no CLI flag available)"
    echo ""
    echo "## Provider CLI Quick Reference"
    echo ""
    echo "### Claude"
    echo "- **Install:** \`curl -fsSL https://claude.ai/install.sh | bash\`"
    echo "- **Non-interactive:** \`echo \"prompt\" | claude -p --model sonnet\`"
    echo "- **Models:** sonnet (balanced), opus (most capable), haiku (fast/cheap)"
    echo "- **Remote control:** supported via claude.ai browser / mobile app"
    echo "- **Hooks:** \`~/.claude/settings.json\` (PreToolUse, PostToolUse, Stop)"
    echo "- **MCP:** \`.mcp.json\` (project) or \`~/.claude.json\` (global)"
    echo "- **Sub-agents:** \`.claude/agents/*.md\` — launched via Task tool"
    echo "- **Docs:** https://code.claude.com/docs/en/overview"
    echo ""
    echo "### Copilot"
    echo "- **Install:** \`npm install -g @github/copilot\`"
    echo "- **Non-interactive:** \`copilot --allow-all-tools --allow-all-paths -p \"<prompt>\"\`"
    echo "- **Model:** set via GitHub settings (https://github.com/settings/copilot) — no --model CLI flag"
    echo "- **Remote control:** supported (Copilot coding agent)"
    echo "- **Instructions:** \`.github/copilot-instructions.md\`"
    echo "- **Skills:** \`.github/copilot/skills/\` and \`.copilot/\`"
    echo "- **Docs:** https://docs.github.com/en/copilot"
    echo ""
    echo "### OpenCode (worker-only)"
    echo "- **Install:** \`npm install -g opencode\`"
    echo "- **Non-interactive:** \`opencode run --file spec.md \"instruction\"\`"
    echo "- **Remote control:** NOT supported"
    echo "- **Config:** \`opencode.json\` in project root"
    echo "- **Docs:** https://opencode.ai/docs/cli/"
    echo ""
    echo "### Pi (worker-only)"
    echo "- **Install:** see https://pi.dev/docs/latest"
    echo "- **Non-interactive:** \`pi --mode json \"prompt\"\` (JSONL event stream)"
    echo "- **Remote control:** NOT supported"
    echo "- **Docs:** https://pi.dev/docs/latest"
    echo ""
    echo "## DevLoop Invocation Matrix"
    echo ""
    echo "| Provider | Role | Command | Prompt prefix |"
    echo "|----------|------|---------|--------------|"
    echo "| claude | main+worker | \`echo \"\$prompt\" | claude -p --model \$model\` | none |"
    echo "| | main roles | CLAUDE_MAIN_MODEL=${CLAUDE_MAIN_MODEL:-${CLAUDE_MODEL:-sonnet}} | |"
    echo "| | worker/fix | CLAUDE_WORKER_MODEL=${CLAUDE_WORKER_MODEL:-${CLAUDE_MODEL:-sonnet}} | |"
    echo "| copilot | main+worker | \`copilot --allow-all-tools --allow-all-paths -p \"\$prompt\"\` | /plan |"
    echo "| | | model: set at github.com/settings/copilot | |"
    echo "| opencode | worker only | \`opencode run --file spec.md \"instruction\"\` | none |"
    echo "| pi | worker only | \`pi --mode json \"\$prompt\"\` | none |"
  } > "$context_file"
  echo "$context_file"
}

cmd_agent_sync() {
  load_config
  ensure_dirs

  local root; root="$(find_project_root)"
  local docs_dir="$root/$AGENT_DOCS_DIR"
  mkdir -p "$docs_dir"

  local main_p worker_p
  main_p="$(main_provider)"
  worker_p="$(worker_provider)"

  # Deduplicate: if main == worker, only list once
  local providers=("$main_p")
  [[ "$worker_p" != "$main_p" ]] && providers+=("$worker_p")

  step "🔄 DevLoop Agent Sync"
  divider

  # ── 1. Version checks ──────────────────────────────────────────────────────
  echo ""
  info "Checking provider versions..."
  for p in "${providers[@]}"; do
    _agent_check_version "$p"
  done

  # ── 2. Fetch / refresh docs ────────────────────────────────────────────────
  echo ""
  info "Checking documentation cache (24h TTL)..."
  local refreshed=()
  for p in "${providers[@]}"; do
    local cache="$docs_dir/${p}-docs.md"
    if _agent_docs_stale "$cache" 86400; then
      _agent_fetch_docs "$p" "$docs_dir" && refreshed+=("$p")
    else
      local age_h=$(( ( $(date +%s) - $(stat -f %m "$cache" 2>/dev/null || stat -c %Y "$cache" 2>/dev/null || echo 0) ) / 3600 ))
      info "  $(provider_label "$p"): cached (${age_h}h old)"
    fi
  done

  # ── 3. Regenerate provider-context.md ─────────────────────────────────────
  echo ""
  info "Writing provider context summary..."
  local ctx_file
  ctx_file="$(_agent_write_context "$docs_dir" "$main_p" "$worker_p")"
  success "  Updated: ${CYAN}$(basename "$ctx_file")${RESET}"

  # ── 4. Ensure CLAUDE.md references the context file ───────────────────────
  local claude_md="$root/CLAUDE.md"
  local context_ref="## Agent Provider Context"
  if [[ -f "$claude_md" ]] && ! grep -q "$context_ref" "$claude_md"; then
    {
      echo ""
      echo "$context_ref"
      echo "_See \`.devloop/agent-docs/provider-context.md\` for the full provider reference._"
      echo "_Run \`devloop agent-sync\` to refresh docs and check for provider updates._"
    } >> "$claude_md"
    info "  CLAUDE.md: added provider context reference"
  fi

  # ── 5. If docs were refreshed, use main provider to analyse what's new ─────
  if [[ ${#refreshed[@]} -gt 0 ]]; then
    echo ""
    step "🧠 Analysing updated docs with $(provider_label "$main_p")..."
    divider

    local doc_contents=""
    for p in "${refreshed[@]}"; do
      local cache="$docs_dir/${p}-docs.md"
      [[ -f "$cache" ]] && doc_contents+="$(head -80 "$cache")"$'\n\n'
    done

    local analysis_prompt
    analysis_prompt="You are reviewing updated documentation for AI coding agent CLIs used in DevLoop.

## Updated providers: ${refreshed[*]}

## Extracted doc content (first 80 lines each):
$doc_contents

## Your task
Analyse these docs and produce a concise Markdown report with:
1. **New CLI features or flags** relevant to non-interactive/piped usage
2. **Breaking changes** in invocation syntax
3. **Best practices** for passing large prompts or spec files
4. **Recommended DevLoop improvements** (max 3 bullet points)

Be specific and actionable. If nothing significant changed, say so.
Keep the report under 300 words."

    local analysis_out; analysis_out="$(mktemp /tmp/devloop-agent-analysis.XXXXXX)"
    run_provider_prompt "$main_p" "$analysis_prompt" "$analysis_out" 2>/dev/null || true

    if [[ -s "$analysis_out" ]]; then
      local analysis; analysis="$(cat "$analysis_out")"

      # Guard: skip if response looks like an error / rate limit (too short or no markdown)
      local word_count; word_count="$(echo "$analysis" | wc -w | tr -d ' ')"
      if [[ $word_count -lt 20 ]] || echo "$analysis" | grep -qi "hit your limit\|rate limit\|error\|unauthorized\|forbidden"; then
        warn "Analysis skipped — provider returned an error or rate-limit response"
        rm -f "$analysis_out"
      else
        echo ""
        echo -e "${GRAY}$analysis${RESET}"
        echo ""

        # Save analysis to docs dir
        local report="$docs_dir/last-sync-report.md"
        {
          echo "# Agent Sync Report — $(date '+%Y-%m-%d %H:%M')"
          echo ""
          echo "**Providers refreshed:** ${refreshed[*]}"
          echo ""
          echo "$analysis"
        } > "$report"

        # Append to CLAUDE.md under Learned Patterns
        if [[ -f "$claude_md" ]]; then
          {
            echo ""
            echo "### Agent Sync — $(date +%Y-%m-%d) (providers: ${refreshed[*]})"
            echo "$analysis"
          } >> "$claude_md"
          info "Analysis appended to CLAUDE.md"
        fi
        rm -f "$analysis_out"
      fi
    fi
  fi  # end: if refreshed docs

  echo ""
  success "Agent sync complete"
  echo -e "  ${CYAN}.devloop/agent-docs/${RESET}   ← cached docs + context"
  echo -e "  Run ${CYAN}devloop agent-sync${RESET} to force-refresh (auto-skips if < 24h old)"
  echo ""
}



_write_hook_stop() {
  local hooks_dir="$1"
  local root; root="$(find_project_root)"
  cat > "$hooks_dir/devloop-stop.sh" <<'HOOK'
#!/usr/bin/env bash
# DevLoop Stop hook — logs when Claude finishes a turn
LOG="$(git rev-parse --show-toplevel 2>/dev/null)/.devloop/pipeline.log"
mkdir -p "$(dirname "$LOG")"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
INPUT="$(cat)"
STOP_REASON="$(printf '%s' "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('stop_reason','unknown'))" 2>/dev/null || echo "unknown")"
printf '[%s] Claude turn ended — stop_reason: %s\n' "$TIMESTAMP" "$STOP_REASON" >> "$LOG"
HOOK
  chmod +x "$hooks_dir/devloop-stop.sh"
}

_write_hook_subagent_stop() {
  local hooks_dir="$1"
  cat > "$hooks_dir/devloop-subagent-stop.sh" <<'HOOK'
#!/usr/bin/env bash
# DevLoop SubagentStop hook — logs when an agent (architect/reviewer) completes
LOG="$(git rev-parse --show-toplevel 2>/dev/null)/.devloop/pipeline.log"
mkdir -p "$(dirname "$LOG")"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
INPUT="$(cat)"
AGENT="$(printf '%s' "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('agent_name', d.get('subagent_name','unknown')))" 2>/dev/null || echo "unknown")"
printf '[%s] Subagent completed — agent: %s\n' "$TIMESTAMP" "$AGENT" >> "$LOG"
HOOK
  chmod +x "$hooks_dir/devloop-subagent-stop.sh"
}

_write_hook_notification() {
  local hooks_dir="$1"
  cat > "$hooks_dir/devloop-notification.sh" <<'HOOK'
#!/usr/bin/env bash
# DevLoop Notification hook — forwards Claude notifications to a log
LOG="$(git rev-parse --show-toplevel 2>/dev/null)/.devloop/notifications.log"
mkdir -p "$(dirname "$LOG")"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
INPUT="$(cat)"
MSG="$(printf '%s' "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('message',''))" 2>/dev/null || echo "$INPUT")"
printf '[%s] %s\n' "$TIMESTAMP" "$MSG" >> "$LOG"
HOOK
  chmod +x "$hooks_dir/devloop-notification.sh"
}

_write_hook_session() {
  local hooks_dir="$1"
  cat > "$hooks_dir/devloop-session.sh" <<'HOOK'
#!/usr/bin/env bash
# DevLoop SessionStart/End hook — records session boundaries
LOG="$(git rev-parse --show-toplevel 2>/dev/null)/.devloop/sessions.log"
mkdir -p "$(dirname "$LOG")"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
INPUT="$(cat)"
EVENT="$(printf '%s' "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('event','session_event'))" 2>/dev/null || echo "session_event")"
SESSION="$(printf '%s' "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('session_id','')[:8])" 2>/dev/null || echo "?")"
printf '[%s] %s session=%s\n' "$TIMESTAMP" "$EVENT" "$SESSION" >> "$LOG"
HOOK
  chmod +x "$hooks_dir/devloop-session.sh"
}

# ── Permission hook (PreToolUse — Bash) ──────────────────────────────────────

_write_hook_pre_tool_use() {
  local hooks_dir="$1"
  cat > "$hooks_dir/devloop-permission.sh" <<'HOOK'
#!/usr/bin/env bash
# devloop-permission.sh — PreToolUse hook
# Classifies Bash tool calls into: BLOCK / ALLOW / ESCALATE-to-user

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
QUEUE_DIR="$ROOT/.devloop/permission-queue"
LOG="$ROOT/.devloop/permissions.log"
PERMISSION_MODE="smart"
PERMISSION_TIMEOUT="60"

# Load just the permission config lines (safe, no side effects)
if [[ -f "$ROOT/devloop.config.sh" ]]; then
  _TMP="$(mktemp)"
  grep -E '^DEVLOOP_PERMISSION_(MODE|TIMEOUT)' "$ROOT/devloop.config.sh" > "$_TMP" 2>/dev/null || true
  source "$_TMP"
  rm -f "$_TMP"
  PERMISSION_MODE="${DEVLOOP_PERMISSION_MODE:-smart}"
  PERMISSION_TIMEOUT="${DEVLOOP_PERMISSION_TIMEOUT:-60}"
fi

mkdir -p "$QUEUE_DIR" "$(dirname "$LOG")"

_log()     { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"; }
_approve() { _log "APPROVED: [$TOOL_NAME] $1"; exit 0; }
_block()   {
  _log "BLOCKED: [$TOOL_NAME] $1"
  printf '{"decision":"block","reason":"%s"}\n' "$1"
  exit 2
}

# Parse tool call from Claude (JSON on stdin)
_INPUT="$(cat)"
_TMPF="$(mktemp)"
printf '%s' "$_INPUT" > "$_TMPF"

TOOL_NAME="$(python3 -c "
import sys, json
d = json.load(open(sys.argv[1]))
print(d.get('tool_name',''))
" "$_TMPF" 2>/dev/null || echo "")"

CMD=""
if [[ "$TOOL_NAME" == "Bash" ]]; then
  CMD="$(python3 -c "
import sys, json
d = json.load(open(sys.argv[1]))
print(d.get('tool_input', {}).get('command',''))
" "$_TMPF" 2>/dev/null || echo "")"
fi
rm -f "$_TMPF"

# ── Off / auto mode: approve everything ─────────────────────────────────────
if [[ "$PERMISSION_MODE" == "off" ]] || [[ "$PERMISSION_MODE" == "auto" ]]; then
  _approve "permission-mode=$PERMISSION_MODE"
fi

# ── Non-Bash tools: always approve (file read/write handled by acceptEdits) ─
if [[ "$TOOL_NAME" != "Bash" ]]; then
  _approve "non-bash tool"
fi

# ── Tier 1: ALWAYS BLOCK — provably destructive patterns ────────────────────
_is_always_block() {
  local c="$1"
  # rm -rf on critical paths
  echo "$c" | grep -qE 'rm\s+-[a-zA-Z]*r[a-zA-Z]*f\s+/' && return 0
  echo "$c" | grep -qE 'rm\s+-[a-zA-Z]*r[a-zA-Z]*f\s+~' && return 0
  echo "$c" | grep -qE 'rm\s+-[a-zA-Z]*r[a-zA-Z]*f\s+\$HOME' && return 0
  echo "$c" | grep -qE 'sudo\s+rm\s+-' && return 0
  # Download + execute (code injection)
  echo "$c" | grep -qE '(curl|wget)\s+[^|]+\|\s*(bash|sh|python[23]?|ruby|perl|node)\b' && return 0
  # Disk destruction
  echo "$c" | grep -qE '\bdd\b.*\bof=/dev/(sd|nvme|hd|disk)' && return 0
  echo "$c" | grep -qE '\bmkfs\b' && return 0
  # Fork bomb
  echo "$c" | grep -qE ':\s*\(\s*\)\s*\{.*\|.*:' && return 0
  # chmod 777 on system paths
  echo "$c" | grep -qE 'chmod\s+[0-9]*7[0-9]*7\s*/' && return 0
  return 1
}

# ── Tier 2: ALWAYS ALLOW — provably safe read/test/build operations ──────────
_is_always_safe() {
  local c="$1"
  # Grab just the first logical command (before pipes/semicolons)
  local first
  first="$(printf '%s' "$c" | sed 's/^[[:space:]]*//' | head -1 | sed 's/[;|&].*//')"

  # Read-only shell builtins and utilities
  echo "$first" | grep -qE '^(cat|head|tail|grep|rg|ag|find|ls|ll|la|wc|stat|file|which|type|echo|printf|pwd|whoami|date|env|printenv|uname|id|tree|diff|sort|uniq|awk|sed|jq|yq|less|more)\b' && return 0

  # Git read ops (status, log, diff, show, etc.)
  echo "$first" | grep -qE '^git\s+(status|log|diff|branch|show|remote|tag|describe|shortlog|reflog|ls-files|ls-tree|stash\s+list|rev-parse|symbolic-ref|config\s+--get)\b' && return 0

  # Git safe write ops (add, commit, checkout, stash save)
  echo "$first" | grep -qE '^git\s+(add|commit|checkout|switch|restore|stash\s+(push|pop|drop|apply)|reset\s+--(soft|mixed)|clean\s+-fd|cherry-pick|merge|rebase)\b' && return 0

  # Test runners
  echo "$first" | grep -qE '^(pytest|python3?\s+-m\s+pytest|npm\s+(test|run\s+test)|yarn\s+test|pnpm\s+test|go\s+test|cargo\s+test|jest|mocha|vitest|rspec|phpunit|mvn\s+test|gradle\s+test|dotnet\s+test)\b' && return 0

  # Build tools
  echo "$first" | grep -qE '^(make|cmake|cargo\s+(build|check|clippy|fmt)|go\s+build|npm\s+run\s+build|yarn\s+build|pnpm\s+build|tsc|vite\s+build|webpack|rollup|dotnet\s+build|mvn\s+package|gradle\s+build|swift\s+build)\b' && return 0

  # Package install from lockfile / project-scoped
  echo "$first" | grep -qE '^(npm\s+(install|ci)|yarn\s+install|pnpm\s+install|pip\s+install\s+-r\s+requirements|pip\s+install\s+-e\s+\.|poetry\s+install|pipenv\s+install|bundle\s+install|go\s+mod\s+(download|tidy)|cargo\s+fetch)\b' && return 0

  # Linting / formatting
  echo "$first" | grep -qE '^(eslint|prettier|black|ruff|flake8|pylint|mypy|rubocop|golangci-lint|clippy|shellcheck|hadolint)\b' && return 0

  # Safe file ops within typical dev dirs (mkdir, cp, mv — narrow patterns)
  echo "$first" | grep -qE '^mkdir\s+(-p\s+)?\.' && return 0

  return 1
}

# Apply tiers
if _is_always_block "$CMD"; then
  _block "Destructive command blocked by DevLoop safety policy. Run manually in terminal if needed."
fi

if _is_always_safe "$CMD"; then
  _approve "safe"
fi

# ── Tier 3: Strict mode — block everything not in safe list ─────────────────
if [[ "$PERMISSION_MODE" == "strict" ]]; then
  _block "Command not in allowed-list (DEVLOOP_PERMISSION_MODE=strict). Add to safe patterns or switch to smart mode."
fi

# ── Tier 3: Smart mode — escalate to user ───────────────────────────────────
_REQ_ID="req-$$-$(date '+%s')"
_REQ_FILE="$QUEUE_DIR/$_REQ_ID.json"
_RESP_FILE="$QUEUE_DIR/$_REQ_ID.response"
_CMD_DISPLAY="$(printf '%s' "$CMD" | head -c 400)"

python3 -c "
import sys, json
print(json.dumps({'id': sys.argv[1], 'tool': sys.argv[2], 'command': sys.argv[3], 'ts': sys.argv[4]}))
" "$_REQ_ID" "$TOOL_NAME" "$_CMD_DISPLAY" "$(date '+%Y-%m-%d %H:%M:%S')" > "$_REQ_FILE" 2>/dev/null || true

_log "PENDING: [$TOOL_NAME] $_CMD_DISPLAY → $_REQ_ID"

# ── Path A: interactive terminal (/dev/tty available) ───────────────────────
if [ -e /dev/tty ] && { printf '' > /dev/tty; } 2>/dev/null; then
  {
    printf '\n'
    printf '⚠️  DevLoop Permission Request\n'
    printf '   Tool:    %s\n' "$TOOL_NAME"
    printf '   Command: %s\n' "$(printf '%s' "$_CMD_DISPLAY" | head -c 300)"
    printf '   Allow? [y/N]: '
  } > /dev/tty
  if read -t "$PERMISSION_TIMEOUT" -r _resp < /dev/tty 2>/dev/null; then
    rm -f "$_REQ_FILE"
    case "${_resp,,}" in
      y|yes|allow) _approve "user granted via terminal" ;;
      *)           _block "user denied via terminal" ;;
    esac
  fi
fi

# ── Path B: macOS dialog (daemon / no tty) ───────────────────────────────────
if command -v osascript &>/dev/null; then
  _SHORT="$(printf '%s' "$_CMD_DISPLAY" | head -c 200 | sed "s/\"/'/g; s/\\\\/\\\\\\\\/g")"
  _mac_btn="$(osascript -e "
    set d to \"DevLoop Permission Request\n\nTool: $TOOL_NAME\nCommand: $_SHORT\n\nAllow this command?\"
    button returned of (display dialog d buttons {\"Deny\", \"Allow\"} default button \"Deny\" with icon caution giving up after $PERMISSION_TIMEOUT)
  " 2>/dev/null || echo "gave up")"
  rm -f "$_REQ_FILE"
  case "$_mac_btn" in
    Allow) _approve "user granted via macOS dialog" ;;
    *)     _block "user denied (or timed out) via macOS dialog" ;;
  esac
fi

# ── Path C: Linux notify-send + queue poll (devloop permit watch) ────────────
if command -v notify-send &>/dev/null; then
  notify-send "DevLoop Permission Request" \
    "Command: $(printf '%s' "$_CMD_DISPLAY" | head -c 100)" \
    --urgency=critical --expire-time=0 2>/dev/null || true
fi
printf '\n[DevLoop] Permission request queued: %s\nRun: devloop permit watch\n' "$_REQ_ID" > /dev/tty 2>/dev/null || true

_waited=0
while (( _waited < PERMISSION_TIMEOUT )); do
  if [[ -f "$_RESP_FILE" ]]; then
    _decision="$(cat "$_RESP_FILE")"
    rm -f "$_REQ_FILE" "$_RESP_FILE"
    case "$_decision" in
      allow) _approve "user granted via devloop permit" ;;
      *)     _block "user denied via devloop permit" ;;
    esac
  fi
  sleep 1
  (( _waited++ )) || true
done

rm -f "$_REQ_FILE"
_block "No response in ${PERMISSION_TIMEOUT}s — auto-denied for safety"
HOOK
  chmod +x "$hooks_dir/devloop-permission.sh"
}

# ── Audit hook (PostToolUse — all tools) ─────────────────────────────────────

_write_hook_post_tool_use() {
  local hooks_dir="$1"
  cat > "$hooks_dir/devloop-audit.sh" <<'HOOK'
#!/usr/bin/env bash
# devloop-audit.sh — PostToolUse hook — logs every executed tool call
LOG="$(git rev-parse --show-toplevel 2>/dev/null)/.devloop/permissions.log"
mkdir -p "$(dirname "$LOG")"
INPUT="$(cat)"
_TMPF="$(mktemp)"
printf '%s' "$INPUT" > "$_TMPF"
TOOL="$(python3 -c "import sys,json; d=json.load(open(sys.argv[1])); print(d.get('tool_name','?'))" "$_TMPF" 2>/dev/null || echo "?")"
CMD="$(python3 -c "import sys,json; d=json.load(open(sys.argv[1])); ti=d.get('tool_input',{}); print((ti.get('command') or ti.get('path',''))[:200])" "$_TMPF" 2>/dev/null || echo "")"
rm -f "$_TMPF"
printf '[%s] EXECUTED: [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$TOOL" "$CMD" >> "$LOG"
HOOK
  chmod +x "$hooks_dir/devloop-audit.sh"
}

# ── Merge hooks into existing settings.json (python3-based) ──────────────────
_merge_claude_settings_hooks() {
  local settings_file="$1"
  local hooks_dir="$2"

  python3 - "$settings_file" "$hooks_dir" <<'PY'
import sys, json, os

settings_file = sys.argv[1]
hooks_dir     = sys.argv[2]

data = {}
if os.path.exists(settings_file):
    try:
        with open(settings_file) as f:
            data = json.load(f)
    except Exception:
        pass

hooks = data.setdefault("hooks", {})

def upsert_hook(event, matcher, script):
    entries = hooks.setdefault(event, [])
    # Remove any existing DevLoop entry for this event+matcher
    entries[:] = [e for e in entries if not any(
        'devloop' in h.get('command','') for h in e.get('hooks',[])
    )]
    entries.append({
        "matcher": matcher,
        "hooks": [{"type": "command", "command": script}]
    })

upsert_hook("Stop",         "", os.path.join(hooks_dir, "devloop-stop.sh"))
upsert_hook("SubagentStop", "", os.path.join(hooks_dir, "devloop-subagent-stop.sh"))
upsert_hook("Notification", "", os.path.join(hooks_dir, "devloop-notification.sh"))
upsert_hook("SessionStart", "", os.path.join(hooks_dir, "devloop-session.sh"))
upsert_hook("SessionEnd",   "", os.path.join(hooks_dir, "devloop-session.sh"))
upsert_hook("PreToolUse",   "Bash", os.path.join(hooks_dir, "devloop-permission.sh"))
upsert_hook("PostToolUse",  "",     os.path.join(hooks_dir, "devloop-audit.sh"))

os.makedirs(os.path.dirname(os.path.abspath(settings_file)), exist_ok=True)
with open(settings_file, 'w') as f:
    json.dump(data, f, indent=2)
print("ok")
PY
}

cmd_hooks() {
  load_config
  local root; root="$(find_project_root)"
  local hooks_dir="$root/.claude/hooks"
  local settings_file="$root/.claude/settings.json"

  step "🪝 Installing DevLoop Claude hooks"
  divider

  mkdir -p "$hooks_dir"
  mkdir -p "$root/$DEVLOOP_DIR/permission-queue"

  _write_hook_stop         "$hooks_dir"
  success "Hook: ${CYAN}$hooks_dir/devloop-stop.sh${RESET}"
  _write_hook_subagent_stop "$hooks_dir"
  success "Hook: ${CYAN}$hooks_dir/devloop-subagent-stop.sh${RESET}"
  _write_hook_notification  "$hooks_dir"
  success "Hook: ${CYAN}$hooks_dir/devloop-notification.sh${RESET}"
  _write_hook_session       "$hooks_dir"
  success "Hook: ${CYAN}$hooks_dir/devloop-session.sh${RESET}"
  _write_hook_pre_tool_use  "$hooks_dir"
  success "Hook: ${CYAN}$hooks_dir/devloop-permission.sh${RESET}  ${GRAY}(PreToolUse — Bash)${RESET}"
  _write_hook_post_tool_use "$hooks_dir"
  success "Hook: ${CYAN}$hooks_dir/devloop-audit.sh${RESET}       ${GRAY}(PostToolUse — all tools)${RESET}"

  local merge_result
  merge_result="$(_merge_claude_settings_hooks "$settings_file" "$hooks_dir" 2>&1)"
  if [[ "$merge_result" == "ok" ]]; then
    success "Settings: ${CYAN}$settings_file${RESET}  ${GRAY}(hooks merged — PreToolUse + PostToolUse added)${RESET}"
  else
    warn "Could not update $settings_file: $merge_result"
  fi

  divider
  echo ""
  info "Hooks fire automatically inside Claude sessions"
  echo -e "  ${BOLD}Logs written to:${RESET}"
  echo -e "    ${CYAN}.devloop/pipeline.log${RESET}       — Claude turns + agent completions"
  echo -e "    ${CYAN}.devloop/notifications.log${RESET}  — Claude notifications"
  echo -e "    ${CYAN}.devloop/sessions.log${RESET}       — session start/end boundaries"
  echo -e "    ${CYAN}.devloop/permissions.log${RESET}    — permission decisions (allow/block/pending)"
  echo ""
  info "Permission mode: ${BOLD}${DEVLOOP_PERMISSION_MODE:-smart}${RESET}  ${GRAY}(change: DEVLOOP_PERMISSION_MODE in devloop.config.sh)${RESET}"
  echo -e "  Run ${CYAN}devloop permit watch${RESET} to handle pending requests interactively"
  echo -e "  Run ${CYAN}devloop logs${RESET} to view all logs"
  echo ""
}

# ── cmd_permit ────────────────────────────────────────────────────────────────

cmd_permit() {
  load_config
  local root; root="$(find_project_root)"
  local queue="$root/$DEVLOOP_DIR/permission-queue"
  local log="$root/$DEVLOOP_DIR/permissions.log"
  local subcmd="${1:-status}"

  case "$subcmd" in

    status)
      step "🔐 DevLoop Permissions"
      divider
      info "Mode: ${BOLD}${DEVLOOP_PERMISSION_MODE:-smart}${RESET}  timeout: ${DEVLOOP_PERMISSION_TIMEOUT:-60}s"
      echo ""
      local pending=()
      if [[ -d "$queue" ]]; then
        while IFS= read -r f; do
          [[ "$f" == *.json ]] && pending+=("$f")
        done < <(ls -1t "$queue"/*.json 2>/dev/null || true)
      fi
      if [[ ${#pending[@]} -eq 0 ]]; then
        success "No pending permission requests"
      else
        warn "${#pending[@]} pending request(s):"
        for f in "${pending[@]}"; do
          local id cmd_preview
          id="$(basename "$f" .json)"
          cmd_preview="$(python3 -c "import sys,json; d=json.load(open(sys.argv[1])); print(d.get('command','?')[:120])" "$f" 2>/dev/null || echo "?")"
          echo -e "  ${YELLOW}⏳ $id${RESET}"
          echo -e "     ${GRAY}$cmd_preview${RESET}"
        done
        echo ""
        echo -e "  Run ${CYAN}devloop permit watch${RESET} to handle interactively"
        echo -e "  Run ${CYAN}devloop permit grant${RESET} / ${CYAN}devloop permit deny${RESET} to resolve latest"
      fi
      ;;

    watch)
      step "🔐 DevLoop Permit Watch — waiting for permission requests…"
      divider
      echo -e "  ${GRAY}Press Ctrl+C to stop${RESET}"
      echo ""
      local seen=()
      while true; do
        local new_reqs=()
        if [[ -d "$queue" ]]; then
          while IFS= read -r f; do
            [[ "$f" == *.json ]] && new_reqs+=("$f")
          done < <(ls -1t "$queue"/*.json 2>/dev/null || true)
        fi
        for f in "${new_reqs[@]}"; do
          local already_seen=false
          for s in "${seen[@]}"; do [[ "$s" == "$f" ]] && already_seen=true; done
          if ! $already_seen; then
            seen+=("$f")
            local id; id="$(basename "$f" .json)"
            local resp_file="$queue/$id.response"
            local tool cmd_text ts
            tool="$(python3 -c "import sys,json; d=json.load(open(sys.argv[1])); print(d.get('tool','?'))" "$f" 2>/dev/null || echo "?")"
            cmd_text="$(python3 -c "import sys,json; d=json.load(open(sys.argv[1])); print(d.get('command','?')[:400])" "$f" 2>/dev/null || echo "?")"
            ts="$(python3 -c "import sys,json; d=json.load(open(sys.argv[1])); print(d.get('ts','?'))" "$f" 2>/dev/null || echo "?")"
            echo ""
            echo -e "${YELLOW}⚠️  Permission Request${RESET}  ${GRAY}[$ts]${RESET}"
            echo -e "   Tool:    ${BOLD}$tool${RESET}"
            echo -e "   Command: ${CYAN}$cmd_text${RESET}"
            printf '   Allow? [y/N]: '
            local _r=""
            read -t "${DEVLOOP_PERMISSION_TIMEOUT:-60}" -r _r || true
            case "${_r,,}" in
              y|yes|allow)
                echo "allow" > "$resp_file"
                success "Granted: $id"
                ;;
              *)
                echo "deny" > "$resp_file"
                warn "Denied: $id"
                ;;
            esac
          fi
        done
        sleep 0.5
      done
      ;;

    grant)
      local target="${2:-}"
      local req_file=""
      if [[ -n "$target" ]]; then
        req_file="$queue/$target.json"
      else
        req_file="$(ls -1t "$queue"/*.json 2>/dev/null | head -1 || true)"
      fi
      if [[ -z "$req_file" ]] || [[ ! -f "$req_file" ]]; then
        error "No pending request found${target:+ for: $target}"; exit 1
      fi
      local id; id="$(basename "$req_file" .json)"
      echo "allow" > "$queue/$id.response"
      success "Granted: $id"
      ;;

    deny)
      local target="${2:-}"
      local req_file=""
      if [[ -n "$target" ]]; then
        req_file="$queue/$target.json"
      else
        req_file="$(ls -1t "$queue"/*.json 2>/dev/null | head -1 || true)"
      fi
      if [[ -z "$req_file" ]] || [[ ! -f "$req_file" ]]; then
        error "No pending request found${target:+ for: $target}"; exit 1
      fi
      local id; id="$(basename "$req_file" .json)"
      echo "deny" > "$queue/$id.response"
      warn "Denied: $id"
      ;;

    log)
      if [[ -f "$log" ]]; then
        step "🔐 Permissions Log"
        divider
        tail -50 "$log"
      else
        info "No permissions log yet. Run devloop hooks first."
      fi
      ;;

    mode)
      local new_mode="${2:-}"
      case "$new_mode" in
        off|auto|smart|strict) ;;
        *) error "Valid modes: off | auto | smart | strict"; exit 1 ;;
      esac
      if [[ ! -f "$root/devloop.config.sh" ]]; then
        error "No devloop.config.sh found. Run: devloop init"; exit 1
      fi
      if grep -q 'DEVLOOP_PERMISSION_MODE' "$root/devloop.config.sh"; then
        sed -i.bak "s/^DEVLOOP_PERMISSION_MODE=.*/DEVLOOP_PERMISSION_MODE=\"$new_mode\"/" "$root/devloop.config.sh"
      else
        echo "DEVLOOP_PERMISSION_MODE=\"$new_mode\"" >> "$root/devloop.config.sh"
      fi
      rm -f "$root/devloop.config.sh.bak"
      success "Permission mode set to: ${BOLD}$new_mode${RESET}"
      info "Reinstall hooks: ${CYAN}devloop hooks${RESET}"
      ;;

    *)
      error "Unknown permit subcommand: $subcmd"
      echo "  devloop permit [status|watch|grant [id]|deny [id]|log|mode <off|auto|smart|strict>]"
      exit 1
      ;;
  esac
}

cmd_logs() {
  load_config
  local follow=false
  while [[ $# -gt 0 ]]; do
    case "$1" in -f|--follow) follow=true; shift ;; *) shift ;; esac
  done

  local root; root="$(find_project_root)"
  local log_dir="$root/$DEVLOOP_DIR"

  step "📋 DevLoop Logs"
  divider

  local logs=()
  for logname in pipeline notifications sessions; do
    local f="$log_dir/${logname}.log"
    [[ -f "$f" ]] && logs+=("$f")
  done

  if [[ ${#logs[@]} -eq 0 ]]; then
    info "No logs found yet."
    echo -e "  1. Run ${CYAN}devloop hooks${RESET} to install hooks"
    echo -e "  2. Run ${CYAN}devloop start${RESET} — logs will appear automatically"
    return
  fi

  if [[ "$follow" == true ]]; then
    info "Tailing logs (Ctrl+C to stop)..."
    tail -f "${logs[@]}"
  else
    for f in "${logs[@]}"; do
      local name; name="$(basename "$f")"
      echo -e "\n${BOLD}=== $name ===${RESET}"
      tail -40 "$f"
    done
    echo ""
    info "Use ${CYAN}devloop logs -f${RESET} for live tail"
    echo ""
  fi
}

# ── Configure (standalone wizard) ────────────────────────────────────────────

cmd_configure() {
  load_config
  ensure_dirs

  step "DevLoop Configure — interactive setup"
  divider

  if [[ ! -f "$CONFIG_PATH" ]]; then
    info "No devloop.config.sh found — running full init first..."
    cmd_init --configure
    return
  fi

  info "Current config: ${CYAN}$CONFIG_PATH${RESET}"
  _setup_wizard "$CONFIG_PATH"

  # After wizard, reload and regenerate agents with new model settings
  load_config
  write_agent_orchestrator 2>/dev/null || true
  write_agent_architect "${CLAUDE_MAIN_MODEL:-${CLAUDE_MODEL:-sonnet}}" 2>/dev/null || true
  write_agent_reviewer   "${CLAUDE_MAIN_MODEL:-${CLAUDE_MODEL:-sonnet}}" 2>/dev/null || true
  success "Configuration saved and agent prompts updated"
  echo ""
  echo -e "  Run ${CYAN}devloop hooks${RESET} to re-install permission hooks with new settings"
  echo -e "  Run ${CYAN}devloop status${RESET} to confirm active providers and models"
  echo ""
}

# ── Doctor ────────────────────────────────────────────────────────────────────

cmd_doctor() {
  load_config
  step "🩺 DevLoop Doctor"
  divider

  local pass=0 fail=0

  _chk() {
    local label="$1"
    local ok="$2"
    local hint="${3:-}"
    if [[ "$ok" == "true" ]]; then
      echo -e "  ${GREEN}✔${RESET}  $label"
      pass=$(( pass + 1 ))
    else
      echo -e "  ${RED}✖${RESET}  $label"
      [[ -n "$hint" ]] && echo -e "       ${GRAY}→ $hint${RESET}"
      fail=$(( fail + 1 ))
    fi
  }

  local root; root="$(find_project_root)"

  # Tools
  local ok
  ok="false"; command -v claude   &>/dev/null && ok="true"
  _chk "claude CLI installed"   "$ok" "curl -fsSL https://claude.ai/install.sh | bash"
  ok="false"; command -v copilot &>/dev/null && ok="true"
  _chk "copilot CLI installed"  "$ok" "npm install -g @github/copilot"
  ok="false"; command -v gh      &>/dev/null && ok="true"
  _chk "gh CLI installed"       "$ok" "https://cli.github.com"
  ok="false"; command -v git     &>/dev/null && ok="true"
  _chk "git installed"          "$ok" "https://git-scm.com"

  # Optional worker CLIs
  echo -e "\n  ${BOLD}Optional Worker Providers${RESET}"
  ok="false"; command -v opencode &>/dev/null && ok="true"
  _chk "opencode CLI (optional worker)" "$ok" "npm install -g opencode-ai  or  https://opencode.ai"
  ok="false"; command -v pi &>/dev/null && ok="true"
  _chk "pi CLI (optional worker)"       "$ok" "https://pi.dev/docs/latest"

  # Repo
  ok="false"; git rev-parse --git-dir &>/dev/null 2>&1 && ok="true"
  _chk "inside a git repo" "$ok" "git init"

  # Config + generated files
  ok="false"; [[ -f "$CONFIG_PATH" ]] && ok="true"
  _chk "devloop.config.sh present" "$ok" "devloop init"

  ok="false"; [[ -f "$root/CLAUDE.md" ]] && ok="true"
  _chk "CLAUDE.md present" "$ok" "devloop init"

  ok="false"; [[ -f "$root/.github/copilot-instructions.md" ]] && ok="true"
  _chk ".github/copilot-instructions.md present" "$ok" "devloop init"

  for agent in devloop-orchestrator devloop-architect devloop-reviewer; do
    ok="false"; [[ -f "$root/$AGENTS_DIR/$agent.md" ]] && ok="true"
    _chk "agent: $agent" "$ok" "devloop init"
  done

  # Hooks
  ok="false"; [[ -f "$root/.claude/settings.json" ]] && grep -q 'devloop-stop' "$root/.claude/settings.json" 2>/dev/null && ok="true"
  _chk "Claude hooks installed (.claude/settings.json)" "$ok" "devloop hooks"
  ok="false"; [[ -f "$root/.claude/settings.json" ]] && grep -q 'devloop-permission' "$root/.claude/settings.json" 2>/dev/null && ok="true"
  _chk "Permission hook installed (PreToolUse → devloop-permission.sh)" "$ok" "devloop hooks"
  ok="false"; [[ -f "$root/.claude/hooks/devloop-permission.sh" ]] && ok="true"
  _chk "Permission hook script exists" "$ok" "devloop hooks"

  # Tools
  echo -e "\n  ${BOLD}Tools${RESET}"
  local project_mcp_count=0
  [[ -f "$root/.mcp.json" ]] && project_mcp_count="$(python3 -c "import json; d=json.load(open('$root/.mcp.json')); print(len(d.get('mcpServers',{})))" 2>/dev/null || echo 0)"
  local global_mcp_count=0
  [[ -f "$HOME/.claude.json" ]] && global_mcp_count="$(python3 -c "import json; d=json.load(open('$HOME/.claude.json')); print(len(d.get('mcpServers',{})))" 2>/dev/null || echo 0)"
  echo -e "  ${GRAY}—${RESET}  MCP servers: ${CYAN}$global_mcp_count${RESET} global  /  ${CYAN}$project_mcp_count${RESET} project"

  local vscode_mcp_count=0
  [[ -f "$root/.vscode/mcp.json" ]] && vscode_mcp_count="$(python3 -c "import json; d=json.load(open('$root/.vscode/mcp.json')); print(len(d.get('servers',{})))" 2>/dev/null || echo 0)"
  echo -e "  ${GRAY}—${RESET}  VS Code MCP servers (.vscode/mcp.json): ${CYAN}$vscode_mcp_count${RESET}"

  local skill_count=0
  [[ -d "$root/.claude/skills" ]] && skill_count="$(ls -1 "$root/.claude/skills" 2>/dev/null | wc -l | tr -d ' ')"
  local copilot_skill_count=0
  copilot_skill_count="$(_read_project_copilot_skills "$root" | wc -l | tr -d ' ')"
  echo -e "  ${GRAY}—${RESET}  Project skills (Claude .claude/skills/): ${CYAN}$skill_count${RESET}"
  echo -e "  ${GRAY}—${RESET}  Project skills (Copilot .github/copilot/skills + .copilot/skills): ${CYAN}$copilot_skill_count${RESET}"

  local path_instr_count=0
  [[ -d "$root/.github/instructions" ]] && path_instr_count="$(ls -1 "$root/.github/instructions/"*.instructions.md 2>/dev/null | wc -l | tr -d ' ')"
  echo -e "  ${GRAY}—${RESET}  Path-specific Copilot instructions: ${CYAN}$path_instr_count${RESET}"
  echo -e "  ${GRAY}→  Run ${CYAN}devloop tools audit${GRAY} for full details | ${CYAN}devloop tools suggest${GRAY} for recommendations${RESET}"

  # Agent docs cache status
  echo -e "\n  ${BOLD}Agent Docs${RESET}"
  local docs_dir="$root/$AGENT_DOCS_DIR"
  local main_p worker_p
  main_p="$(main_provider)"
  worker_p="$(worker_provider)"
  local chk_providers=("$main_p")
  [[ "$worker_p" != "$main_p" ]] && chk_providers+=("$worker_p")
  local any_stale=false
  for p in "${chk_providers[@]}"; do
    local cache="$docs_dir/${p}-docs.md"
    if _agent_docs_stale "$cache" 604800; then  # warn if > 7 days old
      echo -e "  ${YELLOW}⚠${RESET}  $(provider_label "$p") docs: stale or missing"
      any_stale=true
    else
      local age_h=$(( ( $(date +%s) - $(stat -f %m "$cache" 2>/dev/null || stat -c %Y "$cache" 2>/dev/null || echo 0) ) / 3600 ))
      echo -e "  ${GREEN}✔${RESET}  $(provider_label "$p") docs: cached (${age_h}h old)"
    fi
  done
  [[ "$any_stale" == "true" ]] && echo -e "     ${GRAY}→ devloop agent-sync${RESET}"

  # Version check — uses GitHub by default, no config required
  {
    local remote_ver
    if [[ -n "${DEVLOOP_VERSION_URL:-}" ]]; then
      # Custom VERSION URL
      local tmp; tmp="$(mktemp /tmp/devloop-ver.XXXXXX)"
      if command -v curl &>/dev/null && curl -fsSL "$DEVLOOP_VERSION_URL" -o "$tmp" 2>/dev/null; then
        remote_ver="$(head -1 "$tmp" | tr -d '[:space:]')"
        rm -f "$tmp"
      else
        rm -f "$tmp"
        _chk "version check (custom URL unreachable)" "false" "Check DEVLOOP_VERSION_URL"
        remote_ver=""
      fi
    else
      # Default: GitHub releases API (non-blocking — skip if slow)
      remote_ver="$( timeout 8 bash -c '_gh_latest_version 2>/dev/null' 2>/dev/null || echo "" )"
    fi
    if [[ -n "$remote_ver" ]]; then
      if [[ "$remote_ver" == "$VERSION" ]]; then
        _chk "version up to date (v$VERSION)" "true"
      else
        _chk "version up to date (local: v$VERSION, remote: v$remote_ver)" "false" "devloop update"
      fi
    else
      echo -e "  ${GRAY}—  version check skipped (no network or GitHub unreachable)${RESET}"
    fi
  }

  divider
  echo ""
  echo -e "  ${BOLD}Passed:${RESET} ${GREEN}$pass${RESET}   ${BOLD}Failed:${RESET} ${RED}$fail${RESET}"
  echo ""
  if (( fail > 0 )); then
    warn "Fix issues above, then re-run ${CYAN}devloop doctor${RESET}"
    echo ""
  else
    success "All checks passed — DevLoop is healthy"
    echo ""
  fi
}

# ── GitHub Actions CI ─────────────────────────────────────────────────────────

cmd_ci() {
  load_config
  local root; root="$(find_project_root)"
  local workflow_dir="$root/.github/workflows"
  local workflow_file="$workflow_dir/devloop-review.yml"

  step "⚙️  Generating GitHub Actions workflow"
  divider

  mkdir -p "$workflow_dir"

  if [[ -f "$workflow_file" ]]; then
    warn "$workflow_file already exists — skipping"
    info "Delete it and re-run to regenerate"
    return
  fi

  cat > "$workflow_file" <<'WORKFLOW'
name: DevLoop Review

on:
  pull_request:
    types: [opened, synchronize, reopened]

permissions:
  contents: read
  pull-requests: write

jobs:
  devloop-review:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: DevLoop Review via Claude
        uses: anthropics/claude-code-action@beta
        with:
          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
          task: |
            You are the DevLoop Reviewer. Review the changes in this pull request.

            1. Check if any .devloop/specs/*.md files exist matching recent commits.
            2. If a matching spec is found, evaluate the diff against it (spec compliance,
               edge cases, error handling, tests, SOLID principles).
            3. If no spec found, perform a general senior code review of the git diff.
            4. Post a structured review comment with:
               - Verdict: APPROVED / NEEDS_WORK / REJECTED
               - Score: X/10
               - What's Good (bullet list)
               - Issues Found (table: severity, file/area, description)
               - Required Fixes (if any)
WORKFLOW

  success "Workflow written: ${CYAN}$workflow_file${RESET}"
  echo ""
  echo -e "${BOLD}Next steps:${RESET}"
  echo -e "  1. Add ${CYAN}ANTHROPIC_API_KEY${RESET} to GitHub repo secrets"
  echo -e "  2. Commit and push the workflow file"
  echo -e "  3. Open a PR — Claude reviews it automatically"
  echo ""
}

# ── Copilot setup steps (coding agent env) ────────────────────────────────────

_write_copilot_setup_steps() {
  cat > "copilot-setup-steps.yml" <<SETUP
# copilot-setup-steps.yml
# Pre-installs tools in the Copilot coding agent's ephemeral environment.
# See: https://docs.github.com/en/copilot/customizing-copilot/customizing-the-development-environment-for-copilot-coding-agent

steps:
  # Install project dependencies — customize for your stack
  - name: Install dependencies
    run: |
      # Node.js:  npm ci
      # Python:   pip install -r requirements.txt
      # .NET:     dotnet restore
      # Go:       go mod download
      echo "Add your dependency installation steps here"

  # Install DevLoop so Copilot can call devloop commands
  - name: Install DevLoop
    run: |
      if [ -f "./devloop.sh" ]; then
        cp ./devloop.sh /usr/local/bin/devloop
        chmod +x /usr/local/bin/devloop
      fi

  # Verify environment
  - name: Verify tools
    run: |
      git --version
      # Add any other verification steps
SETUP
}

# ── Copilot coding agent work mode ────────────────────────────────────────────

_cmd_work_github_agent() {
  local id="$1"
  local spec_file="$2"

  command -v gh &>/dev/null || {
    error "gh CLI required for github-agent mode"
    echo -e "  Install: ${CYAN}https://cli.github.com${RESET}"
    exit 1
  }

  step "🤖 Copilot coding agent implementing: ${BOLD}$id${RESET}"
  divider

  local base_hash
  base_hash="$(git rev-parse HEAD 2>/dev/null || echo "")"
  if [[ -n "$base_hash" ]]; then
    echo "$base_hash" > "$SPECS_PATH/$id.pre-commit"
    info "Git baseline recorded: ${GRAY}${base_hash:0:12}${RESET}"
  fi

  local feature; feature="$(grep '^\*\*Feature\*\*:' "$spec_file" | sed 's/\*\*Feature\*\*: //' | head -1)"
  local issue_title="DevLoop $id: $feature"
  local spec_content; spec_content="$(cat "$spec_file")"

  info "Creating GitHub Issue for Copilot coding agent..."
  echo ""

  local issue_url
  issue_url="$(gh issue create \
    --title "$issue_title" \
    --body "$spec_content" \
    --label "copilot" 2>/dev/null)" || {
    error "Failed to create GitHub Issue. Verify auth: gh auth status"
    exit 1
  }

  local issue_num; issue_num="$(printf '%s' "$issue_url" | grep -o '[0-9]*$')"
  echo "$issue_url" > "$SPECS_PATH/$id.issue"

  success "Issue created: ${CYAN}$issue_url${RESET}"
  echo ""
  echo -e "${BOLD}Copilot coding agent is now working on this issue.${RESET}"
  echo -e "  You can monitor progress at: ${CYAN}$issue_url${RESET}"
  echo ""
  info "Watching for Copilot PR (up to 5 min — Ctrl+C to skip)..."

  local elapsed=0
  local max_wait=300
  while (( elapsed < max_wait )); do
    local pr_url
    pr_url="$(gh pr list --search "closes #$issue_num" --json url --jq '.[0].url' 2>/dev/null || echo "")"
    if [[ -n "$pr_url" && "$pr_url" != "null" ]]; then
      echo ""
      success "Copilot PR found: ${CYAN}$pr_url${RESET}"
      echo "$pr_url" > "$SPECS_PATH/$id.pr"
      echo ""
      echo -e "  Run: ${CYAN}devloop review $id${RESET}"
      return
    fi
    sleep 15
    elapsed=$(( elapsed + 15 ))
    printf "."
  done
  echo ""
  warn "No PR found after 5 minutes — Copilot may still be working"
  echo -e "  Check: ${CYAN}gh pr list${RESET}"
  echo -e "  When ready: ${CYAN}devloop review $id${RESET}"
}

run_provider_prompt() {
  local provider="$1"
  local prompt="$2"
  local output_file="$3"

  local attempt_provider="$provider"
  while true; do
    local tmp_out; tmp_out="$(mktemp /tmp/devloop-rpp-XXXXXX)"
    local rc=0

    case "$attempt_provider" in
      claude)
        # Architect/reviewer: read-only tools sufficient (no bash execution needed)
        local _readonly_tools="Read,Write,Glob,LS,Bash(git*),Bash(cat*),Bash(grep*),Bash(find*),Bash(ls*),Bash(wc*)"
        local _main_model="${CLAUDE_MAIN_MODEL:-${CLAUDE_MODEL:-sonnet}}"
        if ! echo "$prompt" | claude -p --model "$_main_model" --allowedTools "$_readonly_tools" > "$tmp_out" 2>&1; then
          echo "$prompt" | claude -p --model "$_main_model" > "$tmp_out" 2>&1 || rc=$?
        fi
        ;;
      copilot)
        copilot --allow-all-tools --allow-all-paths -p "$prompt" > "$tmp_out" 2>&1 || rc=$?
        ;;
      *)
        error "Unsupported provider in run_provider_prompt: $attempt_provider"
        rm -f "$tmp_out"; exit 1
        ;;
    esac

    local out_text; out_text="$(cat "$tmp_out")"

    if _is_rate_limit_error "$out_text" || (( rc == 429 )); then
      local role="main"
      local fallback; fallback="$(_fallback_main "$attempt_provider")"
      warn "$(provider_label "$attempt_provider") hit its limit — switching main to $(provider_label "${fallback:-none}")"
      if [[ -z "$fallback" ]]; then
        error "All main providers are rate-limited. Try again later."
        rm -f "$tmp_out"; exit 1
      fi
      _health_mark_limited "$role" "$fallback"
      attempt_provider="$fallback"
      rm -f "$tmp_out"
      continue
    fi

    cp "$tmp_out" "$output_file"
    rm -f "$tmp_out"

    # If we used a fallback, show a reminder
    if [[ "$attempt_provider" != "$provider" ]]; then
      info "Completed via fallback provider: $(provider_label "$attempt_provider")"
      info "Original provider $(provider_label "$provider") will be re-probed every ${DEVLOOP_PROBE_INTERVAL:-5}m until available"
    fi
    break
  done
}

# ── Embedded Agent Definitions ────────────────────────────────────────────────
# Written to .claude/agents/ by `devloop init`

# FIX #8: Added TodoWrite to orchestrator tools for per-task progress tracking
write_agent_orchestrator() {
  cat > "$AGENTS_PATH/devloop-orchestrator.md" <<'AGENT'
---
name: devloop-orchestrator
description: Main DevLoop orchestrator. Receives feature requests remotely and coordinates the architect and reviewer agents through the full build loop until approved. Provider routing can swap architect/reviewer/worker backends while Claude remains the remote-control launcher in v1.
tools: Agent(devloop-architect, devloop-reviewer), Bash, Read, Write, TodoWrite
model: sonnet
color: cyan
---

You are the DevLoop Orchestrator — the main coordinator of a three-agent development pipeline. The user sends instructions remotely from claude.ai or the Claude mobile app.

## Pipeline
```
User (remote: mobile / browser)
  → You (orchestrator, main thread)
    → @devloop-architect (subagent: designs spec)
    → Bash: devloop work  (provider-selected worker implements)
    → @devloop-reviewer   (subagent: reviews result)
    → loop until APPROVED
```

## Workflow

### On receiving a task from the user:

**Step 1 — Confirm**
Echo back what you understood. State the plan in one line.
Use TodoWrite to track: ["Architect spec", "Copilot implement", "Review", "Done"].

**Step 2 — Architect**
Mark "Architect spec" in_progress. Delegate:
```
@devloop-architect Design spec for: [feature]
Type: [feature|bugfix|refactor|test]
Files: [any file hints, or omit]
```
Wait for the Task ID (e.g. TASK-20260504-093022).
Mark "Architect spec" completed.

**Step 3 — Implement**
Mark "Copilot implement" in_progress.
Tell the user: "📐 Spec ready. Launching the configured worker to implement..."
Run:
```bash
devloop work TASK-ID
```
Mark "Copilot implement" completed.

**Step 4 — Review**
Mark "Review" in_progress.
```
@devloop-reviewer Review task: TASK-ID
```
Mark "Review" completed.

**Step 5 — Handle verdict**
- **APPROVED** → Mark "Done" completed. Summarize what was built. ✅
- **NEEDS_WORK** → Run `devloop fix TASK-ID`, re-delegate to reviewer. Repeat up to 3 times.
- **REJECTED** → Report with reasons. Ask if user wants to restart.

## Phase indicators
- 📐 Designing spec...
- 🤖 Copilot implementing...
- 🔍 Reviewing implementation...
- ✅ Approved!
- ⚠️ Needs fixes — looping...
- ❌ Rejected

## Error handling
- `devloop: not found` → tell user: `sudo devloop install`
- `copilot: not found` → tell user: `npm install -g @github/copilot`
- No git changes after work → ask user to confirm Copilot finished

## Mobile push notifications
When starting a long task, include in your first message: "I'll notify you when this task completes."
Claude Code will push a notification to your phone when the task finishes.
AGENT
}

# FIX #5: Dynamic model — split front matter (variable-expanded) from body (quoted heredoc)
write_agent_architect() {
  local model="${1:-opus}"
  # Front matter uses unquoted heredoc so ${model} expands
  cat > "$AGENTS_PATH/devloop-architect.md" <<FRONT
---
name: devloop-architect
description: DevLoop architect. Designs precise implementation specs for Copilot. Called by orchestrator with a feature description. Returns Task ID and spec summary.
tools: Bash, Read, Glob, Grep
model: ${model}
color: blue
---
FRONT
  # Body uses quoted heredoc so $ signs are literal
  cat >> "$AGENTS_PATH/devloop-architect.md" <<'BODY'

You are the DevLoop Architect. Design precise, unambiguous specs Copilot can follow without additional context.

## On invocation

### 1. Load project context
```bash
cat devloop.config.sh 2>/dev/null
cat CLAUDE.md 2>/dev/null
```

### 2. Explore relevant files
Read files mentioned in the task. Check existing patterns.

### 3. Generate the spec
```bash
devloop architect "[feature]" [type] "[file hints]"
```

### 4. Return to orchestrator
- Task ID (e.g. `TASK-20260504-093022`)
- 2-sentence summary of what the spec covers
- Key signatures from the spec

## Spec requirements
- Exact method signatures with full types
- Explicit business rules
- All edge cases enumerated
- Test scenarios in table format
- Copilot Instructions Block included
BODY
}

# FIX #5: Dynamic model for reviewer too
write_agent_reviewer() {
  local model="${1:-sonnet}"
  cat > "$AGENTS_PATH/devloop-reviewer.md" <<FRONT
---
name: devloop-reviewer
description: DevLoop reviewer. Reviews Copilot's implementation against the task spec via git diff. Returns APPROVED, NEEDS_WORK, or REJECTED with specific issues and fix instructions.
tools: Bash, Read, Glob, Grep
model: ${model}
color: yellow
---
FRONT
  cat >> "$AGENTS_PATH/devloop-reviewer.md" <<'BODY'

You are the DevLoop Reviewer. Rigorously check Copilot's implementation against the original spec.

## On invocation

### 1. Load spec
```bash
devloop status TASK-ID
```

### 2. Run review
```bash
devloop review TASK-ID
```

### 3. Return to orchestrator
- Verdict: APPROVED / NEEDS_WORK / REJECTED
- Score: X/10
- What passed
- Issues (file, area, severity, description)
- Copilot Fix Instructions block (if NEEDS_WORK)

## Criteria (priority order)
1. Spec compliance
2. Correctness / edge cases
3. Error handling
4. Code quality (SOLID)
5. Security
6. Test coverage

## Verdicts
- **APPROVED**: all spec items done, no CRITICAL/HIGH, tests present
- **NEEDS_WORK**: fixable gaps
- **REJECTED**: wrong approach, missing core logic, security issue

## If no git changes
Tell orchestrator: "No git changes found — ask user to confirm Copilot finished."
BODY
}

# ── cmd: install ──────────────────────────────────────────────────────────────

cmd_install() {
  local target="${1:-/usr/local/bin/devloop}"
  local script
  script="$(readlink -f "$0")"

  if [[ "$script" == "$target" ]]; then
    success "Already installed at $target"
    return
  fi

  echo -e "${BOLD}Installing devloop to $target${RESET}"

  if [[ -w "$(dirname "$target")" ]]; then
    cp "$script" "$target"
    chmod +x "$target"
  else
    sudo cp "$script" "$target"
    sudo chmod +x "$target"
  fi

  success "Installed: ${CYAN}$target${RESET}"
  echo -e "  Run ${CYAN}devloop init${RESET} in any project to get started"
}

# ── Init helpers ───────────────────────────────────────────────────────────────

# ── Interactive setup wizard ───────────────────────────────────────────────────
# Asks the user to choose providers, models, and permission mode.
# Writes choices directly into the given config file.
# Usage: _setup_wizard <config_file>
_setup_wizard() {
  local cfg="$1"

  # Detect installed providers
  local has_claude="false"; command -v claude &>/dev/null && has_claude="true"
  local has_copilot="false"; command -v copilot &>/dev/null && has_copilot="true"
  local has_opencode="false"; command -v opencode &>/dev/null && has_opencode="true"
  local has_pi="false"; command -v pi &>/dev/null && has_pi="true"

  _avail() { [[ "$1" == "true" ]] && echo "${GREEN}✔ installed${RESET}" || echo "${YELLOW}⚠  not found${RESET}"; }

  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}  DevLoop Setup Wizard${RESET}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""
  echo -e "  Detected providers:"
  echo -e "    claude   $(_avail "$has_claude")"
  echo -e "    copilot  $(_avail "$has_copilot")"
  echo -e "    opencode $(_avail "$has_opencode")"
  echo -e "    pi       $(_avail "$has_pi")"
  echo ""
  echo -e "  ${GRAY}Press Enter to accept default shown in [brackets]${RESET}"
  echo ""

  # ── Step 1: Main provider ────────────────────────────────────────────────────
  echo -e "${BOLD}Step 1/4 — Main provider${RESET}"
  echo -e "  The main provider runs the ${CYAN}orchestrator${RESET}, ${CYAN}architect${RESET}, and ${CYAN}reviewer${RESET}."
  echo -e "  It must support remote control (mobile/browser → terminal handoff)."
  echo ""
  echo -e "  1) claude   — Claude Code CLI  $(_avail "$has_claude")"
  echo -e "  2) copilot  — GitHub Copilot   $(_avail "$has_copilot")"
  echo ""
  local main_default="claude"
  [[ "$has_claude" == "false" && "$has_copilot" == "true" ]] && main_default="copilot"
  local wiz_main=""
  while [[ -z "$wiz_main" ]]; do
    printf "  Choose main provider [${BOLD}%s${RESET}]: " "$main_default"
    local _inp=""
    read -r _inp 2>/dev/null </dev/tty || _inp=""
    _inp="${_inp:-$main_default}"
    case "$_inp" in
      1|claude)  wiz_main="claude" ;;
      2|copilot) wiz_main="copilot" ;;
      *) echo -e "  ${RED}Invalid — enter 1 (claude) or 2 (copilot)${RESET}" ;;
    esac
  done
  echo -e "  ${GREEN}✔${RESET} Main provider: ${BOLD}$wiz_main${RESET}"
  echo ""

  # ── Step 2: Worker provider ──────────────────────────────────────────────────
  echo -e "${BOLD}Step 2/4 — Worker provider${RESET}"
  echo -e "  The worker executes ${CYAN}work${RESET} and ${CYAN}fix${RESET} tasks (implements the code)."
  echo -e "  All providers are supported here."
  echo ""
  echo -e "  1) copilot  — GitHub Copilot   $(_avail "$has_copilot")"
  echo -e "  2) claude   — Claude Code CLI  $(_avail "$has_claude")"
  echo -e "  3) opencode — OpenCode         $(_avail "$has_opencode")"
  echo -e "  4) pi       — Pi               $(_avail "$has_pi")"
  echo ""
  local worker_default="copilot"
  [[ "$wiz_main" == "copilot" ]] && worker_default="claude"
  [[ "$has_copilot" == "false" && "$has_claude" == "true" ]] && worker_default="claude"
  local wiz_worker=""
  while [[ -z "$wiz_worker" ]]; do
    printf "  Choose worker provider [${BOLD}%s${RESET}]: " "$worker_default"
    local _inp=""
    read -r _inp 2>/dev/null </dev/tty || _inp=""
    _inp="${_inp:-$worker_default}"
    case "$_inp" in
      1|copilot)  wiz_worker="copilot" ;;
      2|claude)   wiz_worker="claude" ;;
      3|opencode) wiz_worker="opencode" ;;
      4|pi)       wiz_worker="pi" ;;
      *) echo -e "  ${RED}Invalid — enter 1-4 or provider name${RESET}" ;;
    esac
  done
  echo -e "  ${GREEN}✔${RESET} Worker provider: ${BOLD}$wiz_worker${RESET}"
  echo ""

  # ── Step 3: Claude model(s) ──────────────────────────────────────────────────
  echo -e "${BOLD}Step 3/4 — Claude model${RESET}"
  echo -e "  Used when Claude is the main or worker provider."
  echo ""
  echo -e "  ${BOLD}Main model${RESET} (architect / reviewer / orchestrator):"
  echo -e "  1) sonnet  — balanced speed and quality  ${GRAY}[default]${RESET}"
  echo -e "  2) opus    — most capable, slower/costlier"
  echo -e "  3) haiku   — fastest and cheapest"
  echo ""
  local wiz_main_model=""
  while [[ -z "$wiz_main_model" ]]; do
    printf "  Choose main model [${BOLD}sonnet${RESET}]: "
    local _inp=""
    read -r _inp 2>/dev/null </dev/tty || _inp=""
    _inp="${_inp:-sonnet}"
    case "$_inp" in
      1|sonnet) wiz_main_model="sonnet" ;;
      2|opus)   wiz_main_model="opus" ;;
      3|haiku)  wiz_main_model="haiku" ;;
      *)
        # allow any model name (custom or future claude-* values)
        if echo "$_inp" | grep -qE '^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$'; then
          wiz_main_model="$_inp"
        else
          echo -e "  ${RED}Invalid — enter 1 (sonnet), 2 (opus), 3 (haiku), or a model name${RESET}"
        fi
        ;;
    esac
  done
  echo ""
  echo -e "  ${BOLD}Worker model${RESET} (work / fix):"
  echo -e "  1) sonnet  — balanced speed and quality  ${GRAY}[default]${RESET}"
  echo -e "  2) opus    — most capable, slower/costlier"
  echo -e "  3) haiku   — fastest and cheapest"
  echo -e "  4) same    — same as main model (${BOLD}$wiz_main_model${RESET})"
  echo ""
  local wiz_worker_model=""
  while [[ -z "$wiz_worker_model" ]]; do
    printf "  Choose worker model [${BOLD}sonnet${RESET}]: "
    local _inp=""
    read -r _inp 2>/dev/null </dev/tty || _inp=""
    _inp="${_inp:-sonnet}"
    case "$_inp" in
      1|sonnet) wiz_worker_model="sonnet" ;;
      2|opus)   wiz_worker_model="opus" ;;
      3|haiku)  wiz_worker_model="haiku" ;;
      4|same)   wiz_worker_model="$wiz_main_model" ;;
      *)
        if echo "$_inp" | grep -qE '^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$'; then
          wiz_worker_model="$_inp"
        else
          echo -e "  ${RED}Invalid — enter 1-4 or a model name${RESET}"
        fi
        ;;
    esac
  done
  echo -e "  ${GREEN}✔${RESET} Main model: ${BOLD}$wiz_main_model${RESET} | Worker model: ${BOLD}$wiz_worker_model${RESET}"
  echo ""

  # ── Step 4: Permission mode ──────────────────────────────────────────────────
  echo -e "${BOLD}Step 4/4 — Permission mode${RESET}"
  echo -e "  Controls how devloop handles Bash commands from AI agents."
  echo ""
  echo -e "  1) smart  — block dangerous, allow safe, ask user for unknowns  ${GRAY}[default]${RESET}"
  echo -e "  2) auto   — allow everything (fastest, no interruptions)"
  echo -e "  3) strict — allow only known-safe ops, block + ask for the rest"
  echo -e "  4) off    — disable hook (Claude's built-in behaviour)"
  echo ""
  local wiz_perm=""
  while [[ -z "$wiz_perm" ]]; do
    printf "  Choose permission mode [${BOLD}smart${RESET}]: "
    local _inp=""
    read -r _inp 2>/dev/null </dev/tty || _inp=""
    _inp="${_inp:-smart}"
    case "$_inp" in
      1|smart)  wiz_perm="smart" ;;
      2|auto)   wiz_perm="auto" ;;
      3|strict) wiz_perm="strict" ;;
      4|off)    wiz_perm="off" ;;
      *) echo -e "  ${RED}Invalid — enter 1-4 or: smart, auto, strict, off${RESET}" ;;
    esac
  done
  echo -e "  ${GREEN}✔${RESET} Permission mode: ${BOLD}$wiz_perm${RESET}"
  echo ""

  # ── Summary ──────────────────────────────────────────────────────────────────
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "  ${BOLD}Your selections:${RESET}"
  echo -e "  Main provider:  ${CYAN}$wiz_main${RESET}"
  echo -e "  Worker provider: ${CYAN}$wiz_worker${RESET}"
  echo -e "  Claude main model:   ${CYAN}$wiz_main_model${RESET}"
  echo -e "  Claude worker model: ${CYAN}$wiz_worker_model${RESET}"
  echo -e "  Permission mode: ${CYAN}$wiz_perm${RESET}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""
  printf "  Save to %s? [${BOLD}Y/n${RESET}]: " "$cfg"
  local _confirm=""
  read -r _confirm 2>/dev/null </dev/tty || _confirm=""
  _confirm="${_confirm:-y}"
  if [[ "$_confirm" =~ ^[Nn] ]]; then
    warn "Wizard cancelled — keeping existing config"
    return 0
  fi

  # ── Write into config file ────────────────────────────────────────────────────
  # Use sed/python to update the values in-place (config already exists from _write_default_config)
  _wizard_set_config "$cfg" "DEVLOOP_MAIN_PROVIDER"    "$wiz_main"
  _wizard_set_config "$cfg" "DEVLOOP_WORKER_PROVIDER"  "$wiz_worker"
  _wizard_set_config "$cfg" "CLAUDE_MODEL"             "$wiz_main_model"
  _wizard_set_config "$cfg" "CLAUDE_MAIN_MODEL"        "$wiz_main_model"
  _wizard_set_config "$cfg" "CLAUDE_WORKER_MODEL"      "$wiz_worker_model"
  _wizard_set_config "$cfg" "DEVLOOP_PERMISSION_MODE"  "$wiz_perm"

  success "Saved preferences to ${CYAN}$cfg${RESET}"
  echo ""
}

# Set or add a key=value line in a config file.
_wizard_set_config() {
  local file="$1"
  local key="$2"
  local val="$3"
  # If key exists (even commented out), update it; otherwise append
  if grep -qE "^[[:space:]#]*${key}=" "$file" 2>/dev/null; then
    # Replace the line (uncomment + set value)
    python3 - "$file" "$key" "$val" <<'PYEOF'
import sys, re
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    lines = f.readlines()
out = []
replaced = False
for line in lines:
    if re.match(r'^[[:space:]#]*' + re.escape(key) + r'=', line) if False else re.match(r'^\s*#?\s*' + re.escape(key) + r'=', line):
        out.append(f'{key}="{val}"\n')
        replaced = True
    else:
        out.append(line)
if not replaced:
    out.append(f'{key}="{val}"\n')
with open(path, 'w') as f:
    f.writelines(out)
PYEOF
  else
    echo "${key}=\"${val}\"" >> "$file"
  fi
}


_write_default_config() {
  local target="$1"
  cat > "$target" <<'CONFIG'
# DevLoop Project Configuration — edit to match your stack

PROJECT_NAME="$(basename "$PWD")"
PROJECT_STACK="C#, .NET 8, ASP.NET Web API, MSSQL"
PROJECT_PATTERNS="SOLID, Repository Pattern, Clean Architecture"
PROJECT_CONVENTIONS="async/await throughout, custom exception classes, no magic strings, XML doc comments on public APIs"
TEST_FRAMEWORK="xUnit"

# Provider routing
# main  = orchestrator / architect / reviewer (requires remote control: claude | copilot)
# worker = work / fix (any CLI provider: claude | copilot | opencode | pi)
# opencode and pi are worker-only — they have no remote-control support
DEVLOOP_MAIN_PROVIDER="claude"
DEVLOOP_WORKER_PROVIDER="copilot"

# Auto-failover: when a provider hits its rate limit, DevLoop automatically
# switches to the next provider in the chain and restores as soon as available.
# Main chain:   claude → copilot
# Worker chain: copilot → opencode → pi
DEVLOOP_FAILOVER_ENABLED="true"
DEVLOOP_PROBE_INTERVAL="5"   # minutes between availability probes on limited providers

# Smart permission system
# smart  — BLOCK dangerous, ALLOW safe ops, ESCALATE unknown to user (default)
# auto   — ALLOW everything (fastest, no interruptions to the pipeline)
# strict — ALLOW only known-safe ops, BLOCK everything else
# off    — disable permission hook (Claude's built-in behaviour applies)
DEVLOOP_PERMISSION_MODE="smart"
DEVLOOP_PERMISSION_TIMEOUT="60"  # seconds to wait for user response before auto-deny

# Worker mode
# cli          — use copilot or claude CLI locally (default)
# github-agent — create a GitHub Issue; Copilot coding agent works on it and opens a PR
DEVLOOP_WORKER_MODE="cli"

# Claude model settings
# CLAUDE_MODEL is the base default used by all Claude roles.
# Override per-role to use different models for main (architect/reviewer) vs worker.
#   "sonnet" = faster/cheaper   "opus" = more capable   "haiku" = fastest
CLAUDE_MODEL="sonnet"
# CLAUDE_MAIN_MODEL="opus"     # architect, reviewer, orchestrator (uncomment to override)
# CLAUDE_WORKER_MODEL="sonnet" # worker and fix passes (uncomment to override)

# Copilot model: the Copilot CLI does not expose a --model flag for non-interactive use.
# The model is determined by your GitHub Copilot subscription and plan settings.
# To change the Copilot model, update it in: https://github.com/settings/copilot

# Version checks and self-update use GitHub by default (no config needed).
# DEVLOOP_GITHUB_REPO="shaifulshabuj/devloop"   # override to use a fork
# Override with a custom VERSION file URL (plain semver text):
# DEVLOOP_VERSION_URL="https://raw.githubusercontent.com/you/devloop/main/VERSION"
# Override with a custom script URL for 'devloop update':
# DEVLOOP_SOURCE_URL="https://raw.githubusercontent.com/you/devloop/main/devloop.sh"
CONFIG
}

_merge_devloop_config_defaults() {
  local file="$1"
  local additions=""
  local added=0
  local -a entries=(
    'PROJECT_NAME="$(basename "$PWD")"'
    'PROJECT_STACK="C#, .NET 8, ASP.NET Web API, MSSQL"'
    'PROJECT_PATTERNS="SOLID, Repository Pattern, Clean Architecture"'
    'PROJECT_CONVENTIONS="async/await throughout, custom exception classes, no magic strings, XML doc comments on public APIs"'
    'TEST_FRAMEWORK="xUnit"'
    'DEVLOOP_MAIN_PROVIDER="claude"'
    'DEVLOOP_WORKER_PROVIDER="copilot"'
    'DEVLOOP_FAILOVER_ENABLED="true"'
    'DEVLOOP_PROBE_INTERVAL="5"'
    'DEVLOOP_PERMISSION_MODE="smart"'
    'DEVLOOP_PERMISSION_TIMEOUT="60"'
    'DEVLOOP_WORKER_MODE="cli"'
    'CLAUDE_MODEL="sonnet"'
    'CLAUDE_MAIN_MODEL=""'
    'CLAUDE_WORKER_MODEL=""'
  )

  for entry in "${entries[@]}"; do
    local key="${entry%%=*}"
    if ! grep -qE "^[[:space:]]*${key}=" "$file"; then
      additions+="$entry"$'\n'
      added=$((added + 1))
    fi
  done

  if (( added > 0 )); then
    {
      echo ""
      echo "# Added by devloop init (missing defaults)"
      printf "%s" "$additions"
    } >> "$file"
  fi

  echo "$added"
}

_read_config_value() {
  local file="$1" key="$2"
  local line
  line="$(grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | head -1 || true)"
  line="${line#*=}"
  line="${line#\"}"
  line="${line%\"}"
  printf '%s' "$line"
}

_is_placeholder_config_value() {
  local key="$1" value="$2"
  case "$key" in
    PROJECT_STACK)
      [[ -z "$value" || "$value" == "Unknown stack" || "$value" == "C#, .NET 8, ASP.NET Web API, MSSQL" ]]
      ;;
    PROJECT_PATTERNS)
      [[ -z "$value" || "$value" == "SOLID, Repository Pattern, Clean Architecture" ]]
      ;;
    PROJECT_CONVENTIONS)
      [[ -z "$value" || "$value" == "async/await throughout, custom exception classes, no magic strings, XML doc comments on public APIs" || "$value" == "Use async/await, handle all errors explicitly" ]]
      ;;
    TEST_FRAMEWORK)
      [[ -z "$value" || "$value" == "default" || "$value" == "xUnit" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

_set_config_value() {
  local file="$1" key="$2" value="$3"
  python3 - "$file" "$key" "$value" <<'PYEOF'
import re
import sys

path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as f:
    lines = f.read().splitlines()

pattern = re.compile(r"^\s*" + re.escape(key) + r"=")
replacement = f'{key}="{value}"'
updated = False
for idx, line in enumerate(lines):
    if pattern.match(line):
        lines[idx] = replacement
        updated = True
        break

if not updated:
    lines.append(replacement)

with open(path, "w", encoding="utf-8") as f:
    f.write("\n".join(lines).rstrip() + "\n")
PYEOF
}

_detect_project_config_local() {
  local root="$1"
  python3 - "$root" <<'PYEOF'
import json
import os
import re
import sys

root = sys.argv[1]
skip_dirs = {
    ".git", "node_modules", "dist", "build", "target", "bin", "obj",
    ".venv", "venv", ".next", ".nuxt", ".devloop", ".claude"
}

files = set()
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in skip_dirs]
    for fn in filenames:
        rel = os.path.relpath(os.path.join(dirpath, fn), root)
        files.add(rel.replace("\\", "/"))

def has(pattern):
    rx = re.compile(pattern)
    return any(rx.search(p) for p in files)

def read_file(path):
    try:
        with open(os.path.join(root, path), "r", encoding="utf-8") as f:
            return f.read()
    except Exception:
        return ""

langs = []
frameworks = []
dbs = []
patterns = []
conventions = []
test_framework = "default"

pkg_json = read_file("package.json")
if "package.json" in files:
    langs.append("Node.js")
    if re.search(r'"next"\s*:', pkg_json): frameworks.append("Next.js")
    elif re.search(r'"react"\s*:', pkg_json): frameworks.append("React")
    if re.search(r'"nestjs|@nestjs/', pkg_json): frameworks.append("NestJS")
    if re.search(r'"express"\s*:', pkg_json): frameworks.append("Express")
    if re.search(r'"vue"\s*:', pkg_json): frameworks.append("Vue")
    if re.search(r'"svelte"\s*:', pkg_json): frameworks.append("Svelte")
    if re.search(r'"typescript"\s*:', pkg_json) or "tsconfig.json" in files:
        langs.append("TypeScript")
    else:
        langs.append("JavaScript")
    if re.search(r'"vitest"\s*:', pkg_json): test_framework = "Vitest"
    elif re.search(r'"jest"\s*:', pkg_json): test_framework = "Jest"
    elif re.search(r'"mocha"\s*:', pkg_json): test_framework = "Mocha"
    elif re.search(r'"playwright"\s*:', pkg_json): test_framework = "Playwright"

if "pyproject.toml" in files or "requirements.txt" in files or has(r"\.py$"):
    langs.append("Python")
    pyproject = read_file("pyproject.toml")
    req = read_file("requirements.txt")
    blob = pyproject + "\n" + req
    if re.search(r"\bfastapi\b", blob, re.I): frameworks.append("FastAPI")
    elif re.search(r"\bdjango\b", blob, re.I): frameworks.append("Django")
    elif re.search(r"\bflask\b", blob, re.I): frameworks.append("Flask")
    if re.search(r"\bpytest\b", blob, re.I) or has(r"(^|/)test_.*\.py$") or has(r".*_test\.py$"):
        test_framework = "pytest"
    elif test_framework == "default":
        test_framework = "unittest"

if "go.mod" in files:
    langs.append("Go")
    gomod = read_file("go.mod")
    if re.search(r"\bgin-gonic/gin\b", gomod): frameworks.append("Gin")
    elif re.search(r"\blabstack/echo\b", gomod): frameworks.append("Echo")
    elif re.search(r"\bgofiber/fiber\b", gomod): frameworks.append("Fiber")
    if test_framework == "default":
        test_framework = "go test"

if "Cargo.toml" in files:
    langs.append("Rust")
    cargo = read_file("Cargo.toml")
    if re.search(r"\baxum\b", cargo): frameworks.append("Axum")
    elif re.search(r"\bactix-web\b", cargo): frameworks.append("Actix Web")
    if test_framework == "default":
        test_framework = "cargo test"

if has(r"\.csproj$") or "global.json" in files:
    langs.append("C#")
    frameworks.append(".NET")
    if has(r"Controllers/.*\.cs$") or has(r"Program\.cs$"):
        frameworks.append("ASP.NET")
    if test_framework == "default":
        test_framework = "xUnit"

if has(r"\.java$") or "pom.xml" in files or "build.gradle" in files:
    langs.append("Java")
    if "pom.xml" in files:
        frameworks.append("Maven")
    if "build.gradle" in files:
        frameworks.append("Gradle")
    if test_framework == "default":
        test_framework = "JUnit"

if "docker-compose.yml" in files or "docker-compose.yaml" in files:
    frameworks.append("Docker")
if has(r"Dockerfile$"):
    frameworks.append("Docker")

if "prisma/schema.prisma" in files:
    dbs.append("Prisma")
if has(r"(postgres|postgresql)"):
    dbs.append("PostgreSQL")
if has(r"mysql"):
    dbs.append("MySQL")
if has(r"sqlite"):
    dbs.append("SQLite")
if has(r"mssql|sqlserver"):
    dbs.append("MSSQL")
if has(r"redis"):
    dbs.append("Redis")

if has(r"src/.*/(service|repository|controller)") or has(r"(service|repository|controller)\."):
    patterns.extend(["SOLID", "Repository Pattern"])
if has(r"domain/|application/|infrastructure/|clean"):
    patterns.append("Clean Architecture")
if not patterns:
    patterns = ["SOLID", "Clean Architecture"]

if "TypeScript" in langs:
    conventions.extend(["strict typing", "explicit error handling", "avoid any"])
elif "Python" in langs:
    conventions.extend(["type hints", "custom exceptions", "explicit error handling"])
elif "Go" in langs:
    conventions.extend(["explicit error checks", "small interfaces", "idiomatic packages"])
elif "C#" in langs:
    conventions.extend(["async/await throughout", "custom exceptions", "no magic strings"])
else:
    conventions.extend(["explicit error handling", "small focused modules"])

def uniq(xs):
    out = []
    seen = set()
    for x in xs:
        if x and x not in seen:
            seen.add(x)
            out.append(x)
    return out

langs = uniq(langs)
frameworks = uniq(frameworks)
dbs = uniq(dbs)
patterns = uniq(patterns)
conventions = uniq(conventions)

stack_parts = langs + frameworks + dbs
if not stack_parts:
    stack_parts = ["Unknown stack"]

data = {
    "PROJECT_STACK": ", ".join(stack_parts[:6]),
    "PROJECT_PATTERNS": ", ".join(patterns[:4]),
    "PROJECT_CONVENTIONS": ", ".join(conventions[:4]),
    "TEST_FRAMEWORK": test_framework if test_framework != "default" else "default",
}
print(json.dumps(data))
PYEOF
}

_auto_config_from_project() {
  local file="$1" root="$2"
  local detected_json
  detected_json="$(_detect_project_config_local "$root" 2>/dev/null || true)"
  [[ -z "$detected_json" ]] && { echo "0"; return; }

  local updates=0
  local keys=(PROJECT_STACK PROJECT_PATTERNS PROJECT_CONVENTIONS TEST_FRAMEWORK)
  for key in "${keys[@]}"; do
    local current detected
    current="$(_read_config_value "$file" "$key")"
    detected="$(python3 - "$detected_json" "$key" <<'PYEOF'
import json
import sys
data = json.loads(sys.argv[1])
print(data.get(sys.argv[2], ""))
PYEOF
)"

    if [[ -n "$detected" ]] && _is_placeholder_config_value "$key" "$current"; then
      if [[ "$current" != "$detected" ]]; then
        _set_config_value "$file" "$key" "$detected"
        updates=$((updates + 1))
      fi
    fi
  done

  echo "$updates"
}

_upsert_managed_block() {
  local file="$1" start_marker="$2" end_marker="$3" incoming_content="$4"
  python3 - "$file" "$start_marker" "$end_marker" "$incoming_content" <<'PYEOF'
import os
import sys

path, start, end, incoming = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].strip()
if incoming:
    incoming += "\n"

if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
else:
    text = ""

if not text:
    new_text = incoming
else:
    s = text.find(start)
    e = text.find(end)
    if s != -1 and e != -1 and e > s:
      e = e + len(end)
      prefix = text[:s].rstrip()
      suffix = text[e:].lstrip()
      parts = []
      if prefix:
          parts.append(prefix)
      if incoming:
          parts.append(incoming.strip())
      if suffix:
          parts.append(suffix)
      new_text = "\n\n".join(parts).rstrip() + "\n"
    else:
      new_text = text.rstrip() + "\n\n" + incoming

with open(path, "w", encoding="utf-8") as f:
    f.write(new_text)
PYEOF
}

_render_claude_managed_block() {
  cat <<'CLAUDEMD'
<!-- DEVLOOP:CLAUDE:START -->
# Claude Code — DevLoop Project

## System
This project uses the DevLoop multi-agent pipeline:
- `devloop-orchestrator` — main thread, receives remote instructions
- `devloop-architect`    — subagent, designs implementation specs
- `devloop-reviewer`     — subagent, reviews the worker's implementation
- Worker — implements specs (CLI or cloud Copilot coding agent)
- Provider routing and worker mode are controlled in `devloop.config.sh`

## Start the system
```bash
devloop start
```
Then connect from claude.ai/code or the Claude mobile app (when main provider is claude).
If main provider is copilot, the session runs locally in the terminal.

## DevLoop commands — Quick (full pipeline in one shot)
- `devloop run "feature"`       — **full pipeline**: architect → work → review → fix loop → learn
- `devloop go  "feature"`       — alias for run
- `devloop queue add "task"`    — add to batch queue
- `devloop queue run`           — process all queued tasks sequentially

## DevLoop commands — Step-by-step
- `devloop architect "feature"` — design a spec
- `devloop work [TASK-ID]`      — launch worker to implement
- `devloop review [TASK-ID]`    — review implementation
- `devloop fix [TASK-ID]`       — launch worker with fix instructions

## DevLoop commands — Management
- `devloop tasks`               — list all specs
- `devloop status [TASK-ID]`    — show spec + review
- `devloop open [TASK-ID]`      — open spec in $EDITOR
- `devloop block [TASK-ID]`     — print Copilot Instructions Block
- `devloop clean [--days N]`    — remove old specs
- `devloop learn [TASK-ID]`     — extract lessons from review and save to CLAUDE.md
- `devloop agent-sync`          — refresh provider docs cache + analyse with AI (24h TTL)
- `devloop hooks`               — install Claude pipeline hooks
- `devloop logs [TYPE]`         — show pipeline/notification/session logs
- `devloop doctor`              — validate dependencies and configuration
- `devloop ci`                  — generate GitHub Actions review workflow
- `devloop check`               — check for DevLoop updates (works out-of-the-box)
- `devloop update`              — self-upgrade devloop (pulls from GitHub, refreshes project configs)

## Agent Provider Context
_See `.devloop/agent-docs/provider-context.md` for the full provider reference._
_Run `devloop agent-sync` to refresh docs and check for provider updates._

## Stack
See devloop.config.sh for project-specific stack details.

## Learned Patterns
<!-- devloop learn appends dated lessons here -->
<!-- DEVLOOP:CLAUDE:END -->
CLAUDEMD
}

# ── cmd: init ────────────────────────────────────────────────────────────────

cmd_init() {
  # Parse flags: --yes/-y skips wizard; --configure/-c forces wizard even if config exists
  local skip_wizard="false"
  local force_wizard="false"
  local _args=()
  for _a in "$@"; do
    case "$_a" in
      --yes|-y)        skip_wizard="true" ;;
      --configure|-c)  force_wizard="true" ;;
      *)               _args+=("$_a") ;;
    esac
  done
  [[ ${#_args[@]} -gt 0 ]] && set -- "${_args[@]}" || set --

  load_config
  ensure_dirs

  step "Initializing DevLoop in: ${CYAN}$(basename "$(find_project_root)")${RESET}"
  divider

  # 1. Project config
  local _is_new_config="false"
  if [[ -f "$CONFIG_PATH" ]]; then
    local added_keys
    added_keys="$(_merge_devloop_config_defaults "$CONFIG_PATH")"
    if [[ "$added_keys" -gt 0 ]]; then
      success "Merged: ${CYAN}devloop.config.sh${RESET} ${GRAY}(added ${added_keys} missing keys)${RESET}"
    else
      info "devloop.config.sh already up to date"
    fi
  else
    _write_default_config "$CONFIG_PATH"
    success "Created: ${CYAN}devloop.config.sh${RESET}"
    _is_new_config="true"
  fi

  local root
  root="$(find_project_root)"
  local detected_updates
  detected_updates="$(_auto_config_from_project "$CONFIG_PATH" "$root")"
  if [[ "${detected_updates:-0}" -gt 0 ]]; then
    success "Auto-configured: ${CYAN}devloop.config.sh${RESET} ${GRAY}(updated ${detected_updates} values from project analysis)${RESET}"
  else
    info "Project auto-config: no placeholder values needed updates"
  fi

  # Run interactive wizard if: new config (first init) OR --configure flag, AND not --yes
  if [[ "$skip_wizard" == "false" ]] && [[ "$_is_new_config" == "true" || "$force_wizard" == "true" ]]; then
    _setup_wizard "$CONFIG_PATH"
  fi

  # Reload so generated files reflect the (potentially wizard-updated) configuration
  load_config

  # 2. Write agent definitions — pass CLAUDE_MAIN_MODEL so agents stay in sync with config
  write_agent_orchestrator
  success "Agent: ${CYAN}$AGENTS_PATH/devloop-orchestrator.md${RESET}"
  write_agent_architect "${CLAUDE_MAIN_MODEL:-${CLAUDE_MODEL:-sonnet}}"
  success "Agent: ${CYAN}$AGENTS_PATH/devloop-architect.md${RESET}"
  write_agent_reviewer "${CLAUDE_MAIN_MODEL:-${CLAUDE_MODEL:-sonnet}}"
  success "Agent: ${CYAN}$AGENTS_PATH/devloop-reviewer.md${RESET}"

  # 3. CLAUDE.md
  local claude_block
  claude_block="$(_render_claude_managed_block)"
  if [[ ! -f "CLAUDE.md" ]]; then
    _upsert_managed_block "CLAUDE.md" "<!-- DEVLOOP:CLAUDE:START -->" "<!-- DEVLOOP:CLAUDE:END -->" "$claude_block"
    success "Created: ${CYAN}CLAUDE.md${RESET}"
  else
    _upsert_managed_block "CLAUDE.md" "<!-- DEVLOOP:CLAUDE:START -->" "<!-- DEVLOOP:CLAUDE:END -->" "$claude_block"
    success "Merged: ${CYAN}CLAUDE.md${RESET} ${GRAY}(updated DevLoop managed block)${RESET}"
  fi

  # 4. Copilot instructions — FIX #9 #11: rich template with stack context
  mkdir -p .github
  local copilot_block
  copilot_block="$(_write_copilot_instructions)"
  if [[ ! -f ".github/copilot-instructions.md" ]]; then
    _upsert_managed_block ".github/copilot-instructions.md" "<!-- DEVLOOP:COPILOT:START -->" "<!-- DEVLOOP:COPILOT:END -->" "$copilot_block"
    success "Created: ${CYAN}.github/copilot-instructions.md${RESET}"
  else
    _upsert_managed_block ".github/copilot-instructions.md" "<!-- DEVLOOP:COPILOT:START -->" "<!-- DEVLOOP:COPILOT:END -->" "$copilot_block"
    success "Merged: ${CYAN}.github/copilot-instructions.md${RESET} ${GRAY}(updated DevLoop managed block)${RESET}"
  fi

  # 5. copilot-setup-steps.yml (only for github-agent mode)
  if [[ "${DEVLOOP_WORKER_MODE:-cli}" == "github-agent" ]]; then
    if [[ ! -f "copilot-setup-steps.yml" ]]; then
      _write_copilot_setup_steps
      success "Created: ${CYAN}copilot-setup-steps.yml${RESET}"
    else
      warn "copilot-setup-steps.yml already exists — skipping"
    fi
  fi

  divider
  echo ""
  echo -e "${GREEN}${BOLD}✅ DevLoop initialized!${RESET}\n"
  echo -e "${BOLD}Next steps:${RESET}"
  echo -e "  1. Review ${CYAN}devloop.config.sh${RESET} (auto-generated from project analysis)"
  echo -e "  2. Run ${CYAN}devloop hooks${RESET} to install Claude pipeline hooks"
  echo -e "  3. Run ${CYAN}devloop tools suggest${RESET} for stack-specific MCP/skill recommendations"
  echo -e "  4. Run ${CYAN}devloop start${RESET} to launch the orchestrator"
  echo -e "  5. Open ${CYAN}claude.ai/code${RESET} or the Claude app and find your session"
  echo -e "  6. Send a feature request — the pipeline runs automatically"
  echo ""
}

# ── Copilot instructions writer ────────────────────────────────────────────────
# FIX #9 #11: Detailed template with live stack config values.
# Called from cmd_init. Regenerated from the analyzed project config on each init.

_write_copilot_instructions() {
  mkdir -p .github
  python3 - "$PROJECT_STACK" "$PROJECT_PATTERNS" "$PROJECT_CONVENTIONS" "$TEST_FRAMEWORK" <<'PYEOF'
import sys

stack, patterns, conventions, test_framework = sys.argv[1:5]
content = f"""<!-- DEVLOOP:COPILOT:START -->
# GitHub Copilot Instructions — DevLoop Worker

## Your Role
You are the implementation worker in the DevLoop pipeline.
Follow DEVLOOP TASK specs exactly — no improvisation on behaviour not specified in the spec.
If `DEVLOOP_WORKER_PROVIDER` is set to `claude`, DevLoop will route worker tasks through Claude instead of Copilot.

## Project Stack
- **Stack**: {stack}
- **Patterns**: {patterns}
- **Conventions**: {conventions}
- **Test framework**: {test_framework}

## Understanding the Spec
Each task spec has these sections — read all of them before writing any code:

| Section | What it contains |
|---------|-----------------|
| **Files to Touch** | Which files to CREATE or MODIFY |
| **Implementation Steps** | Exact method signatures and per-step rules |
| **Acceptance Criteria** | Checklist of what "done" looks like |
| **Edge Cases** | Non-happy-path behaviours to implement |
| **Test Scenarios** | Table of test cases to write |
| **Copilot Instructions Block** | Condensed machine-readable summary |

## Workflow
1. Read the **full** spec — especially Files to Touch, Implementation Steps, Edge Cases
2. Use `/plan` to build a step-by-step implementation checklist
3. Implement each step in order, following every rule listed
4. Write tests for every row in the Test Scenarios table
5. Run tests (`{test_framework}`) — fix failures before committing
6. Stage **all** changed files and commit in a single commit

## Commit Message Format
```
feat(TASK-ID): <one-line summary of what was implemented>
```
Example: `feat(TASK-20260506-143022): add GET /orders endpoint with date range filter`

Stage ALL changed files in a SINGLE commit with the TASK ID in the message.

## Standards
- Follow every rule listed in the spec (zero improvisation)
- Handle every edge case enumerated in the spec
- Write tests for every row in the Test Scenarios table
- Never skip error handling
- Do not add unrequested features or refactor unrelated code

## Definition of Done
- [ ] All Acceptance Criteria satisfied
- [ ] All Edge Cases handled
- [ ] Tests written and passing (framework: {test_framework})
- [ ] Single commit with TASK ID in message (feat(TASK-ID): ...)
<!-- DEVLOOP:COPILOT:END -->
"""
print(content, end="")
PYEOF
}

# ── cmd: start ───────────────────────────────────────────────────────────────

_verify_agents() {
  local missing_agents=()
  for agent in devloop-orchestrator devloop-architect devloop-reviewer; do
    [[ ! -f "$(find_project_root)/$AGENTS_DIR/$agent.md" ]] && missing_agents+=("$agent")
  done
  if [[ ${#missing_agents[@]} -gt 0 ]]; then
    error "Missing agent definitions: ${missing_agents[*]}"
    echo -e "  Run ${CYAN}devloop init${RESET} first"
    exit 1
  fi
}

_prevent_sleep() {
  if command -v caffeinate &>/dev/null; then
    caffeinate -is &
    CAFFEINATE_PID=$!
    success "Sleep prevention active ${GRAY}(caffeinate PID $CAFFEINATE_PID)${RESET}"
  else
    warn "caffeinate not found — system may sleep during session"
  fi
}

_stop_sleep_prevention() {
  if [[ -n "${CAFFEINATE_PID:-}" ]] && kill -0 "$CAFFEINATE_PID" 2>/dev/null; then
    kill "$CAFFEINATE_PID" 2>/dev/null || true
    info "Sleep prevention stopped"
  fi
}

_launch_claude_session() {
  local project_name="$1"
  # Export so any Copilot subprocess spawned by this session inherits permission
  export COPILOT_ALLOW_ALL=true
  claude \
    --remote-control "DevLoop: $project_name" \
    --agent devloop-orchestrator \
    --permission-mode acceptEdits
}

_launch_copilot_session() {
  local project_name="$1"
  # Read orchestrator agent definition to inject as context
  local agent_file="${DEVLOOP_DIR}/../.claude/agents/devloop-orchestrator.md"
  [[ ! -f "$agent_file" ]] && agent_file="$(pwd)/.claude/agents/devloop-orchestrator.md"

  local system_ctx=""
  if [[ -f "$agent_file" ]]; then
    system_ctx="$(cat "$agent_file")"
  else
    system_ctx="You are the DevLoop Orchestrator for project: $project_name. Coordinate tasks using devloop work commands."
  fi

  local init_prompt="[DevLoop session started for: $project_name]

$system_ctx

You are now running as the DevLoop Orchestrator in interactive Copilot mode. Wait for user instructions and coordinate the development pipeline using 'devloop work TASK-ID' to dispatch work."

  export COPILOT_ALLOW_ALL=true
  # Launch copilot with initial context prompt; drops into interactive REPL
  copilot --allow-all-tools --allow-all-paths -p "$init_prompt" 2>/dev/null || true
  # After the one-shot prompt, launch interactive session
  copilot --allow-all-tools --allow-all-paths
}

# _launch_session: dispatch to provider-specific session launcher
_launch_session() {
  local project_name="$1"
  local provider; provider="$(effective_main_provider)"

  case "$provider" in
    claude)
      _launch_claude_session "$project_name"
      ;;
    copilot)
      _launch_copilot_session "$project_name"
      ;;
    *)
      error "Unknown main provider '$provider' — cannot start session"
      exit 1
      ;;
  esac
}

cmd_start() {
  load_config
  check_deps
  _verify_agents

  local project_name="${1:-$PROJECT_NAME}"
  local main_backend; main_backend="$(effective_main_provider)"
  local worker_backend; worker_backend="$(worker_provider)"

  step "Starting DevLoop for: ${CYAN}$project_name${RESET}"
  divider
  echo ""

  # Show any pending update hint + fire background probe for next time
  _maybe_show_version_hint

  echo -e "${BOLD}Launching:${RESET}"
  case "$main_backend" in
    claude)
      echo -e "  ${CYAN}--remote-control${RESET}      accessible from mobile + browser"
      echo -e "  ${CYAN}--agent orchestrator${RESET}  main thread is the orchestrator"
      ;;
    copilot)
      echo -e "  ${CYAN}copilot interactive${RESET}   terminal session (no remote control)"
      echo -e "  ${CYAN}--agent context${RESET}       orchestrator role injected as prompt"
      ;;
  esac
  echo -e "  ${CYAN}caffeinate -is${RESET}        Mac stays awake while session runs"
  echo -e "  ${CYAN}providers${RESET}             main=$(provider_label "$main_backend"), worker=$(provider_label "$worker_backend")"
  echo ""
  echo -e "${BOLD}Connect from:${RESET}"
  case "$main_backend" in
    claude)
      echo -e "  📱 Claude app → find ${CYAN}\"DevLoop: $project_name\"${RESET} with green dot"
      echo -e "  🌐 ${CYAN}https://claude.ai/code${RESET} → session list"
      ;;
    copilot)
      echo -e "  💻 This terminal — session runs locally (no remote access)"
      echo -e "  ℹ  Copilot CLI has no remote-control equivalent"
      echo -e "  💡 Set ${CYAN}DEVLOOP_MAIN_PROVIDER=claude${RESET} for remote access"
      ;;
  esac
  echo ""
  echo -e "${GRAY}Press Ctrl+C to stop.${RESET}"
  divider
  echo ""

  CAFFEINATE_PID=""
  _prevent_sleep
  trap '_stop_sleep_prevention; exit 0' INT TERM EXIT
  _launch_session "$project_name"
}

# ── cmd: daemon ───────────────────────────────────────────────────────────────
# FIX #4: Restructured arg parsing so stop/status/log/uninstall work without
#         a project-name prefix (the original used ${2:-} after shift, which
#         required devloop daemon <name> stop — now bare subcmds work too).

cmd_daemon() {
  load_config

  # ── Arg parsing ──────────────────────────────────────────────────────────
  # Accepts:
  #   devloop daemon                         → start, default project name
  #   devloop daemon <project-name>          → start, custom name
  #   devloop daemon stop|status|log|uninstall       → subcmd, default name
  #   devloop daemon <project-name> stop|...         → subcmd, custom name
  local project_name="$PROJECT_NAME"
  local subcmd=""
  local known_subcmds="stop status log uninstall"

  if [[ $# -ge 1 ]]; then
    if echo "$known_subcmds" | grep -qw "${1:-}"; then
      subcmd="$1"
    else
      project_name="$1"
      subcmd="${2:-}"
    fi
  fi

  local log_file="${DEVLOOP_DIR}/daemon.log"
  local pid_file="${DEVLOOP_DIR}/daemon.pid"

  # ── Subcommands ───────────────────────────────────────────────────────────
  case "$subcmd" in
    stop)
      if [[ -f "$pid_file" ]]; then
        local pid; pid="$(cat "$pid_file")"
        if kill -0 "$pid" 2>/dev/null; then
          kill "$pid"
          rm -f "$pid_file"
          success "DevLoop daemon stopped (PID $pid)"
        else
          warn "Daemon not running (stale PID $pid)"
          rm -f "$pid_file"
        fi
      else
        warn "No daemon PID file found — daemon may not be running"
      fi
      return
      ;;
    status)
      if [[ -f "$pid_file" ]]; then
        local pid; pid="$(cat "$pid_file")"
        if kill -0 "$pid" 2>/dev/null; then
          success "Daemon running (PID $pid)"
          echo -e "  ${GRAY}Log: $log_file${RESET}"
          echo ""
          echo -e "${BOLD}Last 10 log lines:${RESET}"
          tail -10 "$log_file" 2>/dev/null || echo "(no log yet)"
        else
          warn "PID file exists but daemon not running"
        fi
      else
        info "Daemon not running"
        echo -e "  Start with: ${CYAN}devloop daemon${RESET}"
      fi
      return
      ;;
    log)
      tail -f "$log_file" 2>/dev/null || info "No log file yet"
      return
      ;;
    uninstall)
      _remove_launchd "$project_name"
      _remove_systemd "$project_name"
      return
      ;;
  esac

  # ── Start daemon ──────────────────────────────────────────────────────────
  check_deps
  _verify_agents

  if [[ -f "$pid_file" ]]; then
    local existing_pid; existing_pid="$(cat "$pid_file")"
    if kill -0 "$existing_pid" 2>/dev/null; then
      warn "Daemon already running (PID $existing_pid)"
      echo -e "  ${CYAN}devloop daemon stop${RESET}    to stop"
      echo -e "  ${CYAN}devloop daemon status${RESET}  to check"
      echo -e "  ${CYAN}devloop daemon log${RESET}     to tail logs"
      return
    fi
  fi

  mkdir -p "$DEVLOOP_DIR"

  local main_backend; main_backend="$(effective_main_provider)"

  # Copilot has no persistent remote session — warn and advise
  if [[ "$main_backend" == "copilot" ]]; then
    warn "Daemon mode with Copilot: no remote-control available"
    echo -e "  The daemon will restart the local Copilot interactive session on exit."
    echo -e "  For remote access, set ${CYAN}DEVLOOP_MAIN_PROVIDER=claude${RESET}"
    echo ""
  fi

  step "Starting DevLoop daemon: ${CYAN}$project_name${RESET}"
  echo -e "  Auto-restart on crash or wake"
  echo -e "  Sleep prevention via caffeinate"
  echo -e "  Log: ${CYAN}$log_file${RESET}"
  echo ""

  local restart_delay=5
  local max_restarts=20

  # FIX #4: No `local` inside subshell — `local` is function-scope only and
  #         produces undefined behaviour under set -euo pipefail in some shells.
  (
    attempt=0
    cafpid=""

    _daemon_cleanup() {
      [[ -n "$cafpid" ]] && kill "$cafpid" 2>/dev/null || true
      rm -f "$pid_file"
      echo "[$(date)] Daemon stopped" >> "$log_file"
    }
    trap '_daemon_cleanup; exit 0' INT TERM EXIT

    echo "[$(date)] DevLoop daemon started for: $project_name (main: $main_backend)" > "$log_file"

    while (( attempt < max_restarts )); do
      attempt=$(( attempt + 1 ))
      echo "[$(date)] Starting session (attempt $attempt/$max_restarts)" >> "$log_file"

      [[ -n "$cafpid" ]] && kill "$cafpid" 2>/dev/null || true
      /usr/bin/caffeinate -is &
      cafpid=$!

      _launch_session "$project_name" >> "$log_file" 2>&1
      exit_code=$?

      echo "[$(date)] Session ended (exit $exit_code)" >> "$log_file"

      if (( exit_code == 130 )); then
        echo "[$(date)] Stopped by user" >> "$log_file"
        break
      fi

      echo "[$(date)] Restarting in ${restart_delay}s..." >> "$log_file"
      sleep "$restart_delay"
      restart_delay=$(( restart_delay < 60 ? restart_delay + 5 : 60 ))
    done

    echo "[$(date)] Max restarts ($max_restarts) reached — daemon exiting" >> "$log_file"
  ) &

  local daemon_pid=$!
  echo "$daemon_pid" > "$pid_file"

  success "Daemon started (PID $daemon_pid)"
  echo ""
  echo -e "${BOLD}Connect from:${RESET}"
  case "$main_backend" in
    claude)
      echo -e "  📱 Claude app → ${CYAN}\"DevLoop: $project_name\"${RESET}"
      echo -e "  🌐 ${CYAN}https://claude.ai/code${RESET}"
      ;;
    copilot)
      echo -e "  💻 Copilot session runs locally — tail logs to monitor"
      echo -e "  ℹ  No remote control available with Copilot provider"
      ;;
  esac
  echo ""
  echo -e "${BOLD}Manage:${RESET}"
  echo -e "  ${CYAN}devloop daemon status${RESET}    check if running"
  echo -e "  ${CYAN}devloop daemon log${RESET}       tail live logs"
  echo -e "  ${CYAN}devloop daemon stop${RESET}      stop the daemon"
  echo -e "  ${CYAN}devloop daemon uninstall${RESET} remove auto-start entry"
  echo ""

  # Register persistent auto-start: launchd on macOS, systemd on Linux
  _write_launchd "$project_name"
  _write_systemd "$project_name"
}

# ── launchd: auto-start on macOS login ────────────────────────────────────────

_write_launchd() {
  local project_name="$1"
  [[ "$(uname)" != "Darwin" ]] && return

  local label="com.devloop.$(echo "$project_name" | tr '[:upper:] ' '[:lower:]_')"
  local plist="$HOME/Library/LaunchAgents/$label.plist"
  local project_dir; project_dir="$(find_project_root)"
  local devloop_bin; devloop_bin="$(command -v devloop)"
  local log_dir; log_dir="$project_dir/$DEVLOOP_DIR"

  mkdir -p "$HOME/Library/LaunchAgents"

  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>

  <key>ProgramArguments</key>
  <array>
    <string>$devloop_bin</string>
    <string>daemon</string>
    <string>$project_name</string>
  </array>

  <key>WorkingDirectory</key>
  <string>$project_dir</string>

  <!-- Start when user logs in -->
  <key>RunAtLoad</key>
  <true/>

  <!-- Restart if it crashes -->
  <key>KeepAlive</key>
  <true/>

  <!-- Wait 10s before restarting after crash -->
  <key>ThrottleInterval</key>
  <integer>10</integer>

  <!-- Hint to macOS: don't aggressively suspend -->
  <key>ProcessType</key>
  <string>Interactive</string>

  <key>StandardOutPath</key>
  <string>$log_dir/launchd.log</string>
  <key>StandardErrorPath</key>
  <string>$log_dir/launchd-error.log</string>
</dict>
</plist>
PLIST

  launchctl unload "$plist" 2>/dev/null || true
  launchctl load   "$plist" 2>/dev/null && \
    info "launchd agent registered — DevLoop starts automatically on login" || \
    warn "Could not register launchd agent (run manually if needed)"

  info "Plist: ${GRAY}$plist${RESET}"
}

_remove_launchd() {
  load_config
  local project_name="${1:-$PROJECT_NAME}"
  [[ "$(uname)" != "Darwin" ]] && return

  local label="com.devloop.$(echo "$project_name" | tr '[:upper:] ' '[:lower:]_')"
  local plist="$HOME/Library/LaunchAgents/$label.plist"

  if [[ -f "$plist" ]]; then
    launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
    success "launchd agent removed: $label"
  else
    warn "No launchd agent found for: $project_name"
  fi
}

# ── systemd: auto-start on Linux login — FIX #15 ─────────────────────────────

_write_systemd() {
  local project_name="$1"
  [[ "$(uname)" != "Linux" ]] && return
  command -v systemctl &>/dev/null || { warn "systemctl not found — skipping systemd registration"; return; }

  local safe_name; safe_name="$(echo "$project_name" | tr '[:upper:] ' '[:lower:]_')"
  local unit_name="devloop-${safe_name}.service"
  local unit_dir="$HOME/.config/systemd/user"
  local unit_file="$unit_dir/$unit_name"
  local project_dir; project_dir="$(find_project_root)"
  local devloop_bin; devloop_bin="$(command -v devloop)"
  local log_dir; log_dir="$project_dir/$DEVLOOP_DIR"

  mkdir -p "$unit_dir" "$log_dir"

  cat > "$unit_file" <<UNIT
[Unit]
Description=DevLoop daemon for $project_name
After=network.target

[Service]
Type=simple
WorkingDirectory=$project_dir
ExecStart=$devloop_bin daemon $project_name
Restart=on-failure
RestartSec=5
StandardOutput=append:$log_dir/systemd.log
StandardError=append:$log_dir/systemd-error.log

[Install]
WantedBy=default.target
UNIT

  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable "$unit_name" 2>/dev/null && \
    info "systemd user service enabled — DevLoop starts on login ${GRAY}($unit_name)${RESET}" || \
    warn "Could not enable systemd service (run: systemctl --user enable $unit_name)"

  info "Unit file: ${GRAY}$unit_file${RESET}"
}

_remove_systemd() {
  load_config
  local project_name="${1:-$PROJECT_NAME}"
  [[ "$(uname)" != "Linux" ]] && return
  command -v systemctl &>/dev/null || return

  local safe_name; safe_name="$(echo "$project_name" | tr '[:upper:] ' '[:lower:]_')"
  local unit_name="devloop-${safe_name}.service"
  local unit_file="$HOME/.config/systemd/user/$unit_name"

  if [[ -f "$unit_file" ]]; then
    systemctl --user stop    "$unit_name" 2>/dev/null || true
    systemctl --user disable "$unit_name" 2>/dev/null || true
    rm -f "$unit_file"
    systemctl --user daemon-reload 2>/dev/null || true
    success "systemd service removed: $unit_name"
  else
    warn "No systemd service found for: $project_name"
  fi
}

# ── cmd: architect ────────────────────────────────────────────────────────────

cmd_architect() {
  local feature="${1:-}"
  local type="${2:-feature}"
  local file_hints="${3:-}"

  if [[ -z "$feature" ]]; then
    error "Usage: devloop architect \"<feature>\" [type] [file-hints]"
    exit 1
  fi

  load_config
  ensure_dirs
  check_deps

  local id
  id="$(task_id)"
  local spec_file="$SPECS_PATH/$id.md"
  local provider
  _maybe_recover
  provider="$(effective_main_provider)"

  step "📐 $(provider_label "$provider") designing spec: ${BOLD}\"$feature\"${RESET}"
  divider

  local prompt
  prompt="$(cat <<PROMPT
You are a senior software architect. Design a precise implementation spec for GitHub Copilot CLI.

## Project
- Name: $PROJECT_NAME
- Stack: $PROJECT_STACK
- Patterns: $PROJECT_PATTERNS
- Conventions: $PROJECT_CONVENTIONS
- Tests: $TEST_FRAMEWORK

## Task
- ID: $id
- Type: $type
- Feature: $feature
$([ -n "$file_hints" ] && echo "- Files: $file_hints")

## Output this exact Markdown structure:

# $id: [Short Title]

**Feature**: $feature
**Type**: $type
**Status**: pending
**Created**: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

## Summary
[2-3 sentences]

## Files to Touch
| File | Action | Reason |
|------|--------|--------|
| path/to/file | CREATE/MODIFY | reason |

## Implementation Steps

### Step 1: [Name]
**File**: \`path\`
\`\`\`
// exact signatures
\`\`\`
- Rule 1
- Rule 2

## Acceptance Criteria
- [ ] Item 1
- [ ] Tests written

## Edge Cases
- Case: expected behavior

## Test Scenarios
| Scenario | Input | Expected |
|----------|-------|----------|
| Happy path | valid | success |
| Error | null | specific error |

## Copilot Instructions Block
\`\`\`
DEVLOOP TASK: $id
FEATURE: $feature
TYPE: $type

IMPLEMENT: [method name]
SIGNATURE: [exact signature with types]

RULES:
  1. [rule]

EDGE CASES:
  - [case]: [behavior]

TESTS REQUIRED: yes
FRAMEWORK: $TEST_FRAMEWORK
\`\`\`
PROMPT
)"

  info "Calling ${provider} for spec generation..."
  echo ""

  run_provider_prompt "$provider" "$prompt" "$spec_file"

  success "Spec saved: ${CYAN}$spec_file${RESET}"
  divider

  # FIX #2: Match ``` with or without a language tag (was /^```$/ which broke
  #         on ```bash, ```csharp, etc. inside the Copilot Instructions Block)
  step "📋 Copilot Instructions Block"
  local block
  block="$(awk '/^## Copilot Instructions Block/{f=1;next} f&&/^```/{c++;if(c==2)exit} f&&c==1' "$spec_file")"

  if [[ -n "$block" ]]; then
    divider
    echo -e "${YELLOW}$block${RESET}"
    divider
    local instructions_file="$PROMPTS_PATH/$id-copilot.txt"
    echo "$block" > "$instructions_file"
    success "Instructions saved: ${CYAN}$instructions_file${RESET}"
  else
    warn "Could not extract Copilot Instructions Block — showing last 20 lines of spec:"
    tail -20 "$spec_file"
  fi

  echo ""
  echo -e "${BOLD}Next:${RESET}  ${CYAN}devloop work $id${RESET}"
  echo ""
}

# ── cmd: work ────────────────────────────────────────────────────────────────

cmd_work() {
  # FIX (load_config order): load config FIRST so $SPECS_PATH is set before
  # latest_task() is called and before file-existence checks run.
  load_config
  ensure_dirs
  check_deps

  local id="${1:-$(latest_task)}"
  [[ -z "$id" ]] && { error "No task found. Run: devloop architect \"feature\""; exit 1; }

  local spec_file="$SPECS_PATH/$id.md"
  [[ ! -f "$spec_file" ]] && { error "Spec not found: $id"; exit 1; }
  local provider
  _maybe_recover
  provider="$(effective_worker_provider)"

  # Copilot coding agent mode — create GitHub Issue and hand off to cloud agent
  if [[ "${DEVLOOP_WORKER_MODE:-cli}" == "github-agent" ]]; then
    _cmd_work_github_agent "$id" "$spec_file"
    return
  fi

  # FIX #7: Validate spec completeness before handing to Copilot
  if ! grep -q '^## Copilot Instructions Block' "$spec_file"; then
    error "Spec appears incomplete — '## Copilot Instructions Block' section is missing."
    error "Regenerate with: devloop architect \"<feature>\""
    exit 1
  fi

  step "🤖 $(provider_label "$provider") implementing: ${BOLD}$id${RESET}"
  divider

  # FIX #1: Record current HEAD so `devloop review` can diff exactly what
  #         Copilot changed, even after it commits. Saved per-task.
  local base_hash
  base_hash="$(git rev-parse HEAD 2>/dev/null || echo "")"
  if [[ -n "$base_hash" ]]; then
    echo "$base_hash" > "$SPECS_PATH/$id.pre-commit"
    info "Git baseline recorded: ${GRAY}$base_hash${RESET}"
  else
    warn "Not a git repo or no commits yet — review will fall back to uncommitted diff"
  fi

  # FIX #10: Send the FULL spec, not just the condensed Instructions Block.
  # Copilot needs Files to Touch, Implementation Steps, Edge Cases, and Test
  # Scenarios — sections that were stripped in the old approach.
  local task_prompt
  task_prompt="$(cat "$spec_file")"

  info "Launching ${provider} CLI with task prompt..."
  echo ""

  # FIX #11: Prepend runtime stack context from current config so Copilot
  #          always has up-to-date conventions, even on re-runs.
  info "Runtime context → Stack: ${PROJECT_STACK} | Tests: ${TEST_FRAMEWORK}"
  local launch_prompt
  case "$provider" in
    claude)
      launch_prompt="You are implementing a DevLoop task spec. Follow it exactly.

## Runtime Project Context
Stack: $PROJECT_STACK
Patterns: $PROJECT_PATTERNS
Conventions: $PROJECT_CONVENTIONS
Test framework: $TEST_FRAMEWORK
Commit format: feat(TASK-ID): <one-line summary>

## Full Task Spec
$task_prompt

After planning, implement all steps. Run tests if possible. Stage ALL changed files and commit with the TASK ID in the message. Summarize what was implemented."
      ;;
    opencode|pi)
      launch_prompt="You are implementing a DevLoop task spec. Follow it exactly.

## Runtime Project Context
Stack: $PROJECT_STACK
Patterns: $PROJECT_PATTERNS
Conventions: $PROJECT_CONVENTIONS
Test framework: $TEST_FRAMEWORK
Commit format: feat(TASK-ID): <one-line summary>

## Full Task Spec
$task_prompt

After planning, implement all steps. Run tests if possible. Stage ALL changed files and commit with the TASK ID in the message. Summarize what was implemented."
      ;;
    *)  # copilot and others
      launch_prompt="/plan You are implementing a DevLoop task spec. Follow it exactly.

## Runtime Project Context
Stack: $PROJECT_STACK
Patterns: $PROJECT_PATTERNS
Conventions: $PROJECT_CONVENTIONS
Test framework: $TEST_FRAMEWORK
Commit format: feat(TASK-ID): <one-line summary>

## Full Task Spec
$task_prompt

After planning, implement all steps. Run tests if possible. Stage ALL changed files and commit with the TASK ID in the message. Summarize what was implemented."
      ;;
  esac

  local tmp_spec
  tmp_spec="$(mktemp /tmp/devloop_task_XXXXXX.md)"
  echo "$launch_prompt" > "$tmp_spec"

  local attempt_provider="$provider"
  while true; do
    local tmp_out; tmp_out="$(mktemp /tmp/devloop_work_out_XXXXXX)"
    local rc=0
    case "$attempt_provider" in
      claude)
        # --allowedTools scopes what the worker can call (no system ops outside project)
        local _worker_tools="Read,Write,Edit,MultiEdit,Bash(git*),Bash(pytest*),Bash(npm*),Bash(yarn*),Bash(pnpm*),Bash(cargo*),Bash(go*),Bash(python*),Bash(make*),Bash(cat*),Bash(grep*),Bash(find*),Bash(ls*),Bash(mkdir*),Bash(mv*),Bash(cp*),Bash(rm -f*),Glob,LS"
        local _worker_model="${CLAUDE_WORKER_MODEL:-${CLAUDE_MODEL:-sonnet}}"
        if ! cat "$tmp_spec" | claude -p --model "$_worker_model" --allowedTools "$_worker_tools" > "$tmp_out" 2>&1; then
          cat "$tmp_spec" | claude -p --model "$_worker_model" > "$tmp_out" 2>&1 || rc=$?
        fi
        ;;
      opencode)
        opencode run --file "$tmp_spec" "Implement the DevLoop task spec in the attached file exactly as described. Stage ALL changed files and commit with the TASK ID in the message. Summarize what was implemented." 2>&1 | tee "$tmp_out" || rc=$?
        ;;
      pi)
        pi --mode json "$launch_prompt" 2>&1 | tee "$tmp_out" | cat || rc=$?
        ;;
      *)  # copilot
        copilot --allow-all-tools --allow-all-paths -p "$(cat "$tmp_spec")" 2>&1 | tee "$tmp_out" || rc=$?
        ;;
    esac
    cat "$tmp_out"
    if _is_rate_limit_error "$(cat "$tmp_out")" || (( rc == 429 )); then
      local fallback; fallback="$(_fallback_worker "$attempt_provider")"
      warn "$(provider_label "$attempt_provider") hit its limit — switching worker to $(provider_label "${fallback:-none}")"
      if [[ -z "$fallback" ]]; then
        error "All worker providers are rate-limited. Try again later."
        rm -f "$tmp_out" "$tmp_spec"; exit 1
      fi
      _health_mark_limited worker "$fallback"
      attempt_provider="$fallback"
      rm -f "$tmp_out"
      continue
    fi
    if [[ "$attempt_provider" != "$provider" ]]; then
      info "Completed via fallback worker: $(provider_label "$attempt_provider")"
    fi
    rm -f "$tmp_out"
    break
  done
  rm -f "$tmp_spec"

  echo ""
  success "$(provider_label "$provider") session ended"
  echo -e "  Run ${CYAN}devloop review $id${RESET} to review the implementation"
  echo ""
}

# ── cmd: review ──────────────────────────────────────────────────────────────

cmd_review() {
  # FIX (load_config order): must run before latest_task() and file checks
  load_config
  ensure_dirs
  check_deps

  local id="${1:-$(latest_task)}"
  [[ -z "$id" ]] && { error "No task found."; exit 1; }

  local spec_file="$SPECS_PATH/$id.md"
  [[ ! -f "$spec_file" ]] && { error "Spec not found: $id"; exit 1; }
  local provider
  _maybe_recover
  provider="$(effective_main_provider)"

  step "🔍 $(provider_label "$provider") reviewing: ${BOLD}$id${RESET}"
  divider

  # FIX #1: Use the pre-commit baseline saved by `devloop work` so we see
  #         exactly what Copilot changed — including committed changes.
  info "Reading git changes..."
  local impl=""
  local diff=""
  local staged=""
  local pre_commit_file="$SPECS_PATH/$id.pre-commit"

  if [[ -f "$pre_commit_file" ]]; then
    local base_hash; base_hash="$(cat "$pre_commit_file")"
    if git rev-parse "$base_hash" &>/dev/null 2>&1; then
      diff="$(git diff "${base_hash}..HEAD" 2>/dev/null || echo "")"
      info "Diffing from baseline: ${GRAY}${base_hash:0:12}...${RESET}"
    fi
  fi

  # Fallback: uncommitted changes (covers manual runs without a baseline)
  if [[ -z "$diff" ]]; then
    warn "No pre-commit baseline found — falling back to uncommitted diff"
    diff="$(git diff HEAD 2>/dev/null || git diff 2>/dev/null || echo "")"
    staged="$(git diff --cached 2>/dev/null || echo "")"

    local new_files; new_files="$(git ls-files --others --exclude-standard 2>/dev/null | head -8 || echo "")"
    while IFS= read -r file; do
      [[ -n "$file" && -f "$file" ]] && impl+="## New file: $file\n\`\`\`\n$(cat "$file")\n\`\`\`\n\n"
    done <<< "$new_files"
  fi

  [[ -n "$diff"   ]] && impl+="## Changes\n\`\`\`diff\n$diff\n\`\`\`\n\n"
  [[ -n "$staged" ]] && impl+="## Staged changes\n\`\`\`diff\n$staged\n\`\`\`\n\n"
  [[ -z "$impl"   ]] && {
    warn "No git changes detected — Copilot may not have committed yet."
    impl="(No git changes found)"
  }

  # FIX #6: Compact spec for review — extract only review-relevant sections.
  # Skips the Copilot Instructions Block (that's an input, not a spec).
  # Reduces review prompt size by ~40-50% on typical specs.
  local review_spec
  review_spec="$(awk '
    /^# TASK-/                        { print; next }
    /^\*\*(Feature|Type|Status)\*\*/  { print; next }
    /^## (Summary|Files to Touch|Implementation Steps|Acceptance Criteria|Edge Cases|Test Scenarios)/ {
      in_section = 1; print; next
    }
    /^## [A-Z]/ && !in_section        { next }
    /^## [A-Z]/ {
      # Check if entering a section we want
      if ($0 ~ /^## (Summary|Files to Touch|Implementation Steps|Acceptance Criteria|Edge Cases|Test Scenarios)/)
        in_section = 1
      else
        in_section = 0
    }
    in_section { print }
  ' "$spec_file")"
  # Guard: if extraction produced nothing, fall back to full spec
  [[ -z "$review_spec" ]] && review_spec="$(cat "$spec_file")"

  # Build review prompt using a temp file to avoid bash 3.2 heredoc-inside-$()
  # parsing issues when $impl contains naked backticks from file content.
  local _rp; _rp="$(mktemp /tmp/devloop-review-XXXXXX)"
  {
    printf '%s\n' "You are a strict senior code reviewer."
    printf '\n## Project\n'
    printf '%s\n' "- Stack: $PROJECT_STACK"
    printf '%s\n' "- Patterns: $PROJECT_PATTERNS"
    printf '%s\n' "- Conventions: $PROJECT_CONVENTIONS"
    printf '\n## Original Spec\n'
    printf '%s\n' "$review_spec"
    printf '\n## Implementation (git diff)\n'
    echo -e "$impl"
    printf '\n## Review criteria (priority order)\n'
    printf '%s\n' "1. Spec compliance" "2. Correctness / edge cases" \
      "3. Error handling" "4. Code quality (SOLID)" \
      "5. Security" "6. Test coverage"
    printf '\n## Required output format\n'
    printf '%s\n' "First non-empty line must be EXACTLY one of:"
    printf '%s\n' "Verdict: APPROVED" "Verdict: NEEDS_WORK" "Verdict: REJECTED"
    printf '%s\n' "Do not use emoji, markdown heading prefixes, or bold styling on the primary verdict line."
    printf '\n**Score**: X/10\n**Summary**: [one sentence]\n'
    printf '\n### What'"'"'s Good\n- [specific positive]\n'
    printf '\n### Issues Found\n'
    printf '%s\n' '| # | Severity | File/Area | Issue |' \
      '|---|----------|-----------|-------|' \
      '| 1 | CRITICAL/HIGH/MEDIUM/LOW | area | description |'
    printf '\n### Required Fixes\n**Fix 1**: description\n'
    printf '```\n// exact code\n```\n'
    printf '\n### Copilot Fix Instructions\n'
    printf '```\n'
    printf '%s\n' "DEVLOOP REVIEW: $id" "VERDICT: [verdict]" ""
    printf '%s\n' "FIX #1:" "  IN: [file/method]" \
      "  PROBLEM: [what\'s wrong]" "  SOLUTION: [what to do]"
    printf '```\n'
    printf '\nIf APPROVED: "Implementation matches spec. No fixes required."\n'
  } > "$_rp"
  local review_prompt
  review_prompt="$(cat "$_rp")"
  rm -f "$_rp"

  info "Calling ${provider} for review..."
  echo ""

  local review_file="$SPECS_PATH/$id-review.md"
  run_provider_prompt "$provider" "$review_prompt" "$review_file"
  cat "$review_file"

  divider

  local verdict
  verdict="$(parse_review_verdict "$review_file")"

  case "$verdict" in
    APPROVED)
      success "${GREEN}${BOLD}✅ APPROVED${RESET}"
      sed -i.bak 's/\*\*Status\*\*: .*/\*\*Status\*\*: ✅ approved/' "$spec_file" && rm -f "$spec_file.bak"
      ;;
    NEEDS_WORK)
      warn "${YELLOW}${BOLD}⚠️  NEEDS WORK${RESET}"
      sed -i.bak 's/\*\*Status\*\*: .*/\*\*Status\*\*: ⚠️ needs-work/' "$spec_file" && rm -f "$spec_file.bak"
      echo -e "\n  ${CYAN}devloop fix $id${RESET}  ${GRAY}→ launch Copilot with fix instructions${RESET}"
      ;;
    REJECTED)
      error "${RED}${BOLD}❌ REJECTED${RESET}"
      sed -i.bak 's/\*\*Status\*\*: .*/\*\*Status\*\*: ❌ rejected/' "$spec_file" && rm -f "$spec_file.bak"
      ;;
    *)
      warn "Could not determine verdict from review output: $review_file"
      echo -e "  ${GRAY}Expected first non-empty line:${RESET} ${CYAN}Verdict: APPROVED|NEEDS_WORK|REJECTED${RESET}"
      echo -e "  ${GRAY}Fix:${RESET} Re-run reviewer with canonical verdict line."
      ;;
  esac

  echo ""
  info "Review saved: ${CYAN}$review_file${RESET}"
  echo ""
}

# ── cmd: fix ─────────────────────────────────────────────────────────────────

cmd_fix() {
  # FIX (load_config order): must run before latest_task() and file checks
  load_config
  check_deps

  # Optional --history arg: accumulated prior review text injected into fix prompt
  local fix_history_text=""
  if [[ "${1:-}" == "--history" ]]; then
    fix_history_text="${2:-}"
    shift 2
  fi

  local id="${1:-$(latest_task)}"
  [[ -z "$id" ]] && { error "No task found."; exit 1; }

  local review_file="$SPECS_PATH/$id-review.md"
  [[ ! -f "$review_file" ]] && { error "No review found. Run: devloop review $id"; exit 1; }
  local provider
  _maybe_recover
  provider="$(effective_worker_provider)"

  step "🔧 $(provider_label "$provider") fixing: ${BOLD}$id${RESET}"
  [[ -n "$fix_history_text" ]] && info "Deep-fix mode: prior review history injected"
  divider

  # FIX #2: Match ``` with or without language tag (same fix as cmd_architect)
  local fix_instructions
  fix_instructions="$(awk '/^### Copilot Fix Instructions/{f=1;next} f&&/^```/{c++;if(c==2)exit} f&&c==1' "$review_file")"
  [[ -z "$fix_instructions" ]] && fix_instructions="$(cat "$review_file")"

  # FIX #1: Update the pre-commit baseline so the next `devloop review` diffs
  #         from after these fixes, not from the original work session.
  local base_hash
  base_hash="$(git rev-parse HEAD 2>/dev/null || echo "")"
  if [[ -n "$base_hash" ]]; then
    echo "$base_hash" > "$SPECS_PATH/$id.pre-commit"
    info "Git baseline updated: ${GRAY}${base_hash:0:12}...${RESET}"
  fi

  info "Launching ${provider} CLI with fix instructions..."
  echo ""

  local fix_prompt
  if [[ -n "$fix_history_text" ]]; then
    fix_prompt="You are fixing a code review that has already failed multiple times.
Study the HISTORY of prior review failures first, then examine the CURRENT review.
Understand WHY previous fixes did not satisfy the reviewer before attempting new fixes.
Take a fundamentally different approach where previous attempts failed.

## Prior Fix History (what was tried and still failed)
$fix_history_text

## Current Review Issues to Fix Now
$fix_instructions

Fix all CRITICAL and HIGH severity issues. After fixing, stage all changed files and commit:
feat($id): fix review issues — <one-line summary of what was fixed>
Summarize the changes made and explain how your approach differs from previous attempts."
  else
    fix_prompt="The following issues were identified in a code review. Fix each one exactly as described.

$fix_instructions

Fix all CRITICAL and HIGH severity issues. After fixing, stage all changed files and commit:
feat($id): fix review issues — <one-line summary of what was fixed>
Summarize the changes made."
  fi

  local attempt_fix_provider="$provider"
  while true; do
    local tmp_fix_out; tmp_fix_out="$(mktemp /tmp/devloop_fix_out_XXXXXX)"
    local rc=0
    if [[ "$attempt_fix_provider" == "claude" ]]; then
      local _worker_tools="Read,Write,Edit,MultiEdit,Bash(git*),Bash(pytest*),Bash(npm*),Bash(yarn*),Bash(pnpm*),Bash(cargo*),Bash(go*),Bash(python*),Bash(make*),Bash(cat*),Bash(grep*),Bash(find*),Bash(ls*),Bash(mkdir*),Bash(mv*),Bash(cp*),Bash(rm -f*),Glob,LS"
      local _worker_model="${CLAUDE_WORKER_MODEL:-${CLAUDE_MODEL:-sonnet}}"
      if ! echo "$fix_prompt" | claude -p --model "$_worker_model" --allowedTools "$_worker_tools" > "$tmp_fix_out" 2>&1; then
        echo "$fix_prompt" | claude -p --model "$_worker_model" > "$tmp_fix_out" 2>&1 || rc=$?
      fi
    elif [[ "$attempt_fix_provider" == "opencode" ]]; then
      local tmp_fix; tmp_fix="$(mktemp /tmp/devloop_fix_XXXXXX.md)"
      echo "$fix_prompt" > "$tmp_fix"
      opencode run --file "$tmp_fix" "Fix the issues described in the attached file exactly. Stage all changed files and commit." 2>&1 | tee "$tmp_fix_out" || rc=$?
      rm -f "$tmp_fix"
    elif [[ "$attempt_fix_provider" == "pi" ]]; then
      pi --mode json "$fix_prompt" 2>&1 | tee "$tmp_fix_out" | cat || rc=$?
    else
      copilot --allow-all-tools --allow-all-paths -p "$fix_prompt" 2>&1 | tee "$tmp_fix_out" || rc=$?
    fi
    cat "$tmp_fix_out"
    if _is_rate_limit_error "$(cat "$tmp_fix_out")" || (( rc == 429 )); then
      local fallback; fallback="$(_fallback_worker "$attempt_fix_provider")"
      warn "$(provider_label "$attempt_fix_provider") hit its limit — switching to $(provider_label "${fallback:-none}")"
      if [[ -z "$fallback" ]]; then
        error "All worker providers are rate-limited. Try again later."
        rm -f "$tmp_fix_out"; exit 1
      fi
      _health_mark_limited worker "$fallback"
      attempt_fix_provider="$fallback"
      rm -f "$tmp_fix_out"
      continue
    fi
    if [[ "$attempt_fix_provider" != "$provider" ]]; then
      info "Fix completed via fallback: $(provider_label "$attempt_fix_provider")"
    fi
    rm -f "$tmp_fix_out"
    break
  done

  echo ""
  success "$(provider_label "$provider") fix session ended"
  echo -e "  ${CYAN}devloop review $id${RESET}  ${GRAY}→ re-review after fixes${RESET}"
  echo ""
}

# ── cmd: tasks ────────────────────────────────────────────────────────────────

cmd_tasks() {
  load_config

  if [[ ! -d "$SPECS_PATH" ]] || [[ -z "$(ls -A "$SPECS_PATH" 2>/dev/null)" ]]; then
    info "No task specs found."
    echo -e "  ${CYAN}devloop architect \"feature\"${RESET}"
    return
  fi

  step "📋 Task Specs"
  divider
  printf "  %-26s %-45s %s\n" "TASK ID" "FEATURE" "STATUS"
  divider

  for spec in $(ls -1t "$SPECS_PATH"/*.md 2>/dev/null | grep -v '\-review\.md'); do
    local id; id="$(basename "$spec" .md)"
    local feature; feature="$(grep '^\*\*Feature\*\*:' "$spec" 2>/dev/null | sed 's/\*\*Feature\*\*: //' | head -1)"
    local status; status="$(grep '^\*\*Status\*\*:' "$spec" 2>/dev/null | sed 's/\*\*Status\*\*: //' | head -1)"
    local icon="⏳"
    [[ "$status" == *approved*   ]] && icon="✅"
    [[ "$status" == *rejected*   ]] && icon="❌"
    [[ "$status" == *needs-work* ]] && icon="⚠️ "
    printf "  %s %-24s %-45s %s\n" "$icon" "$id" "${feature:0:44}" "${status:-pending}"
  done

  divider
  echo ""
}

# ── cmd: status ───────────────────────────────────────────────────────────────

cmd_status() {
  # FIX (load_config order): load config before latest_task()
  load_config

  local id="${1:-$(latest_task)}"
  [[ -z "$id" ]] && { error "No specs found."; exit 1; }

  local spec_file="$SPECS_PATH/$id.md"
  [[ ! -f "$spec_file" ]] && { error "Spec not found: $id"; exit 1; }

  step "📄 $id"
  divider
  cat "$spec_file"

  local review_file="$SPECS_PATH/$id-review.md"
  if [[ -f "$review_file" ]]; then
    echo ""
    step "🔍 Latest Review"
    divider
    cat "$review_file"
  fi

  divider
  echo ""

  # Show provider health inline
  _health_load
  local eff_main; eff_main="$(effective_main_provider)"
  local eff_worker; eff_worker="$(effective_worker_provider)"
  echo -e "  ${BOLD}Providers:${RESET}  main=$(provider_label "$eff_main") | worker=$(provider_label "$eff_worker")"
  # Show Claude model config if Claude is in use
  if [[ "$eff_main" == "claude" || "$eff_worker" == "claude" ]]; then
    local _main_model="${CLAUDE_MAIN_MODEL:-${CLAUDE_MODEL:-sonnet}}"
    local _worker_model="${CLAUDE_WORKER_MODEL:-${CLAUDE_MODEL:-sonnet}}"
    if [[ "$eff_main" == "claude" && "$eff_worker" == "claude" ]]; then
      if [[ "$_main_model" == "$_worker_model" ]]; then
        echo -e "  ${BOLD}Claude model:${RESET} $_main_model (all roles)"
      else
        echo -e "  ${BOLD}Claude model:${RESET} main=$_main_model | worker=$_worker_model"
      fi
    elif [[ "$eff_main" == "claude" ]]; then
      echo -e "  ${BOLD}Claude model:${RESET} main=$_main_model"
    else
      echo -e "  ${BOLD}Claude model:${RESET} worker=$_worker_model"
    fi
  fi
  if [[ -n "$HEALTH_MAIN_OVERRIDE" || -n "$HEALTH_WORKER_OVERRIDE" ]]; then
    warn "Failover active — run ${CYAN}devloop failover status${RESET} for details"
  fi
  echo ""
}

cmd_open() {
  load_config

  local id="${1:-$(latest_task)}"
  [[ -z "$id" ]] && { error "No specs found."; exit 1; }

  local spec_file="$SPECS_PATH/$id.md"
  [[ ! -f "$spec_file" ]] && { error "Spec not found: $id"; exit 1; }

  local editor="${EDITOR:-${VISUAL:-vi}}"
  info "Opening ${CYAN}$spec_file${RESET} in $editor"
  "$editor" "$spec_file"
}

# ── cmd: block — FIX #12 ─────────────────────────────────────────────────────

cmd_block() {
  load_config

  local id="${1:-$(latest_task)}"
  [[ -z "$id" ]] && { error "No specs found."; exit 1; }

  # Check for pre-extracted file from cmd_architect
  local instructions_file="$PROMPTS_PATH/$id-copilot.txt"
  if [[ -f "$instructions_file" ]]; then
    cat "$instructions_file"
    return
  fi

  local spec_file="$SPECS_PATH/$id.md"
  [[ ! -f "$spec_file" ]] && { error "Spec not found: $id"; exit 1; }

  # FIX #2: Match ``` with or without language tag
  local block
  block="$(awk '/^## Copilot Instructions Block/{f=1;next} f&&/^```/{c++;if(c==2)exit} f&&c==1' "$spec_file")"

  if [[ -n "$block" ]]; then
    echo "$block"
  else
    warn "No Copilot Instructions Block found in spec"
    echo -e "  View full spec: ${CYAN}devloop status $id${RESET}"
    exit 1
  fi
}

# ── cmd: clean — FIX #13 ─────────────────────────────────────────────────────

cmd_clean() {
  local days=30
  local dry_run=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --days)    days="${2:-30}"; shift 2 ;;
      --dry-run) dry_run=true; shift ;;
      *)         shift ;;
    esac
  done

  load_config

  if [[ ! -d "$SPECS_PATH" ]]; then
    info "No specs directory found."
    return
  fi

  step "🧹 Cleaning specs older than ${BOLD}${days} days${RESET}"
  divider

  local count=0
  local skipped=0

  while IFS= read -r spec; do
    [[ -z "$spec" ]] && continue
    local id; id="$(basename "$spec" .md)"
    local status; status="$(grep '^\*\*Status\*\*:' "$spec" 2>/dev/null | sed 's/\*\*Status\*\*: //' | head -1)"

    # Only clean finalized tasks — never remove pending or needs-work
    if [[ "$status" == *approved* || "$status" == *rejected* ]]; then
      local related=()
      related+=("$spec")
      [[ -f "$SPECS_PATH/$id-review.md"     ]] && related+=("$SPECS_PATH/$id-review.md")
      [[ -f "$SPECS_PATH/$id.pre-commit"    ]] && related+=("$SPECS_PATH/$id.pre-commit")
      [[ -f "$PROMPTS_PATH/$id-copilot.txt" ]] && related+=("$PROMPTS_PATH/$id-copilot.txt")

      if [[ "$dry_run" == true ]]; then
        echo -e "  ${GRAY}[dry-run] would remove: $id  (${status})${RESET}"
      else
        for f in "${related[@]}"; do rm -f "$f"; done
        success "Removed: ${CYAN}$id${RESET}  ${GRAY}(${status})${RESET}"
      fi
      count=$(( count + 1 ))
    else
      skipped=$(( skipped + 1 ))
    fi
  done < <(find "$SPECS_PATH" -maxdepth 1 -name "TASK-*.md" -not -name "*-review.md" -mtime "+${days}" 2>/dev/null | sort)

  divider
  if [[ "$dry_run" == true ]]; then
    info "$count specs would be removed, $skipped pending/needs-work preserved"
    echo -e "  Run without ${CYAN}--dry-run${RESET} to apply"
  else
    if (( count == 0 && skipped == 0 )); then
      info "No finalized specs older than $days days found"
    elif (( count == 0 )); then
      info "No finalized specs removed, $skipped pending/needs-work preserved"
    else
      success "$count specs removed, $skipped pending/needs-work preserved"
    fi
  fi
  echo ""
}

# ── cmd: update — FIX #14 ────────────────────────────────────────────────────

cmd_update() {
  load_config

  local url="${DEVLOOP_SOURCE_URL:-}"
  local repo="${DEVLOOP_GITHUB_REPO:-shaifulshabuj/devloop}"

  # Default: use the GitHub repo (no config needed)
  if [[ -z "$url" ]]; then
    info "Source: GitHub (${GRAY}$repo${RESET})"
  else
    info "Source: custom URL (${GRAY}$url${RESET})"
  fi

  local current_version="$VERSION"
  local tmp_file; tmp_file="$(mktemp /tmp/devloop-update.XXXXXX)"

  step "🔄 Updating devloop..."
  echo ""

  local _downloaded="false"

  # If no custom URL, try gh release download first (works for private repos)
  if [[ -z "$url" ]] && command -v gh &>/dev/null; then
    local latest_tag
    latest_tag="$(gh api "repos/$repo/releases/latest" --jq '.tag_name' 2>/dev/null)"
    if [[ -n "$latest_tag" ]]; then
      local dl_dir; dl_dir="$(mktemp -d /tmp/devloop-dl.XXXXXX)"
      if gh release download "$latest_tag" --repo "$repo" \
          --pattern "devloop.sh" --dir "$dl_dir" 2>/dev/null \
          && [[ -f "$dl_dir/devloop.sh" ]]; then
        cp "$dl_dir/devloop.sh" "$tmp_file"
        rm -rf "$dl_dir"
        _downloaded="true"
      else
        rm -rf "$dl_dir"
      fi
    fi
  fi

  # Fall back to curl/wget (works for public repos or custom URLs)
  if [[ "$_downloaded" != "true" ]]; then
    [[ -z "$url" ]] && url="$(_gh_script_url)"
    if command -v curl &>/dev/null; then
      curl -fsSL "$url" -o "$tmp_file" || { error "Download failed from: $url"; rm -f "$tmp_file"; exit 1; }
    elif command -v wget &>/dev/null; then
      wget -qO "$tmp_file" "$url"      || { error "Download failed from: $url"; rm -f "$tmp_file"; exit 1; }
    else
      error "Neither gh, curl, nor wget found — cannot download update"
      rm -f "$tmp_file"; exit 1
    fi
  fi

  # Basic sanity check — must look like a devloop script
  if ! grep -q 'devloop' "$tmp_file" 2>/dev/null; then
    error "Downloaded file does not appear to be a devloop script — aborting"
    rm -f "$tmp_file"; exit 1
  fi

  local new_version
  new_version="$(grep '^VERSION=' "$tmp_file" 2>/dev/null | head -1 | sed 's/VERSION="\(.*\)"/\1/')"

  if [[ -z "$new_version" ]]; then
    warn "Could not determine new version number — proceeding anyway"
  elif [[ "$new_version" == "$current_version" ]]; then
    success "Already up to date (v$current_version) ✅"
    rm -f "$tmp_file"
    return
  else
    info "Updating: ${BOLD}v$current_version${RESET} → ${GREEN}v$new_version${RESET}"
  fi

  local install_target; install_target="$(command -v devloop 2>/dev/null || echo "/usr/local/bin/devloop")"
  chmod +x "$tmp_file"

  if [[ -w "$(dirname "$install_target")" ]]; then
    cp "$tmp_file" "$install_target"
  else
    sudo cp "$tmp_file" "$install_target"
  fi

  rm -f "$tmp_file"
  success "Installed devloop ${GREEN}v${new_version:-unknown}${RESET} → ${CYAN}$install_target${RESET}"
  echo ""

  # ── Refresh project configs for the new version ────────────────────────────
  _refresh_project_for_version "${new_version:-$current_version}"
}

# Refresh project-level devloop config files after a version upgrade.
# Safe to re-run: hooks are idempotent, CLAUDE.md managed block is updated
# in place (user content outside the managed block is preserved).
_refresh_project_for_version() {
  local new_ver="${1:-}"
  local root; root="$(find_project_root 2>/dev/null || echo "")"

  # Only refresh if we are inside an initialized devloop project
  if [[ -z "$root" ]] || [[ ! -f "$root/$CONFIG_FILE" ]]; then
    info "Not inside a devloop project — skipping project config refresh"
    info "Run ${CYAN}devloop init${RESET} in a project directory to set up."
    return
  fi

  step "🔧 Refreshing project configs for v${new_ver}..."
  echo ""

  # 1. Refresh Claude hook scripts (devloop-permission.sh, devloop-audit.sh)
  if [[ -f "$root/.claude/settings.json" ]]; then
    info "Refreshing Claude hooks..."
    cmd_hooks 2>/dev/null && success "  ✓ Hooks updated (.claude/hooks/)" || warn "  Hook refresh failed (run: devloop hooks)"
    echo ""
  fi

  # 2. Refresh devloop agent markdown files
  if ls "$root/$AGENTS_DIR/devloop-"*.md &>/dev/null 2>&1; then
    info "Refreshing devloop agent prompts..."
    local agents_updated=0
    load_config 2>/dev/null || true
    local _main_m="${CLAUDE_MAIN_MODEL:-${CLAUDE_MODEL:-sonnet}}"
    for agent_src in orchestrator architect reviewer; do
      local agent_file="$root/$AGENTS_DIR/devloop-${agent_src}.md"
      if [[ -f "$agent_file" ]]; then
        case "$agent_src" in
          orchestrator) write_agent_orchestrator 2>/dev/null && agents_updated=$(( agents_updated + 1 )) || true ;;
          architect)    write_agent_architect "$_main_m" 2>/dev/null && agents_updated=$(( agents_updated + 1 )) || true ;;
          reviewer)     write_agent_reviewer "$_main_m" 2>/dev/null && agents_updated=$(( agents_updated + 1 )) || true ;;
        esac
      fi
    done
    if (( agents_updated > 0 )); then
      success "  ✓ Agent prompts refreshed ($agents_updated files)"
    else
      info "  Agent prompt functions not found — run ${CYAN}devloop init${RESET} to refresh"
    fi
    echo ""
  fi

  # 3. Update the DevLoop-managed block in CLAUDE.md (commands list may have changed)
  if [[ -f "$root/CLAUDE.md" ]]; then
    info "Refreshing CLAUDE.md managed block..."
    local managed_block; managed_block="$(_render_claude_managed_block)"
    _upsert_managed_block "$root/CLAUDE.md" \
      "<!-- DEVLOOP:CLAUDE:START -->" \
      "<!-- DEVLOOP:CLAUDE:END -->" \
      "$managed_block" 2>/dev/null \
      && success "  ✓ CLAUDE.md updated" \
      || warn "  CLAUDE.md update failed (run: devloop init)"
    echo ""
  fi

  # 4. Merge any new config keys into devloop.config.sh
  if [[ -f "$root/$CONFIG_FILE" ]]; then
    info "Checking devloop.config.sh for new keys..."
    local added_keys; added_keys="$(_merge_devloop_config_defaults "$root/$CONFIG_FILE" 2>/dev/null || echo 0)"
    if (( added_keys > 0 )); then
      success "  ✓ Added $added_keys new config key(s) to devloop.config.sh"
    else
      success "  ✓ devloop.config.sh is up to date"
    fi
    echo ""
  fi

  divider
  success "Project configs refreshed for devloop v${new_ver} ✅"
  echo -e "  ${GRAY}Run ${CYAN}devloop doctor${RESET}${GRAY} to validate everything is working${RESET}"
  echo ""
}

# ── Tools / MCP / Skills Management ──────────────────────────────────────────

_read_global_claude_mcp() {
  local f="$HOME/.claude.json"
  [[ -f "$f" ]] || return 0
  python3 -c "
import json
try:
    data = json.load(open('$f'))
    for name in sorted(data.get('mcpServers', {}).keys()): print(name)
except Exception: pass
" 2>/dev/null
}

_read_project_claude_mcp() {
  local f="$1/.mcp.json"
  [[ -f "$f" ]] || return 0
  python3 -c "
import json
try:
    data = json.load(open('$f'))
    for name in sorted(data.get('mcpServers', {}).keys()): print(name)
except Exception: pass
" 2>/dev/null
}

_read_project_vscode_mcp() {
  local f="$1/.vscode/mcp.json"
  [[ -f "$f" ]] || return 0
  python3 -c "
import json
try:
    data = json.load(open('$f'))
    for name in sorted(data.get('servers', {}).keys()): print(name)
except Exception: pass
" 2>/dev/null
}

_read_global_claude_plugins() {
  local f="$HOME/.claude/settings.json"
  [[ -f "$f" ]] || return 0
  python3 -c "
import json
try:
    data = json.load(open('$f'))
    for p in sorted(data.get('enabledPlugins', [])): print(p)
except Exception: pass
" 2>/dev/null
}

_read_global_claude_skills()  { local d="$HOME/.claude/skills"; [[ -d "$d" ]] && ls -1 "$d" 2>/dev/null | sort || true; }
_read_project_claude_skills() { local d="$1/.claude/skills"; [[ -d "$d" ]] && ls -1 "$d" 2>/dev/null | sort || true; }
_read_project_copilot_skills() {
  local root="$1"
  python3 - "$root" << 'PYEOF'
import os
import sys

root = sys.argv[1]
paths = [
    os.path.join(root, ".github", "copilot", "skills"),
    os.path.join(root, ".copilot", "skills"),
]
names = set()
for base in paths:
    if not os.path.isdir(base):
        continue
    for dirpath, _, filenames in os.walk(base):
        for fn in filenames:
            if not fn.lower().endswith(".md"):
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, base)
            if fn.upper() == "SKILL.MD":
                skill = os.path.basename(os.path.dirname(full))
            else:
                skill = os.path.splitext(os.path.basename(full))[0]
            if skill:
                names.add(skill)
for n in sorted(names):
    print(n)
PYEOF
}

_read_hooks_from_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  python3 -c "
import json
try:
    data = json.load(open('$f'))
    for event in sorted(data.get('hooks', {}).keys()): print(event)
except Exception: pass
" 2>/dev/null
}
_read_global_hooks()  { _read_hooks_from_file "$HOME/.claude/settings.json"; }
_read_project_hooks() { _read_hooks_from_file "$1/.claude/settings.json"; }

_suggest_tools_for_stack() {
  local s; s="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
  echo "$s" | grep -qiE "typescript|javascript|node" && \
    echo "mcp:context7:Context7 — up-to-date library docs (npx -y @upstash/context7-mcp)"
  echo "$s" | grep -qiE "python" && \
    echo "mcp:context7:Context7 — library docs for Python (npx -y @upstash/context7-mcp)"
  echo "$s" | grep -qiE "docker|container" && \
    echo "mcp:docker:Docker MCP gateway (docker mcp gateway run)"
  echo "$s" | grep -qiE "sentry" && \
    echo "mcp:sentry:Sentry error tracking (HTTP: https://mcp.sentry.dev/mcp)"
  echo "$s" | grep -qiE "linear" && \
    echo "mcp:linear:Linear project management (npx mcp-remote https://mcp.linear.app/sse)"
  echo "$s" | grep -qiE "github" && \
    echo "mcp:github:GitHub MCP server (npx -y @modelcontextprotocol/server-github)"
  echo "$s" | grep -qiE "postgres|mysql|sqlite|sql" && \
    echo "mcp:database:SQLite MCP server (npx -y @modelcontextprotocol/server-sqlite)"
  echo "$s" | grep -qiE "typescript|javascript" && \
    echo "plugin:typescript-lsp:TypeScript language server plugin"
  echo "$s" | grep -qiE "python" && \
    echo "plugin:pyright-lsp:Pyright Python language server plugin"
  echo "$s" | grep -qiE "rust" && \
    echo "plugin:rust-analyzer-lsp:Rust Analyzer language server plugin"
  echo "$s" | grep -qiE "golang" && \
    echo "plugin:gopls-lsp:Go language server plugin"
  echo "$s" | grep -qiE "csharp|dotnet" && \
    echo "plugin:csharp-lsp:C# language server plugin"
  echo "$s" | grep -qiE "github" && \
    echo "plugin:github:GitHub integration plugin"
  echo "$s" | grep -qiE "jira|atlassian" && \
    echo "plugin:atlassian:Jira/Confluence integration plugin"
  echo "$s" | grep -qiE "figma" && \
    echo "plugin:figma:Figma design integration plugin"
  echo "$s" | grep -qiE "playwright|testing|e2e" && \
    echo "plugin:playwright:Playwright browser automation plugin"
  echo "$s" | grep -qiE "postgres|mysql|sqlite|sql" && \
    echo "skill:database-query:Skill for writing safe SQL queries and migrations"
  echo "$s" | grep -qiE "typescript|javascript|python|rust|csharp" && \
    echo "skill:code-review:Skill for thorough code reviews with security checks"
  echo "$s" | grep -qiE "git|github" && \
    echo "skill:commit-message:Skill for writing conventional commit messages"
  echo "$s" | grep -qiE "typescript|javascript" && \
    echo "instruction:tests:Path instruction for test files (glob: **/*.test.ts,**/*.spec.ts)"
  echo "$s" | grep -qiE "python" && \
    echo "instruction:tests:Path instruction for Python tests (glob: test_*.py)"
  echo "$s" | grep -qiE "typescript|javascript|python|rust|csharp" && \
    echo "instruction:docs:Path instruction for docs (glob: **/*.md,docs/**)"
}

_add_mcp_to_project() {
  local root="$1" name="$2" cmd_str="$3"
  shift 3
  local args_json; args_json="$(python3 -c "import json,sys; print(json.dumps(sys.argv[1:]))" -- "$@")"
  python3 - "$root/.mcp.json" "$name" "$cmd_str" "$args_json" << 'PYEOF'
import json, os, sys
path, name, command, args_json = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
args = json.loads(args_json)
data = {}
if os.path.exists(path):
    try: data = json.load(open(path))
    except Exception: data = {}
data.setdefault('mcpServers', {})[name] = {'command': command, 'args': args}
with open(path, 'w') as f: json.dump(data, f, indent=2); f.write('\n')
PYEOF
  mkdir -p "$root/.vscode"
  python3 - "$root/.vscode/mcp.json" "$name" "$cmd_str" "$args_json" << 'PYEOF'
import json, os, sys
path, name, command, args_json = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
args = json.loads(args_json)
data = {}
if os.path.exists(path):
    try: data = json.load(open(path))
    except Exception: data = {}
data.setdefault('servers', {})[name] = {'type': 'stdio', 'command': command, 'args': args}
data.setdefault('inputs', [])
with open(path, 'w') as f: json.dump(data, f, indent=2); f.write('\n')
PYEOF
}

_scaffold_skill() {
  local root="$1" name="$2" desc="${3:-A custom skill for this project}"
  local claude_file="$root/.claude/skills/$name/SKILL.md"
  local copilot_repo_file="$root/.github/copilot/skills/$name/SKILL.md"
  local copilot_local_file="$root/.copilot/skills/$name/SKILL.md"
  local created=0

  for f in "$claude_file" "$copilot_repo_file" "$copilot_local_file"; do
    mkdir -p "$(dirname "$f")"
    if [[ -f "$f" ]]; then
      warn "Skill already exists: $f"
      continue
    fi
    cat > "$f" << SKILL
# Skill: $name

$desc

## When to use this skill

<!-- Describe trigger conditions -->

## Steps

1.

## Notes

<!-- Caveats and edge cases -->
SKILL
    created=$((created + 1))
    success "Created skill: $f"
  done

  if (( created > 0 )); then
    info "Skill is available for Claude and Copilot project skill paths."
  fi
}

_add_path_instruction() {
  local root="$1" name="$2" glob_pattern="${3:-**/*.md}"
  local dir="$root/.github/instructions"
  mkdir -p "$dir"
  local f="$dir/${name}.instructions.md"
  if [[ -f "$f" ]]; then warn "Path instruction already exists: $f"; return 0; fi
  cat > "$f" << INSTR
---
applyTo: "$glob_pattern"
---

# Instructions for: $name

<!-- Instructions for files matching: $glob_pattern -->
<!-- Applied in addition to .github/copilot-instructions.md -->
INSTR
  success "Created path instruction: $f"
  info "Edit ${CYAN}$f${RESET} to add guidance for ${CYAN}$glob_pattern${RESET} files"
}

_merge_hook_to_project_settings() {
  local root="$1" event="$2" matcher="${3:-.*}" script="$4"
  python3 - "$root/.claude/settings.json" "$event" "$matcher" "$script" << 'PYEOF'
import json, os, sys
path, event, matcher, script = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
data = {}
if os.path.exists(path):
    try: data = json.load(open(path))
    except Exception: data = {}
data.setdefault('hooks', {}).setdefault(event, []).append(
    {'matcher': matcher, 'hooks': [{'type': 'command', 'command': script}]}
)
with open(path, 'w') as f: json.dump(data, f, indent=2); f.write('\n')
PYEOF
}

cmd_tools_audit() {
  load_config
  local root; root="$(find_project_root)"
  step "🔍 DevLoop Tools Audit"
  divider

  echo -e "\n  ${BOLD}Claude MCP Servers${RESET}"
  local g_mcps; g_mcps="$(_read_global_claude_mcp)"
  local p_mcps; p_mcps="$(_read_project_claude_mcp "$root")"
  local v_mcps; v_mcps="$(_read_project_vscode_mcp "$root")"

  echo -e "    ${CYAN}Global (~/.claude.json):${RESET}"
  if [[ -n "$g_mcps" ]]; then
    echo "$g_mcps" | while IFS= read -r name; do
      if echo "$p_mcps" | grep -qx "$name" 2>/dev/null; then
        echo -e "      • $name ${GREEN}[in project ✔]${RESET}"
      else
        echo -e "      • $name ${YELLOW}[global only — run sync to copy]${RESET}"
      fi
    done
  else
    echo -e "      ${GRAY}(none)${RESET}"
  fi

  echo -e "    ${CYAN}Project (.mcp.json / Claude):${RESET}"
  [[ -n "$p_mcps" ]] && echo "$p_mcps" | sed 's/^/      • /' || echo -e "      ${GRAY}(none)${RESET}"

  echo -e "    ${CYAN}Project (.vscode/mcp.json / Copilot):${RESET}"
  if [[ -n "$v_mcps" ]]; then
    echo "$v_mcps" | sed 's/^/      • /'
  else
    echo -e "      ${GRAY}(none — run ${CYAN}devloop tools sync${GRAY} to populate)${RESET}"
  fi

  echo -e "\n  ${BOLD}Claude Skills${RESET}"
  local g_skills; g_skills="$(_read_global_claude_skills)"
  local p_skills; p_skills="$(_read_project_claude_skills "$root")"
  echo -e "    ${CYAN}Global (~/.claude/skills/):${RESET}"
  [[ -n "$g_skills" ]] && echo "$g_skills" | sed 's/^/      • /' || echo -e "      ${GRAY}(none)${RESET}"
  echo -e "    ${CYAN}Project (.claude/skills/):${RESET}"
  [[ -n "$p_skills" ]] && echo "$p_skills" | sed 's/^/      • /' || echo -e "      ${GRAY}(none)${RESET}"

  echo -e "\n  ${BOLD}Copilot Skills${RESET}"
  local p_copilot_skills; p_copilot_skills="$(_read_project_copilot_skills "$root")"
  echo -e "    ${CYAN}Project (.github/copilot/skills/ + .copilot/skills/):${RESET}"
  [[ -n "$p_copilot_skills" ]] && echo "$p_copilot_skills" | sed 's/^/      • /' || echo -e "      ${GRAY}(none)${RESET}"

  echo -e "\n  ${BOLD}Claude Plugins (global)${RESET}"
  local plugins; plugins="$(_read_global_claude_plugins)"
  [[ -n "$plugins" ]] && echo "$plugins" | sed 's/^/    • /' || echo -e "    ${GRAY}(none installed)${RESET}"

  echo -e "\n  ${BOLD}Claude Hooks${RESET}"
  local g_h; g_h="$(_read_global_hooks | tr '\n' ' ')"
  local p_h; p_h="$(_read_project_hooks "$root" | tr '\n' ' ')"
  echo -e "    ${CYAN}Global events:${RESET}  ${g_h:-${GRAY}(none)}"
  echo -e "    ${CYAN}Project events:${RESET} ${p_h:-${GRAY}(none)}"

  echo -e "\n  ${BOLD}Copilot Instructions${RESET}"
  local ci_status="${RED}missing — run devloop init${RESET}"
  [[ -f "$root/.github/copilot-instructions.md" ]] && ci_status="${GREEN}present${RESET}"
  echo -e "    ${CYAN}.github/copilot-instructions.md:${RESET} $ci_status"
  local path_instrs; path_instrs="$(ls "$root/.github/instructions/"*.instructions.md 2>/dev/null || true)"
  if [[ -n "$path_instrs" ]]; then
    echo -e "    ${CYAN}Path-specific instructions:${RESET}"
    echo "$path_instrs" | xargs -I{} basename {} | sed 's/^/      • /'
  else
    echo -e "    ${CYAN}Path-specific instructions:${RESET} ${GRAY}(none)${RESET}"
  fi

  divider
  echo -e "\n  ${CYAN}devloop tools suggest${RESET} — stack-based recommendations"
  echo -e "  ${CYAN}devloop tools sync${RESET}    — copy global tools to project\n"
}

cmd_tools_suggest() {
  load_config
  local root; root="$(find_project_root)"
  step "💡 DevLoop Tools Suggestions"

  local stack="${PROJECT_STACK:-}"
  if [[ -z "$stack" ]]; then
    warn "PROJECT_STACK not set in devloop.config.sh"
    echo -e "  Example: ${CYAN}PROJECT_STACK=\"typescript github docker\"${RESET}\n"
    return 0
  fi

  echo -e "  Stack: ${CYAN}$stack${RESET}\n"
  divider

  local suggestions; suggestions="$(_suggest_tools_for_stack "$stack")"
  if [[ -z "$suggestions" ]]; then
    echo -e "  ${GRAY}No suggestions for this stack. Try: typescript, python, docker, github, sentry${RESET}\n"
    return 0
  fi

  echo -e "  ${BOLD}Recommended Tools:${RESET}\n"
  local idx=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local t; t="$(echo "$line" | cut -d: -f1)"
    local n; n="$(echo "$line" | cut -d: -f2)"
    local d; d="$(echo "$line" | cut -d: -f3-)"
    idx=$(( idx + 1 ))
    local badge=""
    case "$t" in
      mcp)         badge="${BLUE}[MCP]       ${RESET}" ;;
      plugin)      badge="${MAGENTA}[Plugin]    ${RESET}" ;;
      skill)       badge="${GREEN}[Skill]     ${RESET}" ;;
      instruction) badge="${CYAN}[Instruction]${RESET}" ;;
    esac
    echo -e "  $idx. $badge ${BOLD}$n${RESET}"
    echo -e "       ${GRAY}$d${RESET}"
  done <<< "$suggestions"

  echo ""
  divider
  echo -e "\n  Run ${CYAN}devloop tools add${RESET} to install interactively\n"
}

cmd_tools_add() {
  load_config
  local root; root="$(find_project_root)"
  local filter="${1:-}"

  step "➕ DevLoop Tools Add"

  case "$filter" in
    --mcp|--skill|--instruction|--plugin)
      shift 2>/dev/null || true
      _tools_add_explicit "$root" "$filter" "$@"
      return 0
      ;;
  esac

  local stack="${PROJECT_STACK:-}"
  local suggestions=""
  [[ -n "$stack" ]] && suggestions="$(_suggest_tools_for_stack "$stack")"

  if [[ -z "$suggestions" ]]; then
    warn "No suggestions. Set PROJECT_STACK in devloop.config.sh or use explicit flags:"
    echo -e "    ${CYAN}devloop tools add --mcp <name> <command> [args...]${RESET}"
    echo -e "    ${CYAN}devloop tools add --skill <name> [description]${RESET}"
    echo -e "    ${CYAN}devloop tools add --instruction <name> [glob]${RESET}"
    echo ""
    return 0
  fi

  local types=() names=() descs=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    types+=("$(echo "$line" | cut -d: -f1)")
    names+=("$(echo "$line" | cut -d: -f2)")
    descs+=("$(echo "$line" | cut -d: -f3-)")
  done <<< "$suggestions"

  echo -e "  ${BOLD}Select tools to install (comma-separated numbers or 'all'):${RESET}\n"
  local i
  for i in "${!names[@]}"; do
    local badge=""
    case "${types[$i]}" in
      mcp)         badge="${BLUE}[MCP]       ${RESET}" ;;
      plugin)      badge="${MAGENTA}[Plugin]    ${RESET}" ;;
      skill)       badge="${GREEN}[Skill]     ${RESET}" ;;
      instruction) badge="${CYAN}[Instruction]${RESET}" ;;
    esac
    echo -e "  $(( i + 1 )). $badge ${BOLD}${names[$i]}${RESET}"
    echo -e "       ${GRAY}${descs[$i]}${RESET}"
  done

  echo ""
  printf "  Enter selection [1-%d, all, q to quit]: " "${#names[@]}"
  read -r selection
  [[ "$selection" == "q" ]] && return 0

  local selected=()
  if [[ "$selection" == "all" ]]; then
    for i in "${!names[@]}"; do selected+=("$i"); done
  else
    IFS=',' read -ra parts <<< "$selection"
    for part in "${parts[@]}"; do
      part="${part// /}"
      if [[ "$part" =~ ^[0-9]+$ ]]; then
        local idx=$(( part - 1 ))
        (( idx >= 0 && idx < ${#names[@]} )) && selected+=("$idx")
      fi
    done
  fi

  [[ ${#selected[@]} -eq 0 ]] && { warn "No valid selection"; return 0; }

  echo ""
  for idx in "${selected[@]}"; do
    local t="${types[$idx]}" n="${names[$idx]}" d="${descs[$idx]}"
    case "$t" in
      mcp)
        step "Installing MCP: $n"
        local mcp_cmd="" mcp_args=()
        if echo "$d" | grep -q "(npx "; then
          local fc; fc="$(echo "$d" | grep -oE '\(npx [^)]+\)' | tr -d '()')"
          mcp_cmd="npx"; IFS=' ' read -ra _p <<< "$fc"; mcp_args=("${_p[@]:1}")
        elif echo "$d" | grep -q "(docker "; then
          local fc; fc="$(echo "$d" | grep -oE '\(docker [^)]+\)' | tr -d '()')"
          mcp_cmd="docker"; IFS=' ' read -ra _p <<< "$fc"; mcp_args=("${_p[@]:1}")
        elif echo "$d" | grep -q "HTTP:"; then
          local url; url="$(echo "$d" | grep -oE 'https://[^ )]+' | head -1)"
          mcp_cmd="npx"; mcp_args=("mcp-remote" "$url")
          info "HTTP MCP proxied via npx mcp-remote"
        else
          warn "Cannot auto-detect command for '$n' — use: devloop tools add --mcp $n <command>"; continue
        fi
        _add_mcp_to_project "$root" "$n" "$mcp_cmd" "${mcp_args[@]}"
        success "Added MCP '$n' to .mcp.json + .vscode/mcp.json"
        ;;
      plugin)
        step "Plugin: $n"
        warn "Plugins require an interactive Claude session:"
        echo -e "    ${CYAN}claude plugin install $n@claude-plugins-official${RESET}"
        ;;
      skill)
        step "Creating skill: $n"
        _scaffold_skill "$root" "$n" "$d"
        ;;
      instruction)
        step "Creating path instruction: $n"
        local glob="**/*.md"
        case "$n" in
          tests)
            local sl; sl="$(echo "${stack:-}" | tr '[:upper:]' '[:lower:]')"
            echo "$sl" | grep -qiE "python" && glob="test_*.py,*_test.py" || glob="**/*.test.ts,**/*.spec.ts"
            ;;
          docs) glob="**/*.md,**/*.mdx,docs/**" ;;
        esac
        _add_path_instruction "$root" "$n" "$glob"
        ;;
    esac
  done

  echo ""
  success "Done. Run ${CYAN}devloop tools audit${RESET} to review."
  echo ""
}

_tools_add_explicit() {
  local root="$1" flag="$2"
  shift 2
  case "$flag" in
    --mcp)
      local name="${1:-}" cmd_str="${2:-}"
      [[ -z "$name" || -z "$cmd_str" ]] && { warn "Usage: devloop tools add --mcp <name> <command> [args...]"; return 1; }
      shift 2
      _add_mcp_to_project "$root" "$name" "$cmd_str" "$@"
      success "Added MCP '$name' to .mcp.json + .vscode/mcp.json"
      ;;
    --skill)
      local name="${1:-}" desc="${2:-A custom skill for this project}"
      [[ -z "$name" ]] && { warn "Usage: devloop tools add --skill <name> [description]"; return 1; }
      _scaffold_skill "$root" "$name" "$desc"
      ;;
    --instruction)
      local name="${1:-}" glob="${2:-**/*.md}"
      [[ -z "$name" ]] && { warn "Usage: devloop tools add --instruction <name> [glob]"; return 1; }
      _add_path_instruction "$root" "$name" "$glob"
      ;;
    --plugin)
      local name="${1:-}"
      [[ -z "$name" ]] && { warn "Usage: devloop tools add --plugin <name>"; return 1; }
      warn "Plugins require an interactive Claude session:"
      echo -e "  ${CYAN}claude plugin install $name@claude-plugins-official${RESET}"
      ;;
  esac
}

cmd_tools_sync() {
  load_config
  local root; root="$(find_project_root)"
  step "🔄 DevLoop Tools Sync (global → project)"
  divider

  echo -e "\n  ${BOLD}MCP Servers${RESET}"
  local g_mcps; g_mcps="$(_read_global_claude_mcp)"
  local p_mcps; p_mcps="$(_read_project_claude_mcp "$root")"

  if [[ -z "$g_mcps" ]]; then
    echo -e "    ${GRAY}No global MCP servers found${RESET}"
  else
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      if echo "$p_mcps" | grep -qx "$name" 2>/dev/null; then
        echo -e "    ${GREEN}✔${RESET}  $name ${GRAY}(already in project)${RESET}"
        continue
      fi
      printf "  Copy global MCP '%s' to project? [y/N] " "$name"
      read -r ans
      if [[ "$ans" =~ ^[Yy] ]]; then
        local srv_cmd srv_args_str
        srv_cmd="$(python3 -c "import json; d=json.load(open('$HOME/.claude.json')); print(d.get('mcpServers',{}).get('$name',{}).get('command',''))" 2>/dev/null)"
        srv_args_str="$(python3 -c "import json; d=json.load(open('$HOME/.claude.json')); print(' '.join(d.get('mcpServers',{}).get('$name',{}).get('args',[])))" 2>/dev/null)"
        IFS=' ' read -ra srv_args <<< "$srv_args_str"
        _add_mcp_to_project "$root" "$name" "$srv_cmd" "${srv_args[@]}"
        echo -e "    ${GREEN}✔${RESET}  $name copied to .mcp.json + .vscode/mcp.json"
      fi
    done <<< "$g_mcps"
  fi

  echo -e "\n  ${BOLD}Skills${RESET}"
  local g_skills; g_skills="$(_read_global_claude_skills)"
  local p_skills; p_skills="$(_read_project_claude_skills "$root")"

  if [[ -z "$g_skills" ]]; then
    echo -e "    ${GRAY}No global skills found (~/.claude/skills/)${RESET}"
  else
    while IFS= read -r skill; do
      [[ -z "$skill" ]] && continue
      if echo "$p_skills" | grep -qx "$skill" 2>/dev/null; then
        echo -e "    ${GREEN}✔${RESET}  $skill ${GRAY}(already in project)${RESET}"
        continue
      fi
      printf "  Copy global skill '%s' to project? [y/N] " "$skill"
      read -r ans
      if [[ "$ans" =~ ^[Yy] ]]; then
        local dst="$root/.claude/skills/$skill"
        mkdir -p "$dst"
        cp -r "$HOME/.claude/skills/$skill/." "$dst/"
        echo -e "    ${GREEN}✔${RESET}  $skill copied"
      fi
    done <<< "$g_skills"
  fi

  divider
  echo -e "\n  Run ${CYAN}devloop tools audit${RESET} to see the updated state\n"
}

cmd_tools() {
  local subcmd="${1:-audit}"
  shift 2>/dev/null || true
  case "$subcmd" in
    audit)   cmd_tools_audit   "$@" ;;
    suggest) cmd_tools_suggest "$@" ;;
    add)     cmd_tools_add     "$@" ;;
    sync)    cmd_tools_sync    "$@" ;;
    *)
      error "Unknown tools subcommand: $subcmd"
      echo -e "  Usage: ${CYAN}devloop tools [audit|suggest|add|sync]${RESET}"
      exit 1
      ;;
  esac
}

# ── cmd: failover ─────────────────────────────────────────────────────────────

cmd_failover() {
  load_config
  local subcmd="${1:-status}"
  shift 2>/dev/null || true

  case "$subcmd" in
    status)
      _health_load
      step "🔄 Provider Failover Status"
      divider
      local configured_main; configured_main="$(main_provider)"
      local configured_worker; configured_worker="$(worker_provider)"
      local effective_main; effective_main="$(effective_main_provider)"
      local effective_worker; effective_worker="$(effective_worker_provider)"

      echo -e "  ${BOLD}Failover enabled:${RESET} ${DEVLOOP_FAILOVER_ENABLED:-true}"
      echo -e "  ${BOLD}Probe interval:${RESET}   every ${DEVLOOP_PROBE_INTERVAL:-5}m (checks if limited provider is back)"
      echo ""
      echo -e "  ${BOLD}Main provider${RESET}"
      echo -e "    Configured: $(provider_label "$configured_main")"
      if [[ -n "$HEALTH_MAIN_OVERRIDE" ]]; then
        local age=$(( $(date +%s) - ${HEALTH_MAIN_LIMITED_SINCE:-0} ))
        local age_min=$(( age / 60 ))
        local last_probe="${HEALTH_MAIN_LAST_PROBE:-0}"
        local since_probe=$(( $(date +%s) - last_probe ))
        local probe_min=$(( since_probe / 60 ))
        local next_min=$(( ${DEVLOOP_PROBE_INTERVAL:-5} - probe_min ))
        [[ $next_min -lt 0 ]] && next_min=0
        echo -e "    ${YELLOW}⚠️  Limited!${RESET} Switched to: $(provider_label "$HEALTH_MAIN_OVERRIDE") (${age_min}m ago)"
        if [[ "$last_probe" == "0" || -z "$last_probe" ]]; then
          echo -e "    Probe: will run on next devloop command"
        else
          echo -e "    Last probed: ${probe_min}m ago | Next probe in: ~${next_min}m"
        fi
      else
        echo -e "    ${GREEN}✔  Healthy${RESET} — active: $(provider_label "$effective_main")"
      fi
      echo ""
      echo -e "  ${BOLD}Worker provider${RESET}"
      echo -e "    Configured: $(provider_label "$configured_worker")"
      if [[ -n "$HEALTH_WORKER_OVERRIDE" ]]; then
        local age=$(( $(date +%s) - ${HEALTH_WORKER_LIMITED_SINCE:-0} ))
        local age_min=$(( age / 60 ))
        local last_probe="${HEALTH_WORKER_LAST_PROBE:-0}"
        local since_probe=$(( $(date +%s) - last_probe ))
        local probe_min=$(( since_probe / 60 ))
        local next_min=$(( ${DEVLOOP_PROBE_INTERVAL:-5} - probe_min ))
        [[ $next_min -lt 0 ]] && next_min=0
        echo -e "    ${YELLOW}⚠️  Limited!${RESET} Switched to: $(provider_label "$HEALTH_WORKER_OVERRIDE") (${age_min}m ago)"
        if [[ "$last_probe" == "0" || -z "$last_probe" ]]; then
          echo -e "    Probe: will run on next devloop command"
        else
          echo -e "    Last probed: ${probe_min}m ago | Next probe in: ~${next_min}m"
        fi
      else
        echo -e "    ${GREEN}✔  Healthy${RESET} — active: $(provider_label "$effective_worker")"
      fi
      divider
      echo ""
      ;;
    reset)
      _health_load
      HEALTH_MAIN_LIMITED_SINCE=""
      HEALTH_MAIN_OVERRIDE=""
      HEALTH_WORKER_LIMITED_SINCE=""
      HEALTH_WORKER_OVERRIDE=""
      _health_save
      success "Provider health state cleared — all providers restored to configured values"
      echo -e "  Main:   $(provider_label "$(main_provider)")"
      echo -e "  Worker: $(provider_label "$(worker_provider)")"
      echo ""
      ;;
    main|worker)
      # devloop failover main copilot   → force main override to copilot
      # devloop failover main clear     → clear main override
      local role="$subcmd"
      local target="${1:-}"
      if [[ -z "$target" ]]; then
        error "Usage: devloop failover $role <provider|clear>"
        exit 1
      fi
      if [[ "$target" == "clear" ]]; then
        _health_clear "$role"
        success "Cleared $role override — restored to configured provider"
      else
        if [[ "$role" == "main" ]]; then
          normalize_provider "$target" > /dev/null || exit 1
        else
          normalize_worker_provider "$target" > /dev/null || exit 1
        fi
        _health_load
        local ts; ts="$(date +%s)"
        if [[ "$role" == "main" ]]; then
          HEALTH_MAIN_LIMITED_SINCE="$ts"
          HEALTH_MAIN_OVERRIDE="$target"
        else
          HEALTH_WORKER_LIMITED_SINCE="$ts"
          HEALTH_WORKER_OVERRIDE="$target"
        fi
        _health_save
        warn "Manual override: $role provider → $(provider_label "$target")"
        info "To restore: devloop failover $role clear"
      fi
      echo ""
      ;;
    probe)
      # devloop failover probe — test all configured providers right now
      local main_p; main_p="$(main_provider)"
      local worker_p; worker_p="$(worker_provider)"
      step "🩺 Probing providers..."
      divider
      echo -n "  Main   ($(provider_label "$main_p")): "
      if _probe_provider "$main_p"; then
        echo -e "${GREEN}OK${RESET}"
      else
        echo -e "${RED}RATE LIMITED${RESET}"
      fi
      if [[ "$worker_p" != "$main_p" ]]; then
        echo -n "  Worker ($(provider_label "$worker_p")): "
        if _probe_provider "$worker_p"; then
          echo -e "${GREEN}OK${RESET}"
        else
          echo -e "${RED}RATE LIMITED${RESET}"
        fi
      fi
      divider
      echo ""
      ;;
    *)
      error "Unknown failover subcommand: $subcmd"
      echo -e "  Usage: ${CYAN}devloop failover [status|reset|probe|main <provider|clear>|worker <provider|clear>]${RESET}"
      exit 1
      ;;
  esac
}

# ── _run_respec_phase: re-architect and retry after max fix rounds exhausted ──
# Called from cmd_run when DEVLOOP_FIX_STRATEGY=escalate and all fix rounds fail.
# Redesigns the spec using accumulated failure context, then runs work + review.
# Returns: 0 if APPROVED, 1 if still failing.

_run_respec_phase() {
  local id="$1"
  local fix_history_text="$2"
  local spec_file="$SPECS_PATH/$id.md"
  local review_file="$SPECS_PATH/$id-review.md"

  step "🏗  Re-architecting spec after repeated fix failures..."
  info "Recurring issues will be used to guide spec redesign"
  echo ""

  # Build respec prompt
  local orig_spec=""
  [[ -f "$spec_file" ]] && orig_spec="$(cat "$spec_file")"

  local respec_prompt
  respec_prompt="You are redesigning a task spec that has repeatedly failed code review.
The original implementation kept getting NEEDS_WORK despite multiple fix attempts.
Your job: rewrite the spec to be clearer, more precise, and avoid the recurring pitfalls.

## Original Spec
$orig_spec

## Full Review & Fix History (what kept failing)
$fix_history_text

## Your Task
1. Identify the ROOT CAUSE of repeated failures (ambiguous requirements? missing edge cases? wrong approach?)
2. Redesign the spec to eliminate those root causes
3. Add explicit acceptance criteria for every issue that kept recurring
4. Be more prescriptive about implementation details where workers went wrong

Output a complete revised spec in the SAME format as the original.
Keep the same task ID ($id) and title, but mark Status as: ♻️ respecced
Start the spec with: # $id (Respecced)"

  local main_p; main_p="$(effective_main_provider)"
  info "Calling $(provider_label "$main_p") to redesign spec..."
  echo ""

  # Write respec output directly to spec file (overwrite)
  local tmp_respec; tmp_respec="$(mktemp /tmp/devloop-respec-XXXXXX)"
  run_provider_prompt "$main_p" "$respec_prompt" "$tmp_respec"

  if [[ -s "$tmp_respec" ]]; then
    cp "$tmp_respec" "$spec_file"
    rm -f "$tmp_respec"
    success "Spec redesigned: ${CYAN}$id${RESET}"
    echo ""
  else
    rm -f "$tmp_respec"
    warn "Re-architect produced no output — skipping respec phase"
    return 1
  fi

  # Update git baseline for fresh diff
  local base_hash; base_hash="$(git rev-parse HEAD 2>/dev/null || echo "")"
  [[ -n "$base_hash" ]] && echo "$base_hash" > "$SPECS_PATH/$id.pre-commit"

  # Work with redesigned spec
  step "🔨 Re-implementing with redesigned spec..."
  cmd_work "$id"
  echo ""

  # Review with 2 chances
  local respec_verdict="NEEDS_WORK"
  local respec_round=0
  local respec_max=2

  while [[ "$respec_verdict" != "APPROVED" && "$respec_verdict" != "REJECTED" && $respec_round -le $respec_max ]]; do
    respec_round=$(( respec_round + 1 ))
    step "🔍 Re-reviewing after respec (attempt $respec_round/$respec_max)..."
    cmd_review "$id"
    echo ""
    respec_verdict="$(parse_review_verdict "$review_file")"

    case "$respec_verdict" in
      APPROVED) break ;;
      REJECTED)
        error "❌ REJECTED after respec — stopping"
        return 1
        ;;
      NEEDS_WORK)
        if (( respec_round < respec_max )); then
          step "🔧 Final fix attempt after respec..."
          cmd_fix "$id"
          echo ""
        fi
        ;;
    esac
  done

  if [[ "$respec_verdict" == "APPROVED" ]]; then
    return 0
  else
    return 1
  fi
}

# ── cmd: run (full automated pipeline) ───────────────────────────────────────
# Runs the full architect → work → review → [fix → review]* loop in one shot.
# Usage: devloop run "description" [--type TYPE] [--files hints] [--max-retries N] [--no-learn] [--no-respec]

cmd_run() {
  local feature="${1:-}"
  local task_type="feature"
  local file_hints=""
  local max_retries=3
  local skip_learn=false
  local no_respec=false
  shift 2>/dev/null || true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type|-t)        task_type="${2:-feature}"; shift 2 ;;
      --files|-F)       file_hints="${2:-}";       shift 2 ;;
      --max-retries|-n) max_retries="${2:-3}";     shift 2 ;;
      --no-learn)       skip_learn=true;           shift   ;;
      --no-respec)      no_respec=true;            shift   ;;
      *)                shift ;;
    esac
  done

  if [[ -z "$feature" ]]; then
    error "Usage: devloop run \"<description>\" [--type TYPE] [--files hints] [--max-retries N] [--no-learn] [--no-respec]"
    echo -e "  ${GRAY}Example: devloop run \"add dark mode toggle\"${RESET}"
    echo -e "  ${GRAY}Example: devloop run \"fix login redirect\" --type bug${RESET}"
    exit 1
  fi

  load_config
  ensure_dirs
  check_deps
  _maybe_show_version_hint

  # Determine fix strategy: escalate (default) or standard
  local fix_strategy="${DEVLOOP_FIX_STRATEGY:-escalate}"
  # deep_threshold: rounds 1..threshold use standard fix; above uses deep fix
  local deep_threshold=$(( (max_retries + 1) / 2 ))

  step "🚀 Full pipeline: ${BOLD}\"$feature\"${RESET}"
  echo -e "  ${GRAY}Stages: arch → work → review → [fix loop ×$max_retries max]${RESET}"
  if [[ "$fix_strategy" == "escalate" && "$no_respec" == "false" ]]; then
    echo -e "  ${GRAY}Strategy: standard fix (1-$deep_threshold) → deep fix ($((deep_threshold+1))-$max_retries) → re-architect${RESET}"
  fi
  divider
  echo ""

  # ── Stage 1: Architect ───────────────────────────────────────────────────────
  step "📐 [1] Architecting..."

  # Snapshot existing specs so we can identify the newly-created one
  local before_specs=""
  before_specs="$(ls -t "$SPECS_PATH"/*.md 2>/dev/null | grep -v '\-review\.md' || true)"

  cmd_architect "$feature" "$task_type" "$file_hints"

  # Identify the new spec by diffing the directory listing
  local id=""
  while IFS= read -r f; do
    if [[ -n "$f" ]] && ! echo "$before_specs" | grep -qF "$f"; then
      id="$(basename "$f" .md)"
      break
    fi
  done < <(ls -t "$SPECS_PATH"/*.md 2>/dev/null | grep -v '\-review\.md' || true)

  # Fallback: newest file (safe if no concurrent runs)
  if [[ -z "$id" ]]; then
    local latest_spec
    latest_spec="$(ls -t "$SPECS_PATH"/*.md 2>/dev/null | grep -v '\-review\.md' | head -1 || true)"
    [[ -n "$latest_spec" ]] && id="$(basename "$latest_spec" .md)"
  fi

  if [[ -z "$id" ]]; then
    error "Architect did not produce a spec. Aborting pipeline."
    exit 1
  fi

  success "Spec: ${CYAN}$id${RESET}"
  echo ""

  # ── Stage 2: Work ────────────────────────────────────────────────────────────
  step "🔨 [2] Implementing..."
  cmd_work "$id"
  echo ""

  # ── Stage 3: Review + fix loop (3-phase escalation) ─────────────────────────
  local verdict="NEEDS_WORK"
  local fix_round=0
  local unknown_round=0
  local max_unknown_retries=2
  local review_file="$SPECS_PATH/$id-review.md"
  # Accumulate all review content for deep-fix and respec context
  local fix_history_parts=()

  while [[ "$verdict" != "APPROVED" && "$verdict" != "REJECTED" ]]; do
    if (( fix_round == 0 )); then
      step "🔍 [3] Reviewing..."
    else
      local phase_label="standard"
      (( fix_round > deep_threshold )) && phase_label="deep"
      step "🔍 Re-reviewing (fix $fix_round/$max_retries — $phase_label)..."
    fi

    cmd_review "$id"
    echo ""

    verdict="$(parse_review_verdict "$review_file")"

    case "$verdict" in
      APPROVED)
        break
        ;;
      REJECTED)
        error "❌ REJECTED — pipeline stopped"
        echo -e "  ${GRAY}Task: ${CYAN}$id${RESET}"
        echo -e "  ${GRAY}Review: ${CYAN}devloop status $id${RESET}"
        exit 1
        ;;
      NEEDS_WORK)
        unknown_round=0
        # Snapshot this review into history
        if [[ -f "$review_file" ]]; then
          fix_history_parts+=("=== Review after fix round $fix_round ===
$(cat "$review_file")
")
        fi

        fix_round=$(( fix_round + 1 ))

        if (( fix_round > max_retries )); then
          # ── Phase 3: Re-architect (escalate strategy only) ──────────────
          if [[ "$fix_strategy" == "escalate" && "$no_respec" == "false" ]]; then
            warn "⚠  Max fix retries ($max_retries) reached — escalating to re-architect phase"
            echo ""
            local combined_history=""
            local h
            for h in "${fix_history_parts[@]}"; do
              combined_history+="$h"$'\n'
            done
            if _run_respec_phase "$id" "$combined_history"; then
              verdict="APPROVED"
            else
              warn "Re-architect phase also could not get APPROVED"
              echo -e "  ${GRAY}Task needs manual review: ${CYAN}devloop status $id${RESET}"
              echo -e "  ${GRAY}Options:"
              echo -e "    ${CYAN}devloop fix $id${RESET}    — try another fix manually"
              echo -e "    ${CYAN}devloop status $id${RESET} — read full review"
              exit 2
            fi
            break
          else
            warn "⚠  Max fix retries ($max_retries) reached — task left as NEEDS_WORK"
            echo -e "  ${GRAY}Continue manually:  ${CYAN}devloop fix $id${RESET}  then  ${CYAN}devloop review $id${RESET}"
            echo -e "  ${GRAY}Tip: ${CYAN}devloop run ... --no-respec${GRAY} disabled re-architect; remove it to enable${RESET}"
            exit 2
          fi
        fi

        # ── Phase 1 or 2: standard vs deep fix ──────────────────────────
        if (( fix_round <= deep_threshold )); then
          step "🔧 Fixing (attempt $fix_round/$max_retries — standard)..."
          cmd_fix "$id"
        else
          step "🔧 Fixing (attempt $fix_round/$max_retries — deep: injecting review history)..."
          local combined_history=""
          local h
          for h in "${fix_history_parts[@]}"; do
            combined_history+="$h"$'\n'
          done
          cmd_fix --history "$combined_history" "$id"
        fi
        echo ""
        ;;
      *)
        unknown_round=$(( unknown_round + 1 ))
        warn "Could not determine verdict from review output: $review_file"
        echo -e "  ${GRAY}Expected first non-empty line:${RESET} ${CYAN}Verdict: APPROVED|NEEDS_WORK|REJECTED${RESET}"
        if (( unknown_round >= max_unknown_retries )); then
          error "Unknown verdict repeated ($unknown_round/$max_unknown_retries). Stopping to avoid infinite retry loop."
          echo -e "  ${GRAY}Fix:${RESET} Re-run reviewer with canonical verdict line, then run ${CYAN}devloop review $id${RESET}"
          exit 2
        fi
        warn "Retrying review once more before stopping..."
        ;;
    esac
  done

  # ── Stage 4: Learn ───────────────────────────────────────────────────────────
  if [[ "$skip_learn" == "false" ]]; then
    step "📚 Extracting lessons into CLAUDE.md..."
    cmd_learn "$id" 2>/dev/null || true
    echo ""
  fi

  divider
  success "✅ Pipeline complete: ${CYAN}$id${RESET}"
  if (( fix_round > 0 )); then
    echo -e "  ${GRAY}Approved after $fix_round fix round(s)${RESET}"
  fi
  echo ""
}

# ── cmd: queue (batch task management) ────────────────────────────────────────
# Manages a queue of tasks to run sequentially via devloop run.
# Queue file: .devloop/queue.txt  (one task per line: TYPE|description)

_queue_file() {
  local root; root="$(find_project_root)"
  echo "$root/$DEVLOOP_DIR/queue.txt"
}

cmd_queue() {
  local subcmd="${1:-list}"
  shift 2>/dev/null || true

  case "$subcmd" in
    add)
      local task_type="feature"
      local description=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --type|-t) task_type="${2:-feature}"; shift 2 ;;
          *)         description="${description:+$description }$1"; shift ;;
        esac
      done

      if [[ -z "$description" ]]; then
        error "Usage: devloop queue add [--type TYPE] \"<description>\""
        exit 1
      fi

      load_config
      local qfile; qfile="$(_queue_file)"
      mkdir -p "$(dirname "$qfile")"
      echo "$task_type|$description" >> "$qfile"
      success "Queued: [${GRAY}$task_type${RESET}] $description"
      echo -e "  ${GRAY}Run all: ${CYAN}devloop queue run${RESET}"
      ;;

    list|ls)
      load_config
      local qfile; qfile="$(_queue_file)"
      if [[ ! -f "$qfile" ]] || [[ ! -s "$qfile" ]]; then
        info "Queue is empty."
        echo -e "  ${GRAY}Add tasks: ${CYAN}devloop queue add \"description\"${RESET}"
        return
      fi
      step "📋 Pending tasks:"
      local i=0
      while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        i=$(( i + 1 ))
        local t_type="${line%%|*}"
        local t_desc="${line#*|}"
        echo -e "  ${CYAN}$i.${RESET} ${GRAY}[$t_type]${RESET} $t_desc"
      done < "$qfile"
      echo ""
      echo -e "  ${GRAY}Run all: ${CYAN}devloop queue run${RESET}"
      ;;

    run)
      load_config
      ensure_dirs
      check_deps

      local max_retries=3
      local stop_on_fail=false
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --max-retries|-n) max_retries="${2:-3}"; shift 2 ;;
          --stop-on-fail)   stop_on_fail=true;    shift   ;;
          *)                shift ;;
        esac
      done

      local qfile; qfile="$(_queue_file)"
      if [[ ! -f "$qfile" ]] || [[ ! -s "$qfile" ]]; then
        info "Queue is empty. Nothing to run."
        echo -e "  ${GRAY}Add tasks: ${CYAN}devloop queue add \"description\"${RESET}"
        return
      fi

      # Count total pending tasks
      local total=0
      while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        total=$(( total + 1 ))
      done < "$qfile"

      step "🚀 Processing $total queued task(s)..."
      divider

      local done_count=0
      local failed_count=0
      local task_num=0
      local tmp_remaining; tmp_remaining="$(mktemp /tmp/devloop_queue_XXXXXX)"
      local stop_now=false

      while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        [[ "$stop_now" == "true" ]] && { echo "$line" >> "$tmp_remaining"; continue; }

        task_num=$(( task_num + 1 ))
        local t_type="${line%%|*}"
        local t_desc="${line#*|}"

        echo ""
        divider
        step "  [Task $task_num/$total] ${BOLD}\"$t_desc\"${RESET}  ${GRAY}($t_type)${RESET}"
        divider
        echo ""

        local rc=0
        cmd_run "$t_desc" --type "$t_type" --max-retries "$max_retries" || rc=$?

        if (( rc == 0 )); then
          done_count=$(( done_count + 1 ))
          success "  ✓ Task $task_num done"
        else
          failed_count=$(( failed_count + 1 ))
          warn "  ✗ Task $task_num failed (exit $rc)"
          echo "$line" >> "$tmp_remaining"
          if [[ "$stop_on_fail" == "true" ]]; then
            warn "Stopping queue (--stop-on-fail is set)"
            stop_now=true
          fi
        fi
      done < "$qfile"

      # Replace queue with failed/remaining tasks
      if [[ -s "$tmp_remaining" ]]; then
        cp "$tmp_remaining" "$qfile"
        warn "$failed_count task(s) failed — kept in queue for retry"
        echo -e "  ${GRAY}Retry: ${CYAN}devloop queue run${RESET}"
      else
        : > "$qfile"
        success "All $total task(s) completed ✅"
      fi
      rm -f "$tmp_remaining"

      divider
      echo -e "  ${GREEN}✓ Done: $done_count${RESET}  ${YELLOW}✗ Failed: $failed_count${RESET}  Total: $total"
      echo ""
      ;;

    clear)
      load_config
      local qfile; qfile="$(_queue_file)"
      if [[ -f "$qfile" ]]; then
        : > "$qfile"
        success "Queue cleared"
      else
        info "Queue already empty"
      fi
      ;;

    *)
      echo -e "${BOLD}devloop queue${RESET} — batch task management\n"
      echo -e "  ${CYAN}devloop queue add [--type TYPE] \"description\"${RESET}"
      echo -e "    Add a task to the queue\n"
      echo -e "  ${CYAN}devloop queue list${RESET}  ${GRAY}alias: ls${RESET}"
      echo -e "    Show all pending tasks\n"
      echo -e "  ${CYAN}devloop queue run [--max-retries N] [--stop-on-fail]${RESET}"
      echo -e "    Run every queued task through the full pipeline\n"
      echo -e "  ${CYAN}devloop queue clear${RESET}"
      echo -e "    Empty the queue\n"
      echo -e "  ${GRAY}Queue file: .devloop/queue.txt${RESET}"
      ;;
  esac
}

# ── cmd: help ─────────────────────────────────────────────────────────────────

cmd_help() {
  echo -e "${BOLD}COMMANDS${RESET}\n"
  echo -e "  ${CYAN}devloop do \"<natural language task>\"${RESET}  ${GRAY}aliases: ask, please, nl${RESET}"
  echo -e "    Run any task described in plain English — no quoting needed for unambiguous phrases"
  echo -e "    ${GRAY}Equivalent to: devloop run \"...\", but handles short sentences and avoids command conflicts${RESET}"
  echo -e "    ${GRAY}Example: devloop do check the latest progress and work on remaining tasks${RESET}\n"
  echo -e "  ${CYAN}devloop install${RESET}"
  echo -e "    Install devloop to /usr/local/bin (run once)\n"
  echo -e "  ${CYAN}devloop init [--yes|-y] [--configure|-c]${RESET}"
  echo -e "    Set up DevLoop in current project (auto-analyzes stack/config from project files)"
  echo -e "    Runs interactive setup wizard on first init. Use ${GRAY}--yes${RESET} to skip wizard."
  echo -e "    Use ${GRAY}--configure${RESET} to re-run the wizard on an existing project.\n"
  echo -e "  ${CYAN}devloop configure${RESET}  ${GRAY}aliases: setup, wizard${RESET}"
  echo -e "    Re-run the interactive setup wizard to change providers, models, and permissions"
  echo -e "    Updates devloop.config.sh and regenerates agent prompt files.\n"
  echo -e "  ${CYAN}devloop run \"feature\" [--type TYPE] [--files hints] [--max-retries N] [--no-learn] [--no-respec]${RESET}  ${GRAY}alias: go${RESET}"
  echo -e "    Full automated pipeline: architect → work → review → fix loop → learn"
  echo -e "    Fix escalation (DEVLOOP_FIX_STRATEGY=escalate, default):"
  echo -e "      Rounds 1-N/2: standard fix   |  Rounds N/2-N: deep fix (history injected)  |  After N: re-architect"
  echo -e "    ${GRAY}--no-respec${RESET}  skip the re-architect phase after all fix rounds are exhausted"
  echo -e "    One command replaces: architect + work + review + fix + review + ...\n"
  echo -e "  ${CYAN}devloop queue [add|list|run|clear]${RESET}  ${GRAY}alias: q${RESET}"
  echo -e "    Batch mode: queue multiple tasks and run them all sequentially"
  echo -e "    ${GRAY}add [--type TYPE] \"desc\"${RESET}  — enqueue a task"
  echo -e "    ${GRAY}list${RESET}                     — show pending tasks"
  echo -e "    ${GRAY}run [--stop-on-fail]${RESET}     — process all queued tasks"
  echo -e "    ${GRAY}clear${RESET}                    — empty the queue\n"
  echo -e "  ${CYAN}devloop start [project-name]${RESET}  ${GRAY}alias: s${RESET}"
  echo -e "    Launch provider session + orchestrator agent"
  echo -e "    Claude: remote-control (access from mobile/browser); Copilot: local interactive"
  echo -e "    Prevents Mac sleep via caffeinate for session duration\n"
  echo -e "  ${CYAN}devloop daemon [project-name]${RESET}  ${GRAY}alias: d${RESET}"
  echo -e "    Run in background with auto-restart + sleep prevention"
  echo -e "    Claude: remote-control daemon; Copilot: local session (no remote access)"
  echo -e "    Registers launchd (macOS) or systemd (Linux) for auto-start on login"
  echo -e "    Sub-commands: stop | status | log | uninstall\n"
  echo -e "  ${CYAN}devloop architect \"feature\" [type] [files]${RESET}  ${GRAY}alias: a${RESET}"
  echo -e "    Main provider designs an implementation spec (called by orchestrator)\n"
  echo -e "  ${CYAN}devloop work [TASK-ID]${RESET}  ${GRAY}alias: w${RESET}"
  echo -e "    Launch configured worker provider to implement the full spec\n"
  echo -e "  ${CYAN}devloop review [TASK-ID]${RESET}  ${GRAY}alias: r${RESET}"
  echo -e "    Main provider reviews git diff → APPROVED / NEEDS_WORK / REJECTED\n"
  echo -e "  ${CYAN}devloop fix [TASK-ID]${RESET}  ${GRAY}alias: f${RESET}"
  echo -e "    Launch configured worker provider with review fix instructions\n"
  echo -e "  ${CYAN}devloop tasks${RESET}  ${GRAY}alias: t${RESET}"
  echo -e "    List all task specs with status\n"
  echo -e "  ${CYAN}devloop status [TASK-ID]${RESET}"
  echo -e "    Show full spec and latest review\n"
  echo -e "  ${CYAN}devloop open [TASK-ID]${RESET}  ${GRAY}alias: o${RESET}"
  echo -e "    Open spec in \$EDITOR (defaults to vi)\n"
  echo -e "  ${CYAN}devloop block [TASK-ID]${RESET}  ${GRAY}alias: b${RESET}"
  echo -e "    Print the Copilot Instructions Block for a task\n"
  echo -e "  ${CYAN}devloop clean [--days N] [--dry-run]${RESET}"
  echo -e "    Remove finalized (approved/rejected) specs older than N days (default: 30)"
  echo -e "    Use ${CYAN}--dry-run${RESET} to preview what would be removed\n"
  echo -e "  ${CYAN}devloop learn [TASK-ID]${RESET}"
  echo -e "    Extract lessons from the latest review and append to CLAUDE.md\n"
  echo -e "  ${CYAN}devloop agent-sync${RESET} ${GRAY}(aliases: sync-agents, agentsync)${RESET}"
  echo -e "    Check provider versions, refresh cached docs (24h TTL), and use main AI"
  echo -e "    to analyse what's new. Updates CLAUDE.md with latest provider insights."
  echo -e "    Cached in: ${GRAY}.devloop/agent-docs/${RESET}\n"
  echo -e "  ${CYAN}devloop failover [status|reset|probe|main <p|clear>|worker <p|clear>]${RESET}"
  echo -e "    Manage automatic provider failover when rate limits hit"
  echo -e "    ${GRAY}status${RESET}  — show active overrides and recovery time"
  echo -e "    ${GRAY}reset${RESET}   — clear all overrides, restore configured providers"
  echo -e "    ${GRAY}probe${RESET}   — test all providers right now"
  echo -e "    ${GRAY}main/worker <provider>${RESET}   — force a manual override"
  echo -e "    Auto-chain: main claude→copilot, worker copilot→opencode→pi\n"
  echo -e "  ${CYAN}devloop check${RESET}"
  echo -e "    Check for the latest DevLoop version on GitHub (no config needed)\n"
  echo -e "  ${CYAN}devloop hooks${RESET}"
  echo -e "    Install Claude pipeline hooks (.claude/settings.json + hook scripts)"
  echo -e "    Includes: PreToolUse permission hook + PostToolUse audit hook\n"
  echo -e "  ${CYAN}devloop permit [subcmd]${RESET}  ${GRAY}← manage permission requests${RESET}"
  echo -e "    ${GRAY}status${RESET}           — show pending permission requests"
  echo -e "    ${GRAY}watch${RESET}            — interactive prompt for pending requests"
  echo -e "    ${GRAY}grant [id]${RESET}       — allow latest (or named) pending request"
  echo -e "    ${GRAY}deny [id]${RESET}        — deny latest (or named) pending request"
  echo -e "    ${GRAY}log${RESET}              — view permissions audit log"
  echo -e "    ${GRAY}mode <mode>${RESET}      — set mode: off|auto|smart|strict\n"
  echo -e "  ${CYAN}devloop logs [-f|--follow]${RESET}"
  echo -e "    View recent pipeline/notification/session logs (or tail with -f)\n"
  echo -e "  ${CYAN}devloop doctor${RESET}"
  echo -e "    Validate all DevLoop dependencies and configuration\n"
  echo -e "  ${CYAN}devloop ci${RESET}"
  echo -e "    Generate .github/workflows/devloop-review.yml for CI-triggered review\n"
  echo -e "  ${CYAN}devloop tools [audit|suggest|add|sync]${RESET}"
  echo -e "    Manage MCP servers, cross-agent skills (Claude + Copilot), plugins, and path instructions"
  echo -e "    ${GRAY}audit${RESET}   — show global vs project tool inventory"
  echo -e "    ${GRAY}suggest${RESET} — stack-based tool recommendations"
  echo -e "    ${GRAY}add${RESET}     — interactive install (or: --mcp --skill --instruction --plugin)"
  echo -e "    ${GRAY}sync${RESET}    — copy global tools to project level\n"
  echo -e "  ${CYAN}devloop --version${RESET} ${GRAY}or${RESET} ${CYAN}devloop -v${RESET}"
  echo -e "    Print installed DevLoop version\n"
  echo -e "  ${CYAN}devloop update${RESET}"
  echo -e "    Self-upgrade devloop from GitHub (no config needed) + refresh project configs\n"
  echo -e "${BOLD}SETUP (one-time)${RESET}\n"
  echo -e "  ${GRAY}# Install devloop globally${RESET}"
  echo -e "  ${CYAN}curl -fsSL https://raw.githubusercontent.com/shaifulshabuj/devloop/main/devloop.sh -o /tmp/devloop${RESET}"
  echo -e "  ${CYAN}chmod +x /tmp/devloop && sudo mv /tmp/devloop /usr/local/bin/devloop${RESET}\n"
  echo -e "  ${GRAY}# In each project (interactive wizard on first run):${RESET}"
  echo -e "  ${CYAN}cd your-project/${RESET}"
  echo -e "  ${CYAN}devloop init${RESET}              ${GRAY}← runs setup wizard, auto-detects stack${RESET}"
  echo -e "  ${CYAN}devloop init --yes${RESET}        ${GRAY}← skip wizard, use auto-detected defaults${RESET}"
  echo -e "  ${CYAN}devloop configure${RESET}         ${GRAY}← re-run wizard anytime to change settings${RESET}"
  echo -e "  ${CYAN}devloop hooks${RESET}             ${GRAY}← install pipeline hooks${RESET}"
  echo -e "  ${CYAN}devloop tools suggest${RESET}     ${GRAY}← discover stack-specific tools${RESET}"
  echo -e "  ${CYAN}devloop start${RESET}             ${GRAY}← Claude: connect from mobile/browser | Copilot: local terminal${RESET}\n"
  echo -e "${BOLD}REQUIREMENTS${RESET}\n"
  echo -e "  ${CYAN}claude${RESET}    Claude Code CLI   ${GRAY}curl -fsSL https://claude.ai/install.sh | bash${RESET}"
  echo -e "  ${CYAN}copilot${RESET}   Copilot CLI        ${GRAY}npm install -g @github/copilot${RESET}"
  echo -e "  ${CYAN}gh${RESET}        GitHub CLI         ${GRAY}brew install gh  (required for github-agent mode)${RESET}"
  echo -e "  ${CYAN}git${RESET}       Git\n"
  echo -e "${BOLD}PROVIDER ROUTING & FAILOVER${RESET}\n"
  echo -e "  ${BOLD}DEVLOOP_MAIN_PROVIDER${RESET}   Role: orchestrator / architect / reviewer"
  echo -e "  ${BOLD}DEVLOOP_WORKER_PROVIDER${RESET} Role: work / fix\n"
  echo -e "  Supported combinations:"
  echo -e "  ${CYAN}claude${RESET}    + ${CYAN}copilot${RESET}   main=Claude, worker=Copilot   ${GRAY}(default)${RESET}"
  echo -e "  ${CYAN}claude${RESET}    + ${CYAN}claude${RESET}    main=Claude, worker=Claude"
  echo -e "  ${CYAN}copilot${RESET}   + ${CYAN}copilot${RESET}   main=Copilot, worker=Copilot"
  echo -e "  ${CYAN}copilot${RESET}   + ${CYAN}claude${RESET}    main=Copilot, worker=Claude"
  echo -e "  ${CYAN}claude${RESET}    + ${CYAN}opencode${RESET}  main=Claude, worker=OpenCode  ${GRAY}(optional install)${RESET}"
  echo -e "  ${CYAN}claude${RESET}    + ${CYAN}pi${RESET}        main=Claude, worker=Pi        ${GRAY}(optional install)${RESET}"
  echo -e "  ${GRAY}Note: opencode and pi are worker-only (no remote control support)${RESET}\n"
  echo -e "  ${BOLD}Session capabilities (devloop start / daemon):${RESET}"
  echo -e "  ${CYAN}claude${RESET} as main → remote-control session (claude.ai/code + Claude mobile app)"
  echo -e "  ${CYAN}copilot${RESET} as main → local interactive terminal session only (no remote access)\n"
  echo -e "  ${BOLD}Auto-failover${RESET} (DEVLOOP_FAILOVER_ENABLED=true):"
  echo -e "  When a provider hits its rate limit, DevLoop auto-switches to the next in chain:"
  echo -e "  Main:   ${CYAN}claude → copilot${RESET}"
  echo -e "  Worker: ${CYAN}copilot → opencode → pi${RESET}"
  echo -e "  Original provider is probed every ${CYAN}DEVLOOP_PROBE_INTERVAL${RESET} minutes (default 5)"
  echo -e "  and restored immediately when available again — no fixed wait time"
  echo -e "  Run ${CYAN}devloop failover status${RESET} to check current state\n"
  echo -e "${BOLD}MODEL CONFIGURATION${RESET}\n"
  echo -e "  ${BOLD}CLAUDE_MODEL${RESET}        Base model for all Claude roles (default: sonnet)"
  echo -e "  ${BOLD}CLAUDE_MAIN_MODEL${RESET}   Model for architect/reviewer/orchestrator (overrides CLAUDE_MODEL)"
  echo -e "  ${BOLD}CLAUDE_WORKER_MODEL${RESET} Model for worker/fix passes (overrides CLAUDE_MODEL)"
  echo -e "  Available: ${CYAN}sonnet${RESET} (balanced), ${CYAN}opus${RESET} (most capable), ${CYAN}haiku${RESET} (fast/cheap)"
  echo -e "  Example: CLAUDE_MAIN_MODEL=opus CLAUDE_WORKER_MODEL=sonnet"
  echo -e "  ${BOLD}Copilot model${RESET}: set at ${CYAN}github.com/settings/copilot${RESET} — no CLI flag available\n"
  echo -e "${BOLD}SMART PERMISSIONS${RESET}\n"
  echo -e "  DevLoop intercepts every Bash tool call via Claude's PreToolUse hook."
  echo -e "  Commands are classified and handled without blocking the pipeline:\n"
  echo -e "  ${BOLD}Modes${RESET} (DEVLOOP_PERMISSION_MODE in devloop.config.sh):"
  echo -e "  ${CYAN}smart${RESET}    BLOCK dangerous, ALLOW safe, ESCALATE everything else ${GRAY}(default)${RESET}"
  echo -e "  ${CYAN}auto${RESET}     ALLOW everything (fastest, no interruptions)"
  echo -e "  ${CYAN}strict${RESET}   ALLOW safe ops only, BLOCK everything else + ask user"
  echo -e "  ${CYAN}off${RESET}      Disable hook entirely (Claude's default behaviour)\n"
  echo -e "  ${BOLD}Always BLOCKED${RESET}:  rm -rf / or ~, curl|bash, dd to /dev/sd*, mkfs, sudo rm -rf"
  echo -e "  ${BOLD}Always ALLOWED${RESET}: cat/grep/find/ls, git status/log/diff, pytest/npm test/cargo test,"
  echo -e "                   builds, package install from lockfile, linters\n"
  echo -e "  ${BOLD}Escalation${RESET} (unknown commands):"
  echo -e "    1. Terminal prompt (/dev/tty) — works in foreground sessions"
  echo -e "    2. macOS dialog (osascript)   — works in daemon/background mode"
  echo -e "    3. Queue file + devloop permit watch — Linux / headless fallback"
  echo -e "    Auto-deny after DEVLOOP_PERMISSION_TIMEOUT seconds (default: 60)\n"
  echo -e "  ${CYAN}devloop permit watch${RESET}   — monitor and respond to pending escalations"
  echo -e "  ${CYAN}devloop permit mode auto${RESET} — disable escalations entirely\n"
  echo -e "${BOLD}FIX ESCALATION STRATEGY${RESET}\n"
  echo -e "  Controls what happens when the review loop keeps returning NEEDS_WORK:"
  echo -e "  ${CYAN}escalate${RESET} (default)"
  echo -e "    Phase 1 (rounds 1..N/2):   standard fix — latest review fed to worker"
  echo -e "    Phase 2 (rounds N/2+1..N): deep fix — ALL prior review history injected so worker"
  echo -e "                               understands why previous attempts failed"
  echo -e "    Phase 3 (after N rounds):  re-architect — spec rewritten using failure context,"
  echo -e "                               then a fresh work+review cycle (2 attempts)"
  echo -e "  ${CYAN}standard${RESET}"
  echo -e "    Hard cap: after N failed fix rounds the pipeline exits with NEEDS_WORK (old behavior)\n"
  echo -e "  Set ${CYAN}DEVLOOP_FIX_STRATEGY${RESET} in devloop.config.sh"
  echo -e "  Use ${CYAN}--no-respec${RESET} flag on ${CYAN}devloop run${RESET} to skip Phase 3 for a single run\n"
  echo -e "${BOLD}WORKER MODES${RESET}\n"
  echo -e "  ${CYAN}cli${RESET}            Use copilot or claude CLI locally (default)"
  echo -e "  ${CYAN}github-agent${RESET}   Create GitHub Issue; Copilot coding agent opens a PR"
  echo -e "  Set ${CYAN}DEVLOOP_WORKER_MODE${RESET} in devloop.config.sh\n"
}

# ── cmd: do — natural-language entry point ────────────────────────────────────
# Accepts free-text without quoting conflicts (e.g. devloop do check the status)
# Joins all args into one sentence and passes to cmd_run.

cmd_do() {
  if [[ $# -eq 0 ]]; then
    error "Usage: devloop do \"<natural language task>\""
    echo -e "  ${GRAY}Example: ${CYAN}devloop do check the latest progress and work on remaining tasks${RESET}"
    echo -e "  ${GRAY}Example: ${CYAN}devloop do review the codebase and fix any bugs you find${RESET}"
    exit 1
  fi
  load_config
  ensure_dirs
  check_deps
  _maybe_show_version_hint

  # Join all args into a single task description
  local _task="$*"
  step "🗣  Natural language task: ${BOLD}\"$_task\"${RESET}"
  divider
  echo ""
  cmd_run "$_task"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  local cmd="${1:-help}"
  shift 2>/dev/null || true

  case "$cmd" in
    -v|-V|--version|version) echo -e "${CYAN}${BOLD}devloop${RESET} v${VERSION}"; exit 0 ;;
    --help|-h) header; cmd_help; exit 0 ;;
  esac

  header

  # ── Natural-language pre-detection ─────────────────────────────────────────
  # When a "utility" command (that takes no positional args) is followed by
  # plain-English words (not flags or task IDs), treat the whole thing as NL.
  # e.g. "devloop check the latest progress..." → cmd_do instead of cmd_check
  local _zero_arg_cmds=" check update status doctor agent-sync sync-agents agentsync logs clean ci tools failover hooks start daemon tasks "
  if [[ " $_zero_arg_cmds " == *" $cmd "* ]] && [[ $# -gt 0 ]]; then
    local _has_flag=false _has_task_id=false _a
    for _a in "$@"; do
      [[ "$_a" == -* ]]        && { _has_flag=true;    break; }
      [[ "$_a" == TASK-* ]]    && { _has_task_id=true; break; }
    done
    if [[ "$_has_flag" == "false" ]] && [[ "$_has_task_id" == "false" ]]; then
      local _nl_input="$cmd $*"
      info "Interpreted as natural language — routing to pipeline"
      echo -e "  ${GRAY}Tip: ${CYAN}devloop do $cmd $*${GRAY} to be explicit next time${RESET}"
      echo ""
      cmd_do "$cmd" "$@"
      return
    fi
  fi

  case "$cmd" in
    do|ask|please|nl) cmd_do      "$@" ;;
    install)          cmd_install  "$@" ;;
    init)             cmd_init     "$@" ;;
    configure|setup|wizard) cmd_configure "$@" ;;
    start|s)          cmd_start    "$@" ;;
    daemon|d)         cmd_daemon   "$@" ;;
    run|go)           cmd_run      "$@" ;;
    queue|q)          cmd_queue    "$@" ;;
    architect|a)      cmd_architect "$@" ;;
    work|w)           cmd_work     "$@" ;;
    review|r)         cmd_review   "$@" ;;
    fix|f)            cmd_fix      "$@" ;;
    tasks|t)          cmd_tasks    "$@" ;;
    status)           cmd_status   "$@" ;;
    open|o)           cmd_open     "$@" ;;
    block|b)          cmd_block    "$@" ;;
    clean)            cmd_clean    "$@" ;;
    learn)            cmd_learn    "$@" ;;
    check)            cmd_check    "$@" ;;
    agent-sync|sync-agents|agentsync) cmd_agent_sync "$@" ;;
    failover)         cmd_failover "$@" ;;
    permit)           cmd_permit   "$@" ;;
    hooks)            cmd_hooks    "$@" ;;
    logs)             cmd_logs     "$@" ;;
    doctor)           cmd_doctor   "$@" ;;
    ci)               cmd_ci       "$@" ;;
    tools)            cmd_tools    "$@" ;;
    update)           cmd_update   "$@" ;;
    help)             cmd_help ;;
    *)
      # Unknown command: if it looks like natural language, route to NL pipeline
      local _nl_candidate="$cmd${*:+ $*}"
      if [[ "$cmd" != -* ]] && [[ "$_nl_candidate" == *" "* ]]; then
        info "Unknown command — interpreting as natural language task"
        echo -e "  ${GRAY}Tip: ${CYAN}devloop do $_nl_candidate${GRAY} to be explicit next time${RESET}"
        echo ""
        cmd_do "$cmd" "$@"
      else
        error "Unknown command: $cmd"
        echo ""
        echo -e "  ${GRAY}Tip: ${CYAN}devloop do \"<description>\"${GRAY} — natural language pipeline${RESET}"
        echo -e "  ${GRAY}     ${CYAN}devloop run \"<description>\"${GRAY} — explicit full pipeline${RESET}"
        echo -e "  ${GRAY}     ${CYAN}devloop help${GRAY}              — all commands${RESET}"
        exit 1
      fi
      ;;
  esac
}

main "$@"
