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
#   devloop start               — launch Claude remote control + orchestrator agent
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

VERSION="4.1.0"
DEVLOOP_DIR=".devloop"
SPECS_DIR="$DEVLOOP_DIR/specs"
PROMPTS_DIR="$DEVLOOP_DIR/prompts"
AGENTS_DIR=".claude/agents"
CONFIG_FILE="devloop.config.sh"
DEVLOOP_SOURCE_URL="${DEVLOOP_SOURCE_URL:-}"   # set to enable 'devloop update'

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
  DEVLOOP_MAIN_PROVIDER="claude"
  DEVLOOP_WORKER_PROVIDER="copilot"
  DEVLOOP_WORKER_MODE="cli"
  DEVLOOP_VERSION_URL=""
  DEVLOOP_FAILOVER_ENABLED="true"
  DEVLOOP_PROBE_INTERVAL="5"    # minutes between availability probes when a provider is limited
  DEVLOOP_PERMISSION_MODE="smart"   # off | auto | smart | strict
  DEVLOOP_PERMISSION_TIMEOUT="60"   # seconds to wait for user response on escalated permissions

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
      if ! echo "Reply with exactly: OK" | copilot > "$tmp" 2>&1; then
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

_check_version_bg() {
  local url="${DEVLOOP_VERSION_URL:-}"
  [[ -z "$url" ]] && return
  local root; root="$(find_project_root)"
  local hint_file="$root/$DEVLOOP_DIR/.version-hint"
  (
    local tmp; tmp="$(mktemp /tmp/devloop-ver.XXXXXX)"
    if command -v curl &>/dev/null; then
      curl -fsSL "$url" -o "$tmp" 2>/dev/null || { rm -f "$tmp"; exit 0; }
    elif command -v wget &>/dev/null; then
      wget -qO "$tmp" "$url" 2>/dev/null || { rm -f "$tmp"; exit 0; }
    else
      rm -f "$tmp"; exit 0
    fi
    local remote_ver; remote_ver="$(head -1 "$tmp" | tr -d '[:space:]')"
    rm -f "$tmp"
    if [[ -n "$remote_ver" && "$remote_ver" != "$VERSION" ]]; then
      echo "$remote_ver" > "$hint_file"
    fi
  ) >/dev/null 2>&1 &
}

cmd_check() {
  load_config
  local url="${DEVLOOP_VERSION_URL:-}"
  if [[ -z "$url" ]]; then
    warn "DEVLOOP_VERSION_URL not configured"
    echo ""
    echo -e "${BOLD}To enable version checks, add to devloop.config.sh:${RESET}"
    echo -e "  ${CYAN}DEVLOOP_VERSION_URL=\"https://raw.githubusercontent.com/you/devloop/main/VERSION\"${RESET}"
    echo ""
    echo -e "The VERSION file should contain a single semver line, e.g.: ${GRAY}3.0.0${RESET}"
    return
  fi
  step "🔍 Checking for DevLoop updates..."
  local tmp; tmp="$(mktemp /tmp/devloop-ver.XXXXXX)"
  if command -v curl &>/dev/null; then
    curl -fsSL "$url" -o "$tmp" 2>/dev/null || { warn "Could not reach $url"; rm -f "$tmp"; return; }
  elif command -v wget &>/dev/null; then
    wget -qO "$tmp" "$url" 2>/dev/null || { warn "Could not reach $url"; rm -f "$tmp"; return; }
  else
    error "Neither curl nor wget found"; rm -f "$tmp"; return
  fi
  local remote_ver; remote_ver="$(head -1 "$tmp" | tr -d '[:space:]')"
  rm -f "$tmp"
  if [[ -z "$remote_ver" ]]; then
    warn "Could not read version from manifest at: $url"
    return
  fi
  if [[ "$remote_ver" == "$VERSION" ]]; then
    success "Up to date — ${BOLD}v$VERSION${RESET}"
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
    echo "- **Non-interactive:** \`echo \"/plan <prompt>\" | copilot\`"
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
    echo "| copilot | main+worker | \`echo \"\$prompt\" | copilot\` | /plan |"
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

  # Version check
  if [[ -n "${DEVLOOP_VERSION_URL:-}" ]]; then
    local tmp; tmp="$(mktemp /tmp/devloop-ver.XXXXXX)"
    ok="false"
    if command -v curl &>/dev/null; then
      curl -fsSL "$DEVLOOP_VERSION_URL" -o "$tmp" 2>/dev/null && ok="true"
    fi
    if [[ "$ok" == "true" ]]; then
      local remote_ver; remote_ver="$(head -1 "$tmp" | tr -d '[:space:]')"
      rm -f "$tmp"
      if [[ "$remote_ver" == "$VERSION" ]]; then
        _chk "version up to date (v$VERSION)" "true"
      else
        _chk "version up to date (local: v$VERSION, remote: v$remote_ver)" "false" "devloop update"
      fi
    else
      rm -f "$tmp"
      _chk "version check (URL unreachable)" "false" "Check DEVLOOP_VERSION_URL in config"
    fi
  else
    echo -e "  ${GRAY}—  version check skipped (DEVLOOP_VERSION_URL not set)${RESET}"
  fi

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
        if ! echo "$prompt" | claude -p --model "$CLAUDE_MODEL" > "$tmp_out" 2>&1; then
          echo "$prompt" | claude -p > "$tmp_out" 2>&1 || rc=$?
        fi
        ;;
      copilot)
        echo "$prompt" | copilot > "$tmp_out" 2>&1 || rc=$?
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
      info "Original provider $(provider_label "$provider") will be re-tested after ${DEVLOOP_RECOVERY_HOURS:-6}h"
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

# Model for claude -p calls when a role uses Claude
# "sonnet" = faster/cheaper   "opus" = more capable
CLAUDE_MODEL="sonnet"

# Optional: URL to a VERSION file (single semver line) for update checks
# DEVLOOP_VERSION_URL="https://raw.githubusercontent.com/you/devloop/main/VERSION"

# Optional: set to enable 'devloop update'
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
Then connect from claude.ai/code or the Claude mobile app.

## DevLoop commands
- `devloop architect "feature"` — design a spec
- `devloop work [TASK-ID]`      — launch worker to implement
- `devloop review [TASK-ID]`    — review implementation
- `devloop fix [TASK-ID]`       — launch worker with fix instructions
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
- `devloop check`               — check for DevLoop updates
- `devloop update`              — self-upgrade devloop

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
  load_config
  ensure_dirs

  step "Initializing DevLoop in: ${CYAN}$(basename "$(find_project_root)")${RESET}"
  divider

  # 1. Project config
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

  # Reload so generated files reflect the analyzed project configuration
  load_config

  # 2. Write agent definitions — FIX #5: pass CLAUDE_MODEL so agents stay in sync with config
  write_agent_orchestrator
  success "Agent: ${CYAN}$AGENTS_PATH/devloop-orchestrator.md${RESET}"
  write_agent_architect "$CLAUDE_MODEL"
  success "Agent: ${CYAN}$AGENTS_PATH/devloop-architect.md${RESET}"
  write_agent_reviewer "$CLAUDE_MODEL"
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

_launch_claude() {
  local project_name="$1"
  claude \
    --remote-control "DevLoop: $project_name" \
    --agent devloop-orchestrator \
    --permission-mode acceptEdits
}

cmd_start() {
  load_config
  check_deps
  _verify_agents

  local project_name="${1:-$PROJECT_NAME}"
  local main_backend; main_backend="$(main_provider)"
  local worker_backend; worker_backend="$(worker_provider)"

  step "Starting DevLoop for: ${CYAN}$project_name${RESET}"
  divider
  echo ""

  # Non-blocking version check — result shown on next start if update exists
  _check_version_bg
  local root; root="$(find_project_root)"
  local hint_file="$root/$DEVLOOP_DIR/.version-hint"
  if [[ -f "$hint_file" ]]; then
    local remote_ver; remote_ver="$(cat "$hint_file")"
    rm -f "$hint_file"
    warn "DevLoop ${GREEN}v${remote_ver}${RESET} available — run ${CYAN}devloop update${RESET}"
    echo ""
  fi

  echo -e "${BOLD}Launching:${RESET}"
  echo -e "  ${CYAN}--remote-control${RESET}      accessible from mobile + browser"
  echo -e "  ${CYAN}--agent orchestrator${RESET}  main thread is the orchestrator"
  echo -e "  ${CYAN}caffeinate -is${RESET}        Mac stays awake while session runs"
  echo -e "  ${CYAN}providers${RESET}             main=$(provider_label "$main_backend"), worker=$(provider_label "$worker_backend")"
  echo ""
  echo -e "${BOLD}Connect from:${RESET}"
  echo -e "  📱 Claude app → find ${CYAN}\"DevLoop: $project_name\"${RESET} with green dot"
  echo -e "  🌐 ${CYAN}https://claude.ai/code${RESET} → session list"
  echo ""
  echo -e "${GRAY}Press Ctrl+C to stop.${RESET}"
  divider
  echo ""

  CAFFEINATE_PID=""
  _prevent_sleep
  trap '_stop_sleep_prevention; exit 0' INT TERM EXIT
  _launch_claude "$project_name"
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

    echo "[$(date)] DevLoop daemon started for: $project_name" > "$log_file"

    while (( attempt < max_restarts )); do
      attempt=$(( attempt + 1 ))
      echo "[$(date)] Starting session (attempt $attempt/$max_restarts)" >> "$log_file"

      [[ -n "$cafpid" ]] && kill "$cafpid" 2>/dev/null || true
      /usr/bin/caffeinate -is &
      cafpid=$!

      _launch_claude "$project_name" >> "$log_file" 2>&1
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
  echo -e "  📱 Claude app → ${CYAN}\"DevLoop: $project_name\"${RESET}"
  echo -e "  🌐 ${CYAN}https://claude.ai/code${RESET}"
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
        if ! cat "$tmp_spec" | claude -p --model "$CLAUDE_MODEL" > "$tmp_out" 2>&1; then
          cat "$tmp_spec" | claude -p > "$tmp_out" 2>&1 || rc=$?
        fi
        ;;
      opencode)
        opencode run --file "$tmp_spec" "Implement the DevLoop task spec in the attached file exactly as described. Stage ALL changed files and commit with the TASK ID in the message. Summarize what was implemented." 2>&1 | tee "$tmp_out" || rc=$?
        ;;
      pi)
        pi --mode json "$launch_prompt" 2>&1 | tee "$tmp_out" | cat || rc=$?
        ;;
      *)  # copilot
        cat "$tmp_spec" | copilot 2>&1 | tee "$tmp_out" || rc=$?
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
    printf '\n### Verdict: APPROVED | NEEDS_WORK | REJECTED\n'
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
  verdict="$(grep -o 'Verdict: \(APPROVED\|NEEDS_WORK\|REJECTED\)' "$review_file" 2>/dev/null | head -1 | awk '{print $2}' || echo "UNKNOWN")"

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
      warn "Could not determine verdict from review output"
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

  local id="${1:-$(latest_task)}"
  [[ -z "$id" ]] && { error "No task found."; exit 1; }

  local review_file="$SPECS_PATH/$id-review.md"
  [[ ! -f "$review_file" ]] && { error "No review found. Run: devloop review $id"; exit 1; }
  local provider
  _maybe_recover
  provider="$(effective_worker_provider)"

  step "🔧 $(provider_label "$provider") fixing: ${BOLD}$id${RESET}"
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

  info "Launching ${provider} CLI with Claude's fix instructions..."
  echo ""

  local fix_prompt
  fix_prompt="The following issues were identified in a code review. Fix each one exactly as described.

$fix_instructions

Fix all CRITICAL and HIGH severity issues. After fixing, stage all changed files and commit:
feat($id): fix review issues — <one-line summary of what was fixed>
Summarize the changes made."

  local attempt_fix_provider="$provider"
  while true; do
    local tmp_fix_out; tmp_fix_out="$(mktemp /tmp/devloop_fix_out_XXXXXX)"
    local rc=0
    if [[ "$attempt_fix_provider" == "claude" ]]; then
      if ! echo "$fix_prompt" | claude -p --model "$CLAUDE_MODEL" > "$tmp_fix_out" 2>&1; then
        echo "$fix_prompt" | claude -p > "$tmp_fix_out" 2>&1 || rc=$?
      fi
    elif [[ "$attempt_fix_provider" == "opencode" ]]; then
      local tmp_fix; tmp_fix="$(mktemp /tmp/devloop_fix_XXXXXX.md)"
      echo "$fix_prompt" > "$tmp_fix"
      opencode run --file "$tmp_fix" "Fix the issues described in the attached file exactly. Stage all changed files and commit." 2>&1 | tee "$tmp_fix_out" || rc=$?
      rm -f "$tmp_fix"
    elif [[ "$attempt_fix_provider" == "pi" ]]; then
      pi --mode json "$fix_prompt" 2>&1 | tee "$tmp_fix_out" | cat || rc=$?
    else
      echo "$fix_prompt" | copilot 2>&1 | tee "$tmp_fix_out" || rc=$?
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

  if [[ -z "$url" ]]; then
    error "DEVLOOP_SOURCE_URL is not configured."
    echo ""
    echo -e "${BOLD}To enable self-updates, add to devloop.config.sh:${RESET}"
    echo -e "  ${CYAN}DEVLOOP_SOURCE_URL=\"https://raw.githubusercontent.com/you/devloop/main/devloop.sh\"${RESET}"
    echo ""
    echo -e "Or pass it inline:"
    echo -e "  ${CYAN}DEVLOOP_SOURCE_URL=\"...\" devloop update${RESET}"
    exit 1
  fi

  local current_version="$VERSION"
  local tmp_file; tmp_file="$(mktemp /tmp/devloop-update.XXXXXX)"

  step "🔄 Updating devloop..."
  info "Source: ${GRAY}$url${RESET}"
  echo ""

  if command -v curl &>/dev/null; then
    curl -fsSL "$url" -o "$tmp_file" || { error "Download failed from: $url"; rm -f "$tmp_file"; exit 1; }
  elif command -v wget &>/dev/null; then
    wget -qO "$tmp_file" "$url"      || { error "Download failed from: $url"; rm -f "$tmp_file"; exit 1; }
  else
    error "Neither curl nor wget found — cannot download update"
    rm -f "$tmp_file"; exit 1
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
    success "Already up to date (v$current_version)"
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
  success "Updated to ${GREEN}v${new_version:-unknown}${RESET} at ${CYAN}$install_target${RESET}"
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

# ── cmd: help ─────────────────────────────────────────────────────────────────

cmd_help() {
  echo -e "${BOLD}COMMANDS${RESET}\n"
  echo -e "  ${CYAN}devloop install${RESET}"
  echo -e "    Install devloop to /usr/local/bin (run once)\n"
  echo -e "  ${CYAN}devloop init${RESET}"
  echo -e "    Set up DevLoop in current project (auto-analyzes stack/config from project files)"
  echo -e "    Writes: agents, CLAUDE.md, devloop.config.sh, copilot-instructions\n"
  echo -e "  ${CYAN}devloop start [project-name]${RESET}  ${GRAY}alias: s${RESET}"
  echo -e "    Launch Claude with remote control + orchestrator agent"
  echo -e "    Prevents Mac sleep via caffeinate for session duration\n"
  echo -e "  ${CYAN}devloop daemon [project-name]${RESET}  ${GRAY}alias: d${RESET}"
  echo -e "    Run in background with auto-restart + sleep prevention"
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
  echo -e "    Check for available DevLoop updates (requires DEVLOOP_VERSION_URL)\n"
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
  echo -e "    Self-upgrade devloop (requires DEVLOOP_SOURCE_URL in devloop.config.sh)\n"
  echo -e "${BOLD}SETUP (one-time)${RESET}\n"
  echo -e "  ${GRAY}# Install devloop globally${RESET}"
  echo -e "  ${CYAN}curl -fsSL https://your-host/devloop -o /tmp/devloop${RESET}"
  echo -e "  ${CYAN}chmod +x /tmp/devloop && sudo mv /tmp/devloop /usr/local/bin/devloop${RESET}\n"
  echo -e "  ${GRAY}# In each project:${RESET}"
  echo -e "  ${CYAN}cd your-project/${RESET}"
  echo -e "  ${CYAN}devloop init${RESET}"
  echo -e "  ${CYAN}devloop hooks${RESET}           ${GRAY}← install pipeline hooks${RESET}"
  echo -e "  ${CYAN}devloop tools suggest${RESET}   ${GRAY}← discover stack-specific tools${RESET}"
  echo -e "  ${CYAN}devloop start${RESET}           ${GRAY}← connect from mobile/browser${RESET}\n"
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
  echo -e "  ${BOLD}Auto-failover${RESET} (DEVLOOP_FAILOVER_ENABLED=true):"
  echo -e "  When a provider hits its rate limit, DevLoop auto-switches to the next in chain:"
  echo -e "  Main:   ${CYAN}claude → copilot${RESET}"
  echo -e "  Worker: ${CYAN}copilot → opencode → pi${RESET}"
  echo -e "  Original provider is probed every ${CYAN}DEVLOOP_PROBE_INTERVAL${RESET} minutes (default 5)"
  echo -e "  and restored immediately when available again — no fixed wait time"
  echo -e "  Run ${CYAN}devloop failover status${RESET} to check current state\n"
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
  echo -e "${BOLD}WORKER MODES${RESET}\n"
  echo -e "  ${CYAN}cli${RESET}            Use copilot or claude CLI locally (default)"
  echo -e "  ${CYAN}github-agent${RESET}   Create GitHub Issue; Copilot coding agent opens a PR"
  echo -e "  Set ${CYAN}DEVLOOP_WORKER_MODE${RESET} in devloop.config.sh\n"
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

  case "$cmd" in
    install)      cmd_install   "$@" ;;
    init)         cmd_init      "$@" ;;
    start|s)      cmd_start     "$@" ;;
    daemon|d)     cmd_daemon    "$@" ;;
    architect|a)  cmd_architect "$@" ;;
    work|w)       cmd_work      "$@" ;;
    review|r)     cmd_review    "$@" ;;
    fix|f)        cmd_fix       "$@" ;;
    tasks|t)      cmd_tasks     "$@" ;;
    status)       cmd_status    "$@" ;;
    open|o)       cmd_open      "$@" ;;
    block|b)      cmd_block     "$@" ;;
    clean)        cmd_clean     "$@" ;;
    learn)        cmd_learn     "$@" ;;
    check)        cmd_check     "$@" ;;
    agent-sync|sync-agents|agentsync) cmd_agent_sync "$@" ;;
    failover)     cmd_failover  "$@" ;;
    permit)       cmd_permit    "$@" ;;
    hooks)        cmd_hooks     "$@" ;;
    logs)         cmd_logs      "$@" ;;
    doctor)       cmd_doctor    "$@" ;;
    ci)           cmd_ci        "$@" ;;
    tools)        cmd_tools     "$@" ;;
    update)       cmd_update    "$@" ;;
    help)         cmd_help ;;
    *)
      error "Unknown command: $cmd"
      echo ""
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"
