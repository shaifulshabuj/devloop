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

VERSION="5.1.0"
DEVLOOP_DIR=".devloop"
SPECS_DIR="$DEVLOOP_DIR/specs"
PROMPTS_DIR="$DEVLOOP_DIR/prompts"
AGENTS_DIR=".claude/agents"
CONFIG_FILE="devloop.config.sh"
# GitHub source — used by default for version checks and self-update (no config needed)
DEVLOOP_GITHUB_REPO="${DEVLOOP_GITHUB_REPO:-shaifulshabuj/devloop}"
DEVLOOP_SOURCE_URL="${DEVLOOP_SOURCE_URL:-}"   # override to use a custom script URL
DEVLOOP_GLOBAL_DIR="${HOME}/.devloop"          # user-level global state directory
# DEVLOOP_DEFAULT_VIEW=dashboard   # default no-arg behavior; set to "help" for old behavior
# DEVLOOP_STATUS_VIEW=tui                          # default: "tui" launches the TUI; set to "text" to keep the old plain-text dump
# DEVLOOP_DIFF_MAX_EDITS=2                         # rounds of diff-gate edit-on-reject before bailing
# DEVLOOP_FIX_EXTRA_INSTRUCTIONS=<path>            # internal: extra prompt from edit-on-reject (do not set manually)

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

# ── Pipeline status header ──────────────────────────────────────────────────
# _render_status_header arch_state work_state review_state fix_state task_id feature
#
# Prints (or refreshes) a one-line summary of all four pipeline phases above a
# divider line.  Safe to call multiple times — subsequent calls move the cursor
# up 2 lines and overwrite.
#
# State values and their glyphs:
#   ""              → · (pending, dim)
#   "running"       → spinner frame (yellow)
#   "done"          → ✓ (green)
#   "approved"      → ✓ (green)
#   "needs-work"    → ⠿ (yellow)
#   "failed"        → ✗ (red)
#   "rejected"      → ✗ (red)
#   "skipped"       → → (blue)
#   "fix-N:running" → [fix-N ⠙] (yellow, shows round number)
#   "fix-N:done"    → [fix-N ✓] (green)
#   anything else   → · (dim)
#
# Environment:
#   DEVLOOP_STATUS_HEADER=off        suppress entirely
#   DEVLOOP_STATUS_HEADER_FORCE=1    bypass TTY check (for tests)
_HEADER_SPIN_TICK=0
_HEADER_RENDERED=0   # how many times we've rendered (0 = first call)

_render_status_header() {
  # No-op when explicitly disabled
  [[ "${DEVLOOP_STATUS_HEADER:-on}" == "off" ]] && return 0
  # No-op when stdout is not a TTY (unless forced for tests)
  if [[ "${DEVLOOP_STATUS_HEADER_FORCE:-0}" != "1" ]]; then
    [[ -t 1 ]] || return 0
  fi

  local arch_state="${1:-}"
  local work_state="${2:-}"
  local review_state="${3:-}"
  local fix_state="${4:-}"
  local task_id="${5:-}"
  local feature="${6:-}"

  # Advance spinner tick
  _HEADER_SPIN_TICK=$(( (_HEADER_SPIN_TICK + 1) % 10 ))
  local spin_frames="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
  local spin_char="${spin_frames:$_HEADER_SPIN_TICK:1}"

  # Terminal width — truncate feature label to fit
  local cols="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
  local max_feat=$(( cols - 60 ))
  [[ $max_feat -lt 20 ]] && max_feat=20
  if [[ ${#feature} -gt $max_feat ]]; then
    feature="${feature:0:$((max_feat - 1))}…"
  fi

  # Helper: render one phase block   _hdr_block label state spinner_char
  _hdr_block() {
    local label="$1" state="$2" sp="$3"
    local glyph color
    case "$state" in
      "")           glyph="·";   color="${GRAY}" ;;
      running)      glyph="$sp"; color="${YELLOW}" ;;
      done|approved) glyph="✓"; color="${GREEN}" ;;
      needs-work)   glyph="⠿";  color="${YELLOW}" ;;
      failed|rejected) glyph="✗"; color="${RED}" ;;
      skipped)      glyph="→";  color='\033[0;34m' ;;  # blue
      *)            glyph="·";   color="${GRAY}" ;;
    esac
    printf "${GRAY}[${RESET}%s${color}%s${RESET}${GRAY}]${RESET}" "$label " "$glyph"
  }

  # Special-case fix_state: "fix-N:running" or "fix-N:done"
  local fix_block
  if [[ "$fix_state" =~ ^fix-([0-9]+):(.+)$ ]]; then
    local fix_n="${BASH_REMATCH[1]}"
    local fix_sub="${BASH_REMATCH[2]}"
    local fix_glyph fix_color
    case "$fix_sub" in
      running)      fix_glyph="$spin_char"; fix_color="${YELLOW}" ;;
      done|approved) fix_glyph="✓";        fix_color="${GREEN}" ;;
      failed)       fix_glyph="✗";         fix_color="${RED}" ;;
      *)            fix_glyph="·";          fix_color="${GRAY}" ;;
    esac
    fix_block="${GRAY}[${RESET}fix-${fix_n} ${fix_color}${fix_glyph}${RESET}${GRAY}]${RESET}"
  else
    fix_block="$(_hdr_block "fix" "$fix_state" "$spin_char")"
  fi

  local arch_block work_block review_block
  arch_block="$(_hdr_block "arch"   "$arch_state"   "$spin_char")"
  work_block="$(_hdr_block "work"   "$work_state"   "$spin_char")"
  review_block="$(_hdr_block "review" "$review_state" "$spin_char")"

  local task_part=""
  [[ -n "$task_id" ]] && task_part="  ${CYAN}${task_id}${RESET}"

  local feat_part=""
  [[ -n "$feature" ]] && feat_part="  ${GRAY}${feature}${RESET}"

  # Overwrite previous header if already rendered
  if [[ "$_HEADER_RENDERED" -gt 0 ]]; then
    # Move up 2 lines and clear them
    printf '\033[2A\033[2K\033[2K'
  fi

  # Print header line + divider
  echo -e "${arch_block} ${work_block} ${review_block} ${fix_block}${task_part}${feat_part}"
  divider

  _HEADER_RENDERED=$(( _HEADER_RENDERED + 1 ))
}

# _reset_status_header — call at the start of cmd_run / cmd_resume so the
# rendered-count is fresh for each pipeline run (supports multiple calls in
# a single shell session, e.g. from the test suite).
_reset_status_header() {
  _HEADER_RENDERED=0
  _HEADER_SPIN_TICK=0
}

# _read_session_states — populate *_state vars by scanning events.ndjson.
# Outputs: sets arch_state work_state review_state fix_state in caller scope.
# Usage: eval "$(_read_session_states "$session_dir")"
_read_session_states() {
  local sdir="$1"
  local _arch="" _work="" _review="" _fix=""
  local _efile="$sdir/events.ndjson"
  if [[ -f "$_efile" ]]; then
    while IFS= read -r _line; do
      local _phase _status _kind
      if command -v jq >/dev/null 2>&1; then
        _kind="$(printf '%s' "$_line"   | jq -r '.kind   // empty' 2>/dev/null || true)"
        _phase="$(printf '%s' "$_line"  | jq -r '.phase  // empty' 2>/dev/null || true)"
        _status="$(printf '%s' "$_line" | jq -r '.status // empty' 2>/dev/null || true)"
      else
        _kind="$(printf '%s' "$_line"   | sed 's/.*"kind":"\([^"]*\)".*/\1/'   2>/dev/null || true)"
        _phase="$(printf '%s' "$_line"  | sed 's/.*"phase":"\([^"]*\)".*/\1/'  2>/dev/null || true)"
        _status="$(printf '%s' "$_line" | sed 's/.*"status":"\([^"]*\)".*/\1/' 2>/dev/null || true)"
      fi
      [[ "$_kind" == "phase.end" ]] || continue
      case "$_phase" in
        architect)  _arch="$_status" ;;
        worker)     _work="$_status" ;;
        reviewer)   _review="$_status" ;;
        fix-*)      _fix="${_phase}:${_status}" ;;
      esac
    done < "$_efile"
  fi
  printf 'arch_state=%q work_state=%q review_state=%q fix_state=%q\n' \
    "$_arch" "$_work" "$_review" "$_fix"
}

# _find_tui — locate the devloop-tui binary, preferring $HOME/.devloop/bin/.
# Echoes the absolute path on stdout if found; exits non-zero if not.
_find_tui() {
  if [[ -x "$HOME/.devloop/bin/devloop-tui" ]]; then
    echo "$HOME/.devloop/bin/devloop-tui"
    return 0
  fi
  if command -v devloop-tui >/dev/null 2>&1; then
    command -v devloop-tui
    return 0
  fi
  return 1
}

# ── Structured Event Stream ───────────────────────────────────────────────────
# emit_event <kind> [key=value ...]   — append one NDJSON line to two sinks:
#   1) .devloop/events.ndjson          (project-wide stream — single source of truth for TUI / monitors)
#   2) <session_dir>/events.ndjson     (per-session, if DEVLOOP_CURRENT_SESSION_ID is set)
# Failures are silent: a broken event stream must never break the pipeline.
emit_event() {
  [[ "${DEVLOOP_EVENTS_DISABLED:-}" == "1" ]] && return 0
  local kind="${1:-}"; [[ -z "$kind" ]] && return 0
  shift || true

  local ts run_id root json
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  run_id="${DEVLOOP_CURRENT_SESSION_ID:-}"
  root="$(find_project_root 2>/dev/null || pwd)"

  if command -v jq >/dev/null 2>&1; then
    local args=(--arg ts "$ts" --arg session "$run_id" --arg kind "$kind")
    local query='{ts: $ts, session: $session, kind: $kind}'
    local kv k v
    for kv in "$@"; do
      k="${kv%%=*}"
      v="${kv#*=}"
      [[ -z "$k" || "$k" == "$kv" ]] && continue
      args+=(--arg "$k" "$v")
      query+=" | .${k} = \$${k}"
    done
    json="$(jq -nc "${args[@]}" "$query" 2>/dev/null)" || return 0
  else
    # Fallback hand-rolled JSON (best-effort escaping of \ and ").
    json="{\"ts\":\"$ts\",\"session\":\"$run_id\",\"kind\":\"$kind\""
    local kv k v
    for kv in "$@"; do
      k="${kv%%=*}"; v="${kv#*=}"
      [[ -z "$k" || "$k" == "$kv" ]] && continue
      v="${v//\\/\\\\}"; v="${v//\"/\\\"}"
      v="${v//$'\n'/\\n}"; v="${v//$'\t'/\\t}"
      json+=",\"$k\":\"$v\""
    done
    json+="}"
  fi

  local stream="$root/$DEVLOOP_DIR/events.ndjson"
  mkdir -p "$(dirname "$stream")" 2>/dev/null || true
  printf '%s\n' "$json" >> "$stream" 2>/dev/null || true

  if [[ -n "$run_id" ]]; then
    local sdir
    sdir="$root/$DEVLOOP_DIR/sessions/$run_id"
    [[ -d "$sdir" ]] && printf '%s\n' "$json" >> "$sdir/events.ndjson" 2>/dev/null || true
  fi
}

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

# ── Global directory bootstrap ────────────────────────────────────────────────
# Called once at start of main(). Creates ~/.devloop/ and seeds default files
# the first time devloop runs. Completely silent — no output.
_ensure_global_dirs() {
  mkdir -p "$DEVLOOP_GLOBAL_DIR"

  # Seed global config template on first run (never overwrite existing)
  if [[ ! -f "$DEVLOOP_GLOBAL_DIR/config.sh" ]]; then
    cat > "$DEVLOOP_GLOBAL_DIR/config.sh" <<'GLOBAL_CONFIG_TEMPLATE'
# ~/.devloop/config.sh — DevLoop global user defaults
# These apply to ALL projects. Values in a project's devloop.config.sh always override these.
# Edit with:  devloop configure --global

# Provider routing (valid: claude, copilot)
#DEVLOOP_MAIN_PROVIDER="claude"
#DEVLOOP_WORKER_PROVIDER="copilot"

# Claude model for all roles (sonnet | opus | haiku)
#CLAUDE_MODEL="sonnet"
#CLAUDE_MAIN_MODEL=""    # override main roles only (architect/reviewer)
#CLAUDE_WORKER_MODEL=""  # override worker/fix roles only

# Auto-open tmux view pane when devloop run starts (true | false)
# Set to false to disable. Requires tmux to be installed.
#DEVLOOP_AUTO_VIEW="true"

# Fix strategy (escalate | standard)
#DEVLOOP_FIX_STRATEGY="escalate"

# Permission mode (off | auto | smart | strict)
#DEVLOOP_PERMISSION_MODE="smart"

# Keep session logs for N days (0 = keep forever)
#DEVLOOP_SESSION_KEEP_DAYS="30"

# Webhook URL for pipeline event notifications (Slack/Discord/generic)
# Posts JSON on: pipeline complete, inbox item added, NEEDS_WORK, REJECTED
#DEVLOOP_NOTIFY_WEBHOOK=""

# Play a sound on inbox notifications (true | false)
#DEVLOOP_NOTIFY_SOUND="true"
GLOBAL_CONFIG_TEMPLATE
  fi

  # Seed empty project registry
  [[ -f "$DEVLOOP_GLOBAL_DIR/projects.json" ]] || echo "[]" > "$DEVLOOP_GLOBAL_DIR/projects.json"

  # Seed global lessons store
  if [[ ! -f "$DEVLOOP_GLOBAL_DIR/lessons.md" ]]; then
    cat > "$DEVLOOP_GLOBAL_DIR/lessons.md" <<'LESSONS_TEMPLATE'
# DevLoop Global Lessons
<!-- Auto-maintained by `devloop learn --global`. Injected into architect prompts. -->
<!-- Tag sections by stack: ## Node.js, ## Python, ## Go, ## All Stacks, etc. -->

## All Stacks

LESSONS_TEMPLATE
  fi

  # Clean up any stale devloop temp files left by crashed runs (e.g. literal XXXXXX files)
  rm -f /tmp/devloop_task_*XXXXXX*.md /tmp/devloop_fix_*XXXXXX*.md \
        /tmp/devloop_work_out_*XXXXXX /tmp/devloop_fix_out_*XXXXXX 2>/dev/null || true

  mkdir -p "$DEVLOOP_GLOBAL_DIR/logs"
}

# Sources ~/.devloop/config.sh (global defaults) — called at the top of load_config()
# so project devloop.config.sh always wins. Safe no-op if file absent.
load_global_config() {
  local gconf="$DEVLOOP_GLOBAL_DIR/config.sh"
  # shellcheck disable=SC1090
  [[ -f "$gconf" ]] && source "$gconf" || true
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
  DEVLOOP_SESSION_LOGGING="true"   # record per-run session logs under .devloop/sessions/
  DEVLOOP_NOTIFY_WEBHOOK=""         # webhook URL for pipeline event notifications
  DEVLOOP_NOTIFY_SOUND="true"       # play sound on macOS inbox notifications
  # DEVLOOP_AUTO_VIEW and DEVLOOP_SESSION_KEEP_DAYS use :=default so env vars set before devloop
  # (e.g. DEVLOOP_AUTO_VIEW=true devloop run ...) are not overwritten by load_config defaults.
  : "${DEVLOOP_AUTO_VIEW:=true}"         # auto-open tmux view when devloop run starts
  : "${DEVLOOP_SESSION_KEEP_DAYS:=30}"   # auto-prune sessions older than N days (0 = keep forever)

  # Load order: (1) hardcoded defaults above → (2) global user config → (3) project config
  # Each layer overrides the previous; project config always wins.
  load_global_config
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

  # --global: promote recent project lessons to ~/.devloop/lessons.md
  if [[ "${1:-}" == "--global" ]]; then
    shift
    _cmd_learn_global "$@"
    return
  fi

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

  # Offer to also promote to global lessons
  echo -e "  ${GRAY}Promote to global lessons (all projects):  ${CYAN}devloop learn --global $id${RESET}"
  echo ""
}

# Promote lessons from a task review to ~/.devloop/lessons.md
_cmd_learn_global() {
  _ensure_global_dirs
  local id="${1:-$(latest_task)}"
  [[ -z "$id" ]] && { error "No task found."; exit 1; }

  local review_file="$SPECS_PATH/$id-review.md"
  local spec_file="$SPECS_PATH/$id.md"
  [[ ! -f "$review_file" ]] && { error "No review found for $id. Run: devloop review $id"; exit 1; }

  local global_lessons="$DEVLOOP_GLOBAL_DIR/lessons.md"
  local provider; provider="$(effective_main_provider)"

  step "🌍 Learning globally from: ${BOLD}$id${RESET}"
  divider

  local stack="${PROJECT_STACK:-All Stacks}"

  local learn_prompt="You are analyzing a code review to extract GLOBAL reusable lessons.
These lessons will be injected into the architect prompt for ALL future projects with a matching stack.

## Stack: $stack
## Task spec (excerpt)
$(head -40 "$spec_file" 2>/dev/null)

## Code review outcome
$(cat "$review_file")

## Existing global lessons for this stack (do NOT duplicate these):
$(grep -A 30 "## $stack" "$global_lessons" 2>/dev/null | head -30 || echo "(none yet)")

## Your task
Extract 1-3 HIGHLY GENERAL lessons that apply broadly to any $stack project.
- Must be universally applicable (not specific to this codebase)
- Must not duplicate existing global lessons above
- Each as a Markdown list item starting with '-'
Output ONLY the list items. If no new general lessons can be extracted, output: (none)"

  local glessons_file; glessons_file="$(mktemp /tmp/devloop-glessons.XXXXXX)"
  info "Calling $(provider_label "$provider") to extract global lessons..."
  run_provider_prompt "$provider" "$learn_prompt" "$glessons_file"
  local new_lessons; new_lessons="$(cat "$glessons_file")"
  rm -f "$glessons_file"

  if [[ -z "$new_lessons" || "$new_lessons" == *"(none)"* ]]; then
    info "No new global lessons to add for this review"
    return
  fi

  echo ""
  info "New global lessons:"
  echo -e "${GRAY}$new_lessons${RESET}"
  echo ""

  # Append under the right stack section
  if grep -q "^## $stack" "$global_lessons"; then
    # Insert after the stack header
    local tmp; tmp="$(mktemp)"
    awk -v stack="## $stack" -v lessons="$new_lessons" '
      /^## / && found { found=0 }
      $0 == stack { print; print lessons; found=1; next }
      { print }
    ' "$global_lessons" > "$tmp" && mv "$tmp" "$global_lessons"
  else
    {
      printf '\n## %s\n' "$stack"
      printf '%s\n' "$new_lessons"
    } >> "$global_lessons"
  fi

  success "Global lessons updated: ${CYAN}$global_lessons${RESET}"
  info "These lessons will be injected into architect prompts for $stack projects"
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
  # Parse flags before load_config so we can pass them along
  local _non_interactive="false"
  local _cfg_args=()
  for _a in "$@"; do
    case "$_a" in
      --non-interactive|--yes|-y) _non_interactive="true" ;;
      *) _cfg_args+=("$_a") ;;
    esac
  done
  [[ ${#_cfg_args[@]} -gt 0 ]] && set -- "${_cfg_args[@]}" || set --

  load_config
  ensure_dirs

  # --global: edit ~/.devloop/config.sh
  if [[ "${1:-}" == "--global" ]]; then
    _ensure_global_dirs
    local gconf="$DEVLOOP_GLOBAL_DIR/config.sh"
    step "DevLoop Global Configure — ${CYAN}$gconf${RESET}"
    divider
    info "Global defaults apply to all projects. Project devloop.config.sh always overrides."
    echo ""
    echo -e "${BOLD}Current global settings (uncommented lines):${RESET}"
    grep -v '^#' "$gconf" | grep -v '^[[:space:]]*$' || echo -e "  ${GRAY}(all defaults — nothing customized yet)${RESET}"
    echo ""
    local editor="${EDITOR:-}"
    [[ -z "$editor" ]] && command -v nano &>/dev/null && editor="nano"
    [[ -z "$editor" ]] && command -v vi   &>/dev/null && editor="vi"
    if [[ -n "$editor" ]]; then
      "$editor" "$gconf"
      success "Global config saved: $gconf"
    else
      warn "No editor found. Set \$EDITOR or edit manually: $gconf"
    fi
    echo ""
    echo -e "  Run ${CYAN}devloop init${RESET} in each project to inherit new global defaults."
    return
  fi

  step "DevLoop Configure — interactive setup"
  divider

  if [[ ! -f "$CONFIG_PATH" ]]; then
    info "No devloop.config.sh found — running full init first..."
    if [[ "$_non_interactive" == "true" ]]; then
      cmd_init --yes
    else
      cmd_init --configure
    fi
    return
  fi

  info "Current config: ${CYAN}$CONFIG_PATH${RESET}"
  _setup_wizard "$CONFIG_PATH" "$_non_interactive"

  # After wizard, reload and regenerate agents with new model settings
  load_config
  write_agent_orchestrator 2>/dev/null || true
  write_agent_architect "${CLAUDE_MAIN_MODEL:-${CLAUDE_MODEL:-sonnet}}" 2>/dev/null || true
  write_agent_reviewer   "${CLAUDE_MAIN_MODEL:-${CLAUDE_MODEL:-sonnet}}" 2>/dev/null || true
  success "Configuration saved and agent prompts updated"
  echo -e "  ${GRAY}Run ${CYAN}devloop hooks${GRAY} to re-install permission hooks with new settings${RESET}"
  echo -e "  ${GRAY}Run ${CYAN}devloop doctor${GRAY} to verify your setup is complete${RESET}"
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

  # Global config
  echo -e "\n  ${BOLD}Global Config (${DEVLOOP_GLOBAL_DIR})${RESET}"
  ok="false"; [[ -d "$DEVLOOP_GLOBAL_DIR" ]] && ok="true"
  _chk "~/.devloop/ directory exists" "$ok" "devloop configure --global"
  if [[ -f "$DEVLOOP_GLOBAL_DIR/config.sh" ]]; then
    local custom_count
    custom_count="$(grep -v '^#' "$DEVLOOP_GLOBAL_DIR/config.sh" | grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')"
    echo -e "  ${GRAY}—${RESET}  Global config keys set: ${CYAN}${custom_count}${RESET}  (edit: ${CYAN}devloop configure --global${RESET})"
  else
    echo -e "  ${GRAY}—  No global config yet. Create with: devloop configure --global${RESET}"
  fi
  if [[ -f "$DEVLOOP_GLOBAL_DIR/projects.json" ]]; then
    local proj_count
    proj_count="$(python3 -c "import json; d=json.load(open('$DEVLOOP_GLOBAL_DIR/projects.json')); print(len(d))" 2>/dev/null || echo "?")"
    echo -e "  ${GRAY}—${RESET}  Registered projects: ${CYAN}${proj_count}${RESET}"
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
        # Architect/reviewer: read-only tools sufficient (no bash execution needed)
        local _readonly_tools="Read,Write,Glob,LS,Bash(git*),Bash(cat*),Bash(grep*),Bash(find*),Bash(ls*),Bash(wc*)"
        local _main_model="${CLAUDE_MAIN_MODEL:-${CLAUDE_MODEL:-sonnet}}"
        if [[ -n "${DEVLOOP_SESSION_PHASE_LOG:-}" ]]; then
          if ! echo "$prompt" | claude -p --model "$_main_model" --allowedTools "$_readonly_tools" 2>&1 | tee -a "$DEVLOOP_SESSION_PHASE_LOG" > "$tmp_out"; then
            echo "$prompt" | claude -p --model "$_main_model" 2>&1 | tee -a "$DEVLOOP_SESSION_PHASE_LOG" > "$tmp_out" || rc=$?
          fi
        else
          if ! echo "$prompt" | claude -p --model "$_main_model" --allowedTools "$_readonly_tools" > "$tmp_out" 2>&1; then
            echo "$prompt" | claude -p --model "$_main_model" > "$tmp_out" 2>&1 || rc=$?
          fi
        fi
        ;;
      copilot)
        if [[ -n "${DEVLOOP_SESSION_PHASE_LOG:-}" ]]; then
          copilot --allow-all-tools --allow-all-paths -p "$prompt" 2>&1 | tee -a "$DEVLOOP_SESSION_PHASE_LOG" > "$tmp_out" || rc=$?
        else
          copilot --allow-all-tools --allow-all-paths -p "$prompt" > "$tmp_out" 2>&1 || rc=$?
        fi
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
tools: Agent(devloop-architect, devloop-reviewer), Bash, Read, Write, TodoWrite, mcp__waymark-devloop__write_file, mcp__waymark-devloop__read_file, mcp__waymark-devloop__bash
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
- **NEEDS_WORK** → Escalate through fix phases:
  - **Round 1 (standard fix)**: Run `devloop fix TASK-ID`, re-delegate to `@devloop-reviewer`.
  - **Round 2 (deep fix)**: Run `devloop fix TASK-ID` again. Instruct the reviewer to focus ONLY on issues NOT resolved in round 1.
  - **Round 3 (escalate)**: Notify the user: "⚠️ Still NEEDS_WORK after 2 fix attempts. Options: (1) I can try re-architecting the spec with `devloop run --max-retries 5 TASK-ID`, (2) you can edit the spec manually with `devloop open TASK-ID`, or (3) we accept as-is." Wait for user instruction before proceeding.
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

## MCP Tools Available
- **Waymark** (`mcp__waymark-devloop__*`): `write_file`, `read_file`, `bash` — use for audited file writes when modifying project files
- **DocuFlow** (`mcp__docuflow__*`): `query_wiki`, `read_module`, `list_modules` — available to architect/reviewer subagents for codebase context
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
tools: Bash, Read, Glob, Grep, mcp__docuflow__read_module, mcp__docuflow__list_modules, mcp__docuflow__query_wiki, mcp__docuflow__wiki_search
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

### 2. Explore codebase context
Read files mentioned in the task. Check existing patterns.

If DocuFlow MCP tools are available, query the wiki for related patterns before writing the spec:
```
mcp__docuflow__query_wiki({ project_path: ".", question: "How is [feature area] implemented?" })
mcp__docuflow__read_module({ path: "src/relevant-file" })
```
Flag any implementation that contradicts documented patterns in the spec as a constraint.

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
tools: Bash, Read, Glob, Grep, mcp__docuflow__query_wiki, mcp__docuflow__wiki_search
model: ${model}
color: yellow
---
FRONT
  cat >> "$AGENTS_PATH/devloop-reviewer.md" <<'BODY'

You are the DevLoop Reviewer. Rigorously check Copilot's implementation against the original spec.

## On invocation

### 1. Load spec and context
```bash
devloop status TASK-ID
```

If DocuFlow MCP tools are available, optionally query the wiki for patterns relevant to this feature area:
```
mcp__docuflow__query_wiki({ project_path: ".", question: "patterns for [feature area]" })
```
Flag any implementation that contradicts documented patterns as a HIGH severity issue.

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
# Usage: _setup_wizard <config_file> [--non-interactive]

# ── Wizard UI helpers (gum if available, plain read fallback) ─────────────────

# _cfg_choose <header> <default> <choice1> <choice2> ...
# Prints the chosen value to stdout.
_cfg_choose() {
  local header="$1"; local default="$2"; shift 2
  if command -v gum >/dev/null 2>&1; then
    gum choose \
      --header "$header" \
      --selected "$default" \
      --cursor.foreground "36" \
      --header.foreground "36" \
      "$@" 2>/dev/tty
  else
    echo -e "${BOLD}$header${RESET}" >&2
    local i=1 choice
    for choice in "$@"; do
      local marker=""
      [[ "$choice" == "$default" ]] && marker=" ${GRAY}(current)${RESET}"
      printf "  %d) %s%b\n" "$i" "$choice" "$marker" >&2
      i=$(( i + 1 ))
    done
    printf "  Pick [default: ${BOLD}%s${RESET}]: " "$default" >&2
    local answer; read -r answer 2>/dev/null </dev/tty || answer=""
    if [[ -z "$answer" ]]; then
      echo "$default"
    elif [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= $# )); then
      # positional lookup: set -- already consumed header+default, $@ is choices
      local _choices=("$@")
      echo "${_choices[$(( answer - 1 ))]}"
    else
      echo "$answer"
    fi
  fi
}

# _cfg_input <prompt> <default>
# Prints the entered value to stdout.
_cfg_input() {
  local prompt="$1"; local default="$2"
  if command -v gum >/dev/null 2>&1; then
    gum input \
      --prompt "$prompt " \
      --value "$default" \
      --cursor.foreground "36" 2>/dev/tty
  else
    printf "%s [${BOLD}%s${RESET}]: " "$prompt" "$default" >&2
    local answer; read -r answer 2>/dev/null </dev/tty || answer=""
    echo "${answer:-$default}"
  fi
}

# _cfg_confirm <prompt> <default-bool: true|false>
# Prints "true" or "false" to stdout.
_cfg_confirm() {
  local prompt="$1"; local default="${2:-true}"
  if command -v gum >/dev/null 2>&1; then
    local gum_default="yes"
    [[ "$default" == "false" ]] && gum_default="no"
    if gum confirm "$prompt" \
        --default="$gum_default" \
        --affirmative "Yes" --negative "No" \
        --selected.background "36" 2>/dev/tty; then
      echo "true"
    else
      echo "false"
    fi
  else
    local yn_hint="Y/n"
    [[ "$default" == "false" ]] && yn_hint="y/N"
    printf "%s [%s]: " "$prompt" "$yn_hint" >&2
    local answer; read -r answer 2>/dev/null </dev/tty || answer=""
    case "${answer,,}" in
      y|yes) echo "true" ;;
      n|no)  echo "false" ;;
      *)     echo "$default" ;;
    esac
  fi
}

_setup_wizard() {
  local cfg="$1"
  local non_interactive="${2:-false}"

  # Detect installed providers
  local has_claude="false"; command -v claude &>/dev/null && has_claude="true"
  local has_copilot="false"; command -v copilot &>/dev/null && has_copilot="true"
  local has_opencode="false"; command -v opencode &>/dev/null && has_opencode="true"
  local has_pi="false"; command -v pi &>/dev/null && has_pi="true"

  _avail() { [[ "$1" == "true" ]] && echo "${GREEN}✔ installed${RESET}" || echo "${YELLOW}⚠  not found${RESET}"; }

  # Read current values from config as defaults (so Enter keeps current setting)
  local cur_main;         cur_main="$(         grep -E '^DEVLOOP_MAIN_PROVIDER='   "$cfg" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '"' )" || true
  local cur_worker;       cur_worker="$(       grep -E '^DEVLOOP_WORKER_PROVIDER=' "$cfg" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '"' )" || true
  local cur_main_model;   cur_main_model="$(   grep -E '^CLAUDE_MAIN_MODEL='       "$cfg" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '"' )" || true
  local cur_worker_model; cur_worker_model="$( grep -E '^CLAUDE_WORKER_MODEL='     "$cfg" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '"' )" || true
  local cur_perm;         cur_perm="$(         grep -E '^DEVLOOP_PERMISSION_MODE=' "$cfg" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '"' )" || true

  # Smart defaults for fresh configs
  local main_default="${cur_main:-claude}"
  [[ "$has_claude" == "false" && "$has_copilot" == "true" && -z "$cur_main" ]] && main_default="copilot"
  local worker_default="${cur_worker:-copilot}"
  local main_model_default="${cur_main_model:-sonnet}"
  [[ -z "$cur_main_model" ]] && { cur_model_base="$(grep -E '^CLAUDE_MODEL=' "$cfg" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '"')"; [[ -n "$cur_model_base" ]] && main_model_default="$cur_model_base"; } || true
  local worker_model_default="${cur_worker_model:-sonnet}"
  local perm_default="${cur_perm:-smart}"

  # ── Non-interactive: write current/default values and return ─────────────────
  if [[ "$non_interactive" == "true" ]]; then
    _wizard_set_config "$cfg" "DEVLOOP_MAIN_PROVIDER"   "$main_default"
    _wizard_set_config "$cfg" "DEVLOOP_WORKER_PROVIDER" "$worker_default"
    _wizard_set_config "$cfg" "CLAUDE_MODEL"            "$main_model_default"
    _wizard_set_config "$cfg" "CLAUDE_MAIN_MODEL"       "$main_model_default"
    _wizard_set_config "$cfg" "CLAUDE_WORKER_MODEL"     "$worker_model_default"
    _wizard_set_config "$cfg" "DEVLOOP_PERMISSION_MODE" "$perm_default"
    success "Configuration written (non-interactive) to ${CYAN}$cfg${RESET}"
    return 0
  fi

  # ── Banner ────────────────────────────────────────────────────────────────────
  echo ""
  if command -v gum >/dev/null 2>&1; then
    gum style \
      --border double --border-foreground 36 \
      --padding "1 4" --margin "0 2" \
      --bold --foreground 36 \
      "DevLoop Setup Wizard"
  else
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${BOLD}  DevLoop Setup Wizard${RESET}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  fi
  echo ""
  echo -e "  Detected providers:"
  echo -e "    claude   $(_avail "$has_claude")"
  echo -e "    copilot  $(_avail "$has_copilot")"
  echo -e "    opencode $(_avail "$has_opencode")"
  echo -e "    pi       $(_avail "$has_pi")"
  echo ""
  if command -v gum >/dev/null 2>&1; then
    echo -e "  ${CYAN}Use arrow keys to select, Enter to confirm.${RESET}"
  else
    echo -e "  ${GRAY}Press Enter to accept default shown in [brackets]${RESET}"
  fi
  echo ""

  # ── Step 1: Main provider ────────────────────────────────────────────────────
  echo -e "${BOLD}Step 1/4 — Main provider${RESET}"
  echo -e "  The main provider runs the ${CYAN}orchestrator${RESET}, ${CYAN}architect${RESET}, and ${CYAN}reviewer${RESET}."
  echo -e "  It must support remote control (mobile/browser → terminal handoff)."
  echo ""
  local wiz_main
  wiz_main="$(_cfg_choose \
    "Main provider (orchestrator / architect / reviewer):" \
    "$main_default" \
    "claude" "copilot")"
  echo -e "  ${GREEN}✔${RESET} Main provider: ${BOLD}$wiz_main${RESET}"
  echo ""

  # ── Step 2: Worker provider ──────────────────────────────────────────────────
  echo -e "${BOLD}Step 2/4 — Worker provider${RESET}"
  echo -e "  The worker executes ${CYAN}work${RESET} and ${CYAN}fix${RESET} tasks (implements the code)."
  echo -e "  All providers are supported here."
  echo ""
  # Adjust worker default based on newly chosen main
  [[ "$wiz_main" == "copilot" && -z "$cur_worker" ]] && worker_default="claude"
  [[ "$has_copilot" == "false" && "$has_claude" == "true" && -z "$cur_worker" ]] && worker_default="claude"
  local wiz_worker
  wiz_worker="$(_cfg_choose \
    "Worker provider (work / fix):" \
    "$worker_default" \
    "copilot" "claude" "opencode" "pi")"
  echo -e "  ${GREEN}✔${RESET} Worker provider: ${BOLD}$wiz_worker${RESET}"
  echo ""

  # ── Step 3: Claude model(s) ──────────────────────────────────────────────────
  echo -e "${BOLD}Step 3/4 — Claude model${RESET}"
  echo -e "  Used when Claude is the main or worker provider."
  echo ""

  echo -e "  ${BOLD}Main model${RESET} (architect / reviewer / orchestrator):"
  local wiz_main_model
  wiz_main_model="$(_cfg_choose \
    "Claude main model:" \
    "$main_model_default" \
    "sonnet" "opus" "haiku")"
  # Allow free-text custom model name if gum wasn't available and user typed something else
  if [[ -z "$wiz_main_model" ]]; then
    wiz_main_model="$(_cfg_input "Custom main model name:" "$main_model_default")"
  fi
  echo ""

  echo -e "  ${BOLD}Worker model${RESET} (work / fix):"
  local wiz_worker_model
  wiz_worker_model="$(_cfg_choose \
    "Claude worker model (same = match main):" \
    "$worker_model_default" \
    "sonnet" "opus" "haiku" "same as main ($wiz_main_model)")"
  # Resolve "same as main" alias
  if [[ "$wiz_worker_model" == "same as main ($wiz_main_model)" || "$wiz_worker_model" == "same" ]]; then
    wiz_worker_model="$wiz_main_model"
  fi
  if [[ -z "$wiz_worker_model" ]]; then
    wiz_worker_model="$(_cfg_input "Custom worker model name:" "$worker_model_default")"
  fi
  echo -e "  ${GREEN}✔${RESET} Main model: ${BOLD}$wiz_main_model${RESET} | Worker model: ${BOLD}$wiz_worker_model${RESET}"
  echo ""

  # ── Step 4: Permission mode ──────────────────────────────────────────────────
  echo -e "${BOLD}Step 4/4 — Permission mode${RESET}"
  echo -e "  Controls how devloop handles Bash commands from AI agents."
  echo ""
  local wiz_perm
  wiz_perm="$(_cfg_choose \
    "Permission mode:" \
    "$perm_default" \
    "smart" "auto" "strict" "off")"
  echo -e "  ${GREEN}✔${RESET} Permission mode: ${BOLD}$wiz_perm${RESET}"
  echo ""

  # ── Summary ──────────────────────────────────────────────────────────────────
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "  ${BOLD}Your selections:${RESET}"
  echo -e "  Main provider:       ${CYAN}$wiz_main${RESET}"
  echo -e "  Worker provider:     ${CYAN}$wiz_worker${RESET}"
  echo -e "  Claude main model:   ${CYAN}$wiz_main_model${RESET}"
  echo -e "  Claude worker model: ${CYAN}$wiz_worker_model${RESET}"
  echo -e "  Permission mode:     ${CYAN}$wiz_perm${RESET}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""

  local do_save
  do_save="$(_cfg_confirm "Save to $(basename "$cfg")?" "true")"
  if [[ "$do_save" == "false" ]]; then
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

  success "Configuration saved to ${CYAN}$(basename "$cfg")${RESET}"
  echo -e "  ${GRAY}Run ${CYAN}devloop doctor${GRAY} to verify your setup is complete.${RESET}"
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
  # --merge: only add missing config keys (non-destructive re-init)
  local skip_wizard="false"
  local force_wizard="false"
  local merge_only="false"
  local _args=()
  for _a in "$@"; do
    case "$_a" in
      --yes|-y)        skip_wizard="true" ;;
      --configure|-c)  force_wizard="true" ;;
      --merge)         merge_only="true"; skip_wizard="true" ;;
      *)               _args+=("$_a") ;;
    esac
  done
  [[ ${#_args[@]} -gt 0 ]] && set -- "${_args[@]}" || set --

  load_config
  ensure_dirs

  if [[ "$merge_only" == "true" ]]; then
    _cmd_init_merge
    return
  fi

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

  # Register this project in the global registry
  _register_project "$(find_project_root)"
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
  # Launch copilot with remote control, named session, and initial orchestrator context
  # --remote: enable access from GitHub web (copilot.github.com) and GitHub mobile app
  # --name:   session title visible in remote session list
  # --allow-all: allow all tools/paths/urls without confirmation
  # -i: start interactive mode and automatically send the initial context prompt
  copilot \
    --remote \
    --name "DevLoop: $project_name" \
    --allow-all \
    -i "$init_prompt"
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
      echo -e "  ${CYAN}copilot --remote${RESET}      accessible from GitHub web + mobile"
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
      echo -e "  📱 GitHub mobile app → find ${CYAN}\"DevLoop: $project_name\"${RESET} in Copilot sessions"
      echo -e "  🌐 ${CYAN}https://github.com/copilot${RESET} → session list"
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

  # Copilot daemon — remote control is available via --remote flag
  if [[ "$main_backend" == "copilot" ]]; then
    info "Daemon mode with Copilot: remote control enabled (--remote flag)"
    echo -e "  Access from ${CYAN}https://github.com/copilot${RESET} or GitHub mobile app."
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
      echo -e "  📱 GitHub mobile app → find ${CYAN}\"DevLoop: $project_name\"${RESET} in Copilot sessions"
      echo -e "  🌐 ${CYAN}https://github.com/copilot${RESET} → session list"
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

# ── Session logging helpers ───────────────────────────────────────────────────
# Provides structured per-run session directories under .devloop/sessions/<id>/
# Each run gets: main.log, <phase>.log, <phase>.state, feature.txt, status
# Set DEVLOOP_CURRENT_SESSION_ID in cmd_run for automatic phase logging.

_session_dir() {
  local root; root="$(find_project_root 2>/dev/null || pwd)"
  echo "$root/$DEVLOOP_DIR/sessions/${1:-}"
}

_session_init() {
  local run_id="$1"; local feature="$2"
  [[ "${DEVLOOP_SESSION_LOGGING:-true}" != "true" ]] && return 0
  local dir; dir="$(_session_dir "$run_id")"
  mkdir -p "$dir/decisions/pending" "$dir/decisions/approved" "$dir/approvals"
  echo "$feature"                                  > "$dir/feature.txt"
  echo "running"                                   > "$dir/status"
  date '+%Y-%m-%dT%H:%M:%S'                       > "$dir/started_at"
  printf '[%s] DevLoop session started\nFeature: %s\n' \
    "$(date '+%H:%M:%S')" "$feature"               > "$dir/main.log"
  # Write global hint so `devloop view/session` works from any terminal/cwd
  mkdir -p "$HOME/.devloop"
  echo "$dir" > "$HOME/.devloop/last-session"
  # Structured event: session.start
  DEVLOOP_CURRENT_SESSION_ID="$run_id" emit_event "session.start" feature="$feature"
  # Prune old sessions in background to avoid blocking the pipeline
  ( _session_prune 2>/dev/null ) &
}

_session_phase_start() {
  local run_id="${DEVLOOP_CURRENT_SESSION_ID:-}"; local phase="$1"
  [[ -z "$run_id" || "${DEVLOOP_SESSION_LOGGING:-true}" != "true" ]] && return 0
  local dir; dir="$(_session_dir "$run_id")"
  [[ -d "$dir" ]] || return 0
  printf '[%s] === %s started ===\n' "$(date '+%H:%M:%S')" "$phase" > "$dir/$phase.log"
  echo "running:$(date '+%Y-%m-%dT%H:%M:%S')"     > "$dir/$phase.state"
  # Track epoch for duration_ms in phase.end
  date +%s%3N 2>/dev/null > "$dir/$phase.start_epoch_ms" \
    || date +%s | awk '{print $1 "000"}' > "$dir/$phase.start_epoch_ms"
  printf '[%s] Phase started: %s\n' "$(date '+%H:%M:%S')" "$phase" >> "$dir/main.log"
  # Export so run_provider_prompt and cmd_work can tee live output here
  export DEVLOOP_SESSION_PHASE_LOG="$dir/$phase.log"
  # Structured event: phase.start
  emit_event "phase.start" phase="$phase"
}

_session_phase_end() {
  local run_id="${DEVLOOP_CURRENT_SESSION_ID:-}"; local phase="$1"; local status="${2:-done}"
  [[ -z "$run_id" || "${DEVLOOP_SESSION_LOGGING:-true}" != "true" ]] && return 0
  local dir; dir="$(_session_dir "$run_id")"
  [[ -d "$dir" ]] || return 0
  printf '[%s] === %s ended: %s ===\n' "$(date '+%H:%M:%S')" "$phase" "$status" >> "$dir/$phase.log"
  echo "$status:$(date '+%Y-%m-%dT%H:%M:%S')"     > "$dir/$phase.state"
  printf '[%s] Phase ended: %s (%s)\n' "$(date '+%H:%M:%S')" "$phase" "$status" >> "$dir/main.log"
  # Structured event: phase.end with duration_ms when possible
  local duration_ms=""
  if [[ -f "$dir/$phase.start_epoch_ms" ]]; then
    local start_ms end_ms
    start_ms="$(cat "$dir/$phase.start_epoch_ms" 2>/dev/null || echo 0)"
    end_ms="$(date +%s%3N 2>/dev/null || date +%s | awk '{print $1 "000"}')"
    if [[ "$start_ms" =~ ^[0-9]+$ && "$end_ms" =~ ^[0-9]+$ ]]; then
      duration_ms="$((end_ms - start_ms))"
    fi
    rm -f "$dir/$phase.start_epoch_ms" 2>/dev/null || true
  fi
  if [[ -n "$duration_ms" ]]; then
    emit_event "phase.end" phase="$phase" status="$status" duration_ms="$duration_ms"
  else
    emit_event "phase.end" phase="$phase" status="$status"
  fi
}

_session_append_log() {
  # _session_append_log <phase> <content>
  local run_id="${DEVLOOP_CURRENT_SESSION_ID:-}"; local phase="$1"; local content="$2"
  [[ -z "$run_id" || "${DEVLOOP_SESSION_LOGGING:-true}" != "true" ]] && return 0
  local dir; dir="$(_session_dir "$run_id")"
  [[ -d "$dir" ]] || return 0
  echo "$content" >> "$dir/$phase.log"
}

_session_finish() {
  local run_id="${DEVLOOP_CURRENT_SESSION_ID:-}"; local status="${1:-approved}"
  [[ -z "$run_id" || "${DEVLOOP_SESSION_LOGGING:-true}" != "true" ]] && return 0
  local dir; dir="$(_session_dir "$run_id")"
  [[ -d "$dir" ]] || return 0
  echo "$status" > "$dir/status"
  date '+%Y-%m-%dT%H:%M:%S' > "$dir/finished_at"
  printf '[%s] Session finished: %s\n' "$(date '+%H:%M:%S')" "$status" >> "$dir/main.log"
  # Structured event: session.end
  emit_event "session.end" status="$status"
  unset DEVLOOP_SESSION_PHASE_LOG
}

_session_prune() {
  # Delete session directories older than DEVLOOP_SESSION_KEEP_DAYS (0 = keep all)
  local keep_days="${DEVLOOP_SESSION_KEEP_DAYS:-30}"
  [[ "$keep_days" -eq 0 ]] && return 0
  local root; root="$(find_project_root 2>/dev/null || pwd)"
  local sessions_dir="$root/$DEVLOOP_DIR/sessions"
  [[ -d "$sessions_dir" ]] || return 0
  local now; now="$(date +%s)"
  local cutoff=$(( now - keep_days * 86400 ))
  local pruned=0
  while IFS= read -r d; do
    [[ -d "$d" ]] || continue
    local ts_file="$d/started_at"
    if [[ ! -f "$ts_file" ]]; then
      # Use directory mtime as fallback
      local mtime
      # macOS stat
      mtime="$(stat -f %m "$d" 2>/dev/null || stat -c %Y "$d" 2>/dev/null || echo "$now")"
      [[ "$mtime" -lt "$cutoff" ]] && { rm -rf "$d"; (( pruned++ )); }
    else
      # Parse stored timestamp
      local ts_val; ts_val="$(cat "$ts_file" 2>/dev/null | tr -d '[:space:]')"
      local ts_epoch
      ts_epoch="$(date -j -f '%Y-%m-%dT%H:%M:%S' "$ts_val" +%s 2>/dev/null || \
                  date -d "$ts_val" +%s 2>/dev/null || echo "$now")"
      [[ "$ts_epoch" -lt "$cutoff" ]] && { rm -rf "$d"; (( pruned++ )); }
    fi
  done < <(ls -d "$sessions_dir"/TASK-* 2>/dev/null || true)
  [[ "$pruned" -gt 0 ]] && info "Pruned $pruned session(s) older than ${keep_days}d"
}

# ── Approval gates ────────────────────────────────────────────────────────────
# Resolves a yes/no/edit decision for a pipeline checkpoint.
# Resolver chain (first match wins):
#   1) DEVLOOP_AUTO=1                                         → approve
#   2) pre-written <session>/approvals/<gate>.json            → honor it
#   2.5) DEVLOOP_APPROVAL_WAIT=N  poll for decision file up to N seconds
#        (used by devloop-tui: the TUI writes the file; the engine picks it up)
#   3) gum choose                              (if gum installed and TTY)
#   4) read from /dev/tty                       (DEVLOOP_APPROVAL_TIMEOUT, default 120s)
#   5) no surface available                                    → reject (safe default)
#
# Always emits approval.request before, approval.decision after, and persists
# the final decision to <session>/approvals/<gate>.json so any concurrent
# watcher (future TUI) sees the same final state.
#
# Exit codes: 0 = approve, 1 = reject, 2 = edit (caller re-runs upstream phase)

_approval_resolve() {
  # _approval_resolve <gate> <decision> <source> [decision_file_to_write]
  local gate="$1"; local decision="$2"; local source="$3"; local decision_file="${4:-}"
  emit_event "approval.decision" gate="$gate" decision="$decision" source="$source"
  if [[ -n "$decision_file" ]]; then
    local ts; ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    if command -v jq >/dev/null 2>&1; then
      jq -nc --arg ts "$ts" --arg gate "$gate" --arg decision "$decision" --arg source "$source" \
        '{ts:$ts, gate:$gate, decision:$decision, source:$source}' > "$decision_file" 2>/dev/null || true
    else
      printf '{"ts":"%s","gate":"%s","decision":"%s","source":"%s"}\n' \
        "$ts" "$gate" "$decision" "$source" > "$decision_file" 2>/dev/null || true
    fi
  fi
}

# _approval_read_decision <file>
# Extracts the "decision" value from a JSON decision file.
# Prints one of: approve | reject | edit — or nothing if absent/invalid.
# Shared by the pre-written step (2) and the TUI-poll step (2.5).
_approval_read_decision() {
  local file="$1"
  [[ -f "$file" ]] || return
  local val=""
  if command -v jq >/dev/null 2>&1; then
    val="$(jq -r '.decision // empty' "$file" 2>/dev/null || true)"
  else
    val="$(grep -o '"decision"[[:space:]]*:[[:space:]]*"[^"]*"' "$file" 2>/dev/null \
             | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
  fi
  echo "$val"
}

_approval_gate() {
  # _approval_gate <gate> <summary> [detail_file]
  # DEVLOOP_APPROVAL_WAIT=N  — if set and > 0, poll decision_file for up to N
  #   seconds (200 ms interval) before falling through to the gum/tty prompts.
  #   devloop-tui sets this so the engine waits for the TUI's interactive choice.
  local gate="$1"; local summary="$2"; local detail_file="${3:-}"
  local run_id="${DEVLOOP_CURRENT_SESSION_ID:-}"
  local sdir="" decision_file=""
  if [[ -n "$run_id" ]]; then
    sdir="$(_session_dir "$run_id")"
    mkdir -p "$sdir/approvals" 2>/dev/null || true
    decision_file="$sdir/approvals/$gate.json"
  fi

  local detail_size=0
  [[ -n "$detail_file" && -f "$detail_file" ]] && \
    detail_size="$(wc -c < "$detail_file" 2>/dev/null | tr -d ' ' || echo 0)"

  emit_event "approval.request" \
    gate="$gate" \
    summary="$summary" \
    detail_path="${detail_file:-}" \
    detail_size="$detail_size" \
    decision_file="${decision_file:-}"

  # 1) Auto mode
  if [[ "${DEVLOOP_AUTO:-}" == "1" || "${DEVLOOP_AUTO:-}" == "true" ]]; then
    _approval_resolve "$gate" "approve" "auto" "$decision_file"
    return 0
  fi

  # 2) Pre-written decision file (CI / scripted / TUI-pre-write)
  if [[ -n "$decision_file" && -f "$decision_file" ]]; then
    local pre_decision=""
    pre_decision="$(_approval_read_decision "$decision_file")"
    if [[ "$pre_decision" =~ ^(approve|reject|edit)$ ]]; then
      _approval_resolve "$gate" "$pre_decision" "pre-written" ""
      case "$pre_decision" in
        approve) return 0 ;;
        reject)  return 1 ;;
        edit)    return 2 ;;
      esac
    fi
  fi

  # 2.5) TUI poll — wait up to DEVLOOP_APPROVAL_WAIT seconds for decision file.
  # devloop-tui writes the file; this loop picks it up without requiring a TTY.
  local tui_wait="${DEVLOOP_APPROVAL_WAIT:-0}"
  if [[ "$tui_wait" -gt 0 && -n "$decision_file" ]]; then
    info "⏳ Waiting up to ${tui_wait}s for TUI / external decision on gate '${gate}'..."
    local t0; t0="$(date +%s)"
    while true; do
      local now; now="$(date +%s)"
      if (( now - t0 >= tui_wait )); then
        break
      fi
      if [[ -f "$decision_file" ]]; then
        local tui_decision=""
        tui_decision="$(_approval_read_decision "$decision_file")"
        if [[ "$tui_decision" =~ ^(approve|reject|edit)$ ]]; then
          _approval_resolve "$gate" "$tui_decision" "tui-poll" ""
          case "$tui_decision" in
            approve) return 0 ;;
            reject)  return 1 ;;
            edit)    return 2 ;;
          esac
        fi
      fi
      sleep 0.2
    done
    info "TUI poll timed out after ${tui_wait}s — falling through to interactive prompt."
  fi

  # Render summary block for human prompts
  divider
  step "🚦 Approval gate: ${BOLD}$gate${RESET}"
  echo "$summary"
  if [[ -n "$detail_file" && -f "$detail_file" ]]; then
    info "Details: $detail_file (${detail_size} bytes)"
  fi
  divider

  # 3) gum choose (preferred when installed + TTY)
  if command -v gum >/dev/null 2>&1 && [[ -t 0 && -t 1 ]]; then
    local choice
    choice="$(gum choose --header "Decision:" "approve" "reject" "edit" 2>/dev/null || echo "")"
    case "$choice" in
      approve) _approval_resolve "$gate" "approve" "gum"        "$decision_file"; return 0 ;;
      reject)  _approval_resolve "$gate" "reject"  "gum"        "$decision_file"; return 1 ;;
      edit)    _approval_resolve "$gate" "edit"    "gum"        "$decision_file"; return 2 ;;
      *)       _approval_resolve "$gate" "reject"  "gum-cancel" "$decision_file"; return 1 ;;
    esac
  fi

  # 4) Read from /dev/tty (mirrors permission-prompt pattern elsewhere in this script)
  if [[ -r /dev/tty ]]; then
    local timeout="${DEVLOOP_APPROVAL_TIMEOUT:-120}"
    local ans=""
    info "[y]es / [n]o / [e]dit  (${timeout}s timeout, default = reject)"
    if read -r -t "$timeout" -p "  decision> " ans </dev/tty; then
      case "${ans:-}" in
        y|yes|a|approve) _approval_resolve "$gate" "approve" "tty"     "$decision_file"; return 0 ;;
        e|edit)          _approval_resolve "$gate" "edit"    "tty"     "$decision_file"; return 2 ;;
        n|no|r|reject)   _approval_resolve "$gate" "reject"  "tty"     "$decision_file"; return 1 ;;
        *)               _approval_resolve "$gate" "reject"  "tty-bad" "$decision_file"; return 1 ;;
      esac
    else
      warn "Approval timed out after ${timeout}s — gate stalled (not rejected)."
      emit_event "approval.decision" gate="$gate" decision="timeout" source="timeout"
      return 3
    fi
  fi

  # 5) No interactive surface
  warn "No interactive surface for approval gate '$gate' — set DEVLOOP_AUTO=1 to bypass."
  _approval_resolve "$gate" "reject" "no-tty" "$decision_file"
  return 1
}

approve_plan() {
  # approve_plan <summary> [spec_file]
  _approval_gate "plan" "$1" "${2:-}"
}

approve_diff() {
  # approve_diff <summary> [diff_file]
  _approval_gate "diff" "$1" "${2:-}"
}

# Extract a human-readable plan summary from an architect spec file.
# Pulls the Summary section (if present) and a Files-to-Touch list.
_extract_plan_summary() {
  local spec="$1"
  [[ -f "$spec" ]] || { echo "(no spec found at $spec)"; return; }
  local out=""
  if grep -qiE '^#+[[:space:]]*Summary' "$spec" 2>/dev/null; then
    out="$(awk '
      BEGIN { in_section=0 }
      /^#+[[:space:]]*[Ss]ummary/ { in_section=1; next }
      in_section && /^#+[[:space:]]/ { exit }
      in_section { print }
    ' "$spec" | sed '/^$/d' | head -12)"
  fi
  if [[ -z "$out" ]]; then
    out="$(head -c 600 "$spec" 2>/dev/null)"
  fi
  echo "$out"
  if grep -qiE '^#+[[:space:]]*Files[[:space:]]*(to[[:space:]]+Touch)?' "$spec" 2>/dev/null; then
    echo
    echo "Files to touch:"
    awk '
      BEGIN { in_section=0 }
      /^#+[[:space:]]*[Ff]iles/ { in_section=1; next }
      in_section && /^#+[[:space:]]/ { exit }
      in_section { print }
    ' "$spec" | sed '/^$/d' | head -25
  fi
}

# Extract a diff summary (stat) from the worker's commit against the baseline.
_extract_diff_summary() {
  local id="$1"
  local pre_commit_file="$SPECS_PATH/$id.pre-commit"
  local base_hash=""
  [[ -f "$pre_commit_file" ]] && base_hash="$(cat "$pre_commit_file" 2>/dev/null | head -1 | tr -d '[:space:]')"
  if [[ -n "$base_hash" ]]; then
    git diff --stat "${base_hash}..HEAD" 2>/dev/null | head -40
  else
    git diff --stat HEAD 2>/dev/null | head -40
  fi
}

# Write the full diff for the worker's commit to a session-local file.
# Returns the path on stdout (empty if no diff captured).
_capture_worker_diff() {
  local id="$1"
  local run_id="${DEVLOOP_CURRENT_SESSION_ID:-}"
  [[ -z "$run_id" ]] && return 0
  local sdir; sdir="$(_session_dir "$run_id")"
  [[ -d "$sdir" ]] || return 0
  local pre_commit_file="$SPECS_PATH/$id.pre-commit"
  local base_hash=""
  [[ -f "$pre_commit_file" ]] && base_hash="$(cat "$pre_commit_file" 2>/dev/null | head -1 | tr -d '[:space:]')"
  local out="$sdir/worker.diff"
  if [[ -n "$base_hash" ]]; then
    git diff "${base_hash}..HEAD" > "$out" 2>/dev/null || true
  else
    git diff HEAD > "$out" 2>/dev/null || true
  fi
  echo "$out"
}

# Builds a markdown template the user fills in to describe what to fix.
# The diff is appended at the bottom as read-only context.
_build_diff_feedback_template() {
  local id="$1"; local diff_path="$2"
  echo "# Diff feedback — Task $id"
  echo ""
  echo "Describe what to change. Leave this file with at least one non-comment, non-header line"
  echo "under \"Feedback\" to apply the fix; close with the file unchanged to skip this edit round."
  echo ""
  echo "## Feedback"
  echo ""
  echo "(your instructions here)"
  echo ""
  echo "## Context: current diff"
  if [[ -n "$diff_path" && -f "$diff_path" ]]; then
    echo ""
    echo '```diff'
    cat "$diff_path"
    echo '```'
  fi
}

# Returns 0 if the feedback file has content under "## Feedback" beyond the placeholder.
_diff_feedback_has_content() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  awk '
    /^## Feedback/        { in_section=1; next }
    /^## /                { if (in_section) exit; }
    in_section {
      line=$0
      # strip leading whitespace
      gsub(/^[[:space:]]+/, "", line)
      # ignore blank lines and the placeholder "(your instructions here)"
      if (line == "" || line ~ /^\(your instructions here\)$/) next
      print "HAS_CONTENT"; exit
    }
  ' "$file" | grep -q HAS_CONTENT
}

# ── cmd: dashboard — launch the Go/Bubble Tea TUI ────────────────────────────

cmd_dashboard() {
  load_config 2>/dev/null || true
  local tui
  if ! tui="$(_find_tui)"; then
    error "devloop-tui binary not found."
    echo -e "  ${GRAY}Build it with: ${CYAN}make tui-install${RESET}"
    echo -e "  ${GRAY}Or from source: ${CYAN}make tui-dev${RESET}"
    exit 1
  fi
  # exec replaces the bash process so signals, terminal modes, and exit codes
  # propagate cleanly to the TUI.
  exec "$tui" dashboard "$@"
}

# ── cmd: chat — launch the Go/Bubble Tea chat REPL ───────────────────────────

cmd_chat() {
  load_config 2>/dev/null || true
  local tui
  if ! tui="$(_find_tui)"; then
    error "devloop-tui binary not found."
    echo -e "  ${GRAY}Build it with: ${CYAN}make tui-install${RESET}"
    exit 1
  fi
  exec "$tui" chat "$@"
}

# ── cmd: view — live tmux dashboard (requires tmux) ──────────────────────────

_tmux_available() { command -v tmux &>/dev/null; }

cmd_view() {
  load_config
  local id="${1:-}"

  # Resolve session ID: explicit > active run env > latest session
  if [[ -z "$id" ]]; then
    id="${DEVLOOP_CURRENT_SESSION_ID:-}"
  fi

  local root; root="$(find_project_root 2>/dev/null || pwd)"
  local sessions_dir="$root/$DEVLOOP_DIR/sessions"

  # Fallback 1: most recently modified session in project sessions dir
  if [[ -z "$id" ]]; then
    id="$(ls -dt "$sessions_dir"/TASK-* 2>/dev/null | head -1 | xargs basename 2>/dev/null || true)"
  fi

  # Fallback 2: global last-session hint (~/.devloop/last-session) — works cross-terminal
  if [[ -z "$id" ]]; then
    local last_hint="$HOME/.devloop/last-session"
    if [[ -f "$last_hint" ]]; then
      local last_dir; last_dir="$(cat "$last_hint" 2>/dev/null | tr -d '[:space:]')"
      if [[ -d "$last_dir" ]]; then
        id="$(basename "$last_dir")"
        # Re-resolve sessions_dir to the correct project root for this session
        sessions_dir="$(dirname "$last_dir")"
      fi
    fi
  fi

  if [[ -z "$id" ]]; then
    error "No session found. Start one with: devloop run \"<feature>\""
    echo -e "  ${GRAY}Tip: must be run from within the project directory, or after a devloop run${RESET}"
    exit 1
  fi

  local dir="$sessions_dir/$id"
  # Also accept absolute dir from last-session hint
  [[ ! -d "$dir" && -d "$HOME/.devloop/last-session" ]] && \
    dir="$(cat "$HOME/.devloop/last-session" 2>/dev/null | tr -d '[:space:]')"

  if [[ ! -d "$dir" ]]; then
    error "Session directory not found: $id"
    echo -e "  ${GRAY}List sessions: ${CYAN}devloop sessions${RESET}"
    exit 1
  fi

  if ! _tmux_available; then
    warn "tmux is not installed — live multi-pane view requires tmux"
    echo ""
    echo -e "  Install on macOS:  ${CYAN}brew install tmux${RESET}"
    echo -e "  Install on Linux:  ${CYAN}apt install tmux${RESET}  or  ${CYAN}yum install tmux${RESET}"
    echo ""
    info "Falling back to inline log tail for session: ${CYAN}$id${RESET}"
    echo -e "  ${GRAY}Watching main.log (Ctrl-C to stop)${RESET}"
    echo ""
    tail -f "$dir/main.log" 2>/dev/null || cat "$dir/main.log" 2>/dev/null || echo "(no logs yet)"
    return
  fi

  # ── tmux session setup ────────────────────────────────────────────────────
  local tmux_name="devloop-$id"
  local feature="$(cat "$dir/feature.txt" 2>/dev/null || echo "$id")"

  # Kill stale completed session with same name if any
  tmux has-session -t "$tmux_name" 2>/dev/null && {
    local stt; stt="$(cat "$dir/status" 2>/dev/null || echo "")"
    [[ "$stt" != "running" ]] && tmux kill-session -t "$tmux_name" 2>/dev/null || true
  }

  if ! tmux has-session -t "$tmux_name" 2>/dev/null; then
    # Create session with header window
    tmux new-session -d -s "$tmux_name" -n "overview" -x 220 -y 50

    # Overview window: left=status/header, right=main.log tail
    # Use a portable while-loop instead of `watch` (not available on macOS by default)
    tmux send-keys -t "$tmux_name:overview" \
      "while true; do clear; echo \"DevLoop Session: $id\"; echo \"Feature: $feature\"; echo \"\"; printf 'Status: %s\n' \"\$(cat $dir/status 2>/dev/null)\"; echo \"\"; for f in $dir/*.state; do [ -f \"\$f\" ] && printf '  %-14s %s\n' \"\$(basename \$f .state)\" \"\$(cat \$f)\"; done; sleep 2; done" \
      C-m

    # Agents window: 4 panes
    tmux new-window -t "$tmux_name" -n "agents"

    # Pane 0: architect log
    tmux send-keys -t "$tmux_name:agents" \
      "echo '=== 🏗  Architect ==='; tail -f $dir/architect.log 2>/dev/null || echo '(not started yet)'" C-m

    # Pane 1: worker log (split right)
    tmux split-window -t "$tmux_name:agents" -h
    tmux send-keys -t "$tmux_name:agents" \
      "echo '=== 🔨 Worker ==='; tail -f $dir/worker.log 2>/dev/null || echo '(not started yet)'" C-m

    # Pane 2: reviewer log (split bottom-left)
    tmux split-window -t "$tmux_name:agents.0" -v
    tmux send-keys -t "$tmux_name:agents.2" \
      "echo '=== 🔍 Reviewer ==='; tail -f $dir/reviewer.log 2>/dev/null || echo '(not started yet)'" C-m

    # Pane 3: decisions / fix logs + interactive permit watcher (v4.11)
    local pq_dir; pq_dir="$(find_project_root 2>/dev/null || pwd)/$DEVLOOP_DIR/permission-queue"
    tmux split-window -t "$tmux_name:agents.1" -v
    tmux send-keys -t "$tmux_name:agents.3" \
      "echo '=== ⚡ Fix / Decisions / Permissions ==='; echo 'Watching fix rounds + permissions...'; (tail -f $dir/fix-*.log $dir/respec.log $dir/main.log 2>/dev/null & devloop permit watch 2>/dev/null) || tail -f $dir/main.log 2>/dev/null" C-m

    tmux select-pane -t "$tmux_name:agents.0"
    tmux select-window -t "$tmux_name:overview"

    success "tmux session created: ${CYAN}$tmux_name${RESET}"
    echo -e "  ${GRAY}Windows: ${CYAN}overview${RESET} | ${CYAN}agents${RESET} (Ctrl-b n/p to switch)"
    echo ""
  else
    info "Attaching to existing view: ${CYAN}$tmux_name${RESET}"
  fi

  # Attach (or switch if already inside tmux)
  if [[ -n "${TMUX:-}" ]]; then
    tmux switch-client -t "$tmux_name"
  else
    tmux attach-session -t "$tmux_name"
  fi
}

# ── cmd: sessions — list past pipeline runs ───────────────────────────────────

cmd_sessions() {
  load_config
  local subcmd="${1:-list}"; shift 2>/dev/null || true
  local filter_status="" limit=20

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status|-s) filter_status="${2:-}"; shift 2 ;;
      --last|-n)   limit="${2:-20}";       shift 2 ;;
      *)           shift ;;
    esac
  done

  local root; root="$(find_project_root 2>/dev/null || pwd)"
  local sessions_dir="$root/$DEVLOOP_DIR/sessions"

  if [[ ! -d "$sessions_dir" ]]; then
    info "No sessions recorded yet."
    echo -e "  ${GRAY}Sessions are created automatically when you run ${CYAN}devloop run${RESET}"
    return 0
  fi

  # Collect session dirs sorted by started_at (newest first)
  local dirs=()
  while IFS= read -r d; do
    [[ -d "$d" ]] && dirs+=("$d")
  done < <(ls -dt "$sessions_dir"/TASK-* 2>/dev/null | head -"$limit" || true)

  if [[ ${#dirs[@]} -eq 0 ]]; then
    info "No sessions found in: $sessions_dir"
    return 0
  fi

  echo ""
  echo -e "${BOLD}DevLoop Session History${RESET}"
  divider
  printf '  %-24s %-10s %-12s %-50s\n' "ID" "Status" "Duration" "Feature"
  echo -e "  ${GRAY}────────────────────────── ────────── ──────────── ──────────────────────────────────────────────────${RESET}"

  local shown=0
  for d in "${dirs[@]}"; do
    local run_id; run_id="$(basename "$d")"
    local feature=""; local status=""; local started=""; local finished=""

    [[ -f "$d/feature.txt" ]]    && feature="$(cat "$d/feature.txt")"
    [[ -f "$d/status" ]]         && status="$(cat "$d/status")"
    [[ -f "$d/started_at" ]]     && started="$(cat "$d/started_at")"
    [[ -f "$d/finished_at" ]]    && finished="$(cat "$d/finished_at")"

    # Apply status filter
    if [[ -n "$filter_status" && "$status" != "$filter_status" ]]; then
      continue
    fi

    # Compute duration
    local duration="running"
    if [[ -n "$started" && -n "$finished" ]]; then
      local s_epoch; s_epoch="$(date -j -f '%Y-%m-%dT%H:%M:%S' "$started" '+%s' 2>/dev/null || date -d "$started" '+%s' 2>/dev/null || echo 0)"
      local f_epoch; f_epoch="$(date -j -f '%Y-%m-%dT%H:%M:%S' "$finished" '+%s' 2>/dev/null || date -d "$finished" '+%s' 2>/dev/null || echo 0)"
      if (( s_epoch > 0 && f_epoch > 0 )); then
        local secs=$(( f_epoch - s_epoch ))
        if (( secs < 60 )); then
          duration="${secs}s"
        elif (( secs < 3600 )); then
          duration="$(( secs/60 ))m$(( secs%60 ))s"
        else
          duration="$(( secs/3600 ))h$(( (secs%3600)/60 ))m"
        fi
      fi
    fi

    # Colour status
    local status_coloured="$status"
    case "$status" in
      approved) status_coloured="${GREEN}approved${RESET}" ;;
      running)  status_coloured="${CYAN}running${RESET}" ;;
      needs-work|needs_work) status_coloured="${YELLOW}needs-work${RESET}" ;;
      rejected) status_coloured="${RED}rejected${RESET}" ;;
    esac

    local feature_short="${feature:0:50}"
    printf '  %-24s ' "$run_id"
    printf "%-10b " "$status_coloured"
    printf '%-12s ' "$duration"
    printf '%s\n' "$feature_short"

    (( shown++ )) || true
    (( shown >= limit )) && break
  done

  echo ""
  echo -e "  ${GRAY}devloop session <id>     — view detail + live logs${RESET}"
  echo -e "  ${GRAY}devloop sessions --status approved|running|needs-work${RESET}"
  echo ""
}

cmd_session() {
  load_config
  local id="${1:-}"

  if [[ -z "$id" ]]; then
    error "Usage: devloop session <run-id>"
    echo -e "  ${GRAY}List sessions: ${CYAN}devloop sessions${RESET}"
    exit 1
  fi

  local root; root="$(find_project_root 2>/dev/null || pwd)"
  local dir="$root/$DEVLOOP_DIR/sessions/$id"

  if [[ ! -d "$dir" ]]; then
    error "Session not found: $id"
    echo -e "  ${GRAY}List sessions: ${CYAN}devloop sessions${RESET}"
    exit 1
  fi

  local feature=""; local status=""; local started=""; local finished=""
  [[ -f "$dir/feature.txt" ]]  && feature="$(cat "$dir/feature.txt")"
  [[ -f "$dir/status" ]]       && status="$(cat "$dir/status")"
  [[ -f "$dir/started_at" ]]   && started="$(cat "$dir/started_at")"
  [[ -f "$dir/finished_at" ]]  && finished="$(cat "$dir/finished_at")"

  echo ""
  echo -e "${BOLD}Session: ${CYAN}$id${RESET}"
  divider
  echo -e "  ${BOLD}Feature:${RESET}  $feature"
  echo -e "  ${BOLD}Status:${RESET}   $status"
  echo -e "  ${BOLD}Started:${RESET}  $started"
  [[ -n "$finished" ]] && echo -e "  ${BOLD}Ended:${RESET}    $finished"
  echo ""

  # Show phase summary
  echo -e "  ${BOLD}Phases:${RESET}"
  for phase in architect worker reviewer fix-1 fix-2 fix-3 respec; do
    if [[ -f "$dir/$phase.state" ]]; then
      local state_line; state_line="$(cat "$dir/$phase.state")"
      local p_status="${state_line%%:*}"
      local p_time="${state_line#*:}"
      local p_icon="⏺"
      case "$p_status" in
        done|approved) p_icon="✅" ;;
        running)       p_icon="🔄" ;;
        needs-work)    p_icon="⚠️ " ;;
        rejected)      p_icon="❌" ;;
      esac
      echo -e "    $p_icon ${CYAN}$phase${RESET}  ($p_status  $p_time)"
    fi
  done
  echo ""

  # Show available logs
  echo -e "  ${BOLD}Log files:${RESET}"
  for log in "$dir"/*.log; do
    [[ -f "$log" ]] || continue
    local logname; logname="$(basename "$log")"
    local logsize; logsize="$(wc -l < "$log" 2>/dev/null || echo 0)"
    echo -e "    ${GRAY}$logname${RESET}  ($logsize lines)"
  done
  echo ""

  # If status=running, offer live tail; otherwise offer log review
  if [[ "$status" == "running" ]]; then
    echo -e "  ${CYAN}Session is active${RESET} — tailing main log (Ctrl-C to stop):"
    echo ""
    tail -f "$dir/main.log"
  else
    echo -e "  ${GRAY}View a log:  ${CYAN}tail -f $dir/<phase>.log${RESET}"
    echo -e "  ${GRAY}Or open:     ${CYAN}devloop view $id${RESET}  (requires tmux)"
    echo ""
    echo -e "  ${BOLD}Recent activity (main.log):${RESET}"
    tail -20 "$dir/main.log" 2>/dev/null | sed 's/^/    /'
    echo ""
  fi
}

# ── cmd: projects — global project registry ────────────────────────────────────

# Register the current project in ~/.devloop/projects.json.
# Called by cmd_init and cmd_run (idempotent — updates last_run if already present).
_register_project() {
  _ensure_global_dirs
  local root="${1:-$(find_project_root 2>/dev/null || pwd)}"
  local registry="$DEVLOOP_GLOBAL_DIR/projects.json"
  local name; name="$(basename "$root")"
  local stack="${PROJECT_STACK:-Unknown}"
  local main_p="${DEVLOOP_MAIN_PROVIDER:-claude}"
  local worker_p="${DEVLOOP_WORKER_PROVIDER:-copilot}"
  local now; now="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')"

  python3 - <<PYEOF
import json, sys, os

reg_path = "$registry"
root     = "$root"
name     = "$name"
stack    = "$stack"
main_p   = "$main_p"
worker_p = "$worker_p"
now      = "$now"

try:
    with open(reg_path) as f:
        projects = json.load(f)
    if not isinstance(projects, list):
        projects = []
except Exception:
    projects = []

# Find existing entry by path
idx = next((i for i, p in enumerate(projects) if p.get("path") == root), -1)
if idx >= 0:
    projects[idx]["last_run"]        = now
    projects[idx]["name"]            = name
    projects[idx]["stack"]           = stack
    projects[idx]["main_provider"]   = main_p
    projects[idx]["worker_provider"] = worker_p
else:
    projects.append({
        "path":            root,
        "name":            name,
        "stack":           stack,
        "main_provider":   main_p,
        "worker_provider": worker_p,
        "last_run":        now,
        "last_task_id":    None,
        "daemon_pid":      None
    })

with open(reg_path, "w") as f:
    json.dump(projects, f, indent=2)
PYEOF
}

# Unregister current project (called by cmd_clean --unregister)
_unregister_project() {
  _ensure_global_dirs
  local root="${1:-$(find_project_root 2>/dev/null || pwd)}"
  local registry="$DEVLOOP_GLOBAL_DIR/projects.json"

  python3 - <<PYEOF
import json

reg_path = "$registry"
root     = "$root"

try:
    with open(reg_path) as f:
        projects = json.load(f)
    if not isinstance(projects, list):
        projects = []
except Exception:
    projects = []

projects = [p for p in projects if p.get("path") != root]

with open(reg_path, "w") as f:
    json.dump(projects, f, indent=2)
PYEOF
}

cmd_projects() {
  _ensure_global_dirs
  local registry="$DEVLOOP_GLOBAL_DIR/projects.json"
  local subcmd="${1:-list}"; shift 2>/dev/null || true

  case "$subcmd" in
    # ── switch: print cd command for a project ──────────────────────────────
    switch)
      local target="${1:-}"
      if [[ -z "$target" ]]; then
        error "Usage: devloop projects switch <name|path>"
        exit 1
      fi
      local found_path
      found_path="$(python3 - <<PYEOF
import json
try:
    with open("$registry") as f:
        projects = json.load(f)
except Exception:
    projects = []
for p in projects:
    if p.get("name") == "$target" or p.get("path") == "$target":
        print(p.get("path",""))
        break
PYEOF
)"
      if [[ -z "$found_path" ]]; then
        error "Project not found: $target"
        echo -e "  ${GRAY}List projects: ${CYAN}devloop projects${RESET}"
        exit 1
      fi
      echo "$found_path"
      ;;

    # ── list (default): table of all registered projects ────────────────────
    list|*)
      local project_count
      project_count="$(python3 -c "import json; d=json.load(open('$registry')); print(len(d))" 2>/dev/null || echo 0)"

      echo ""
      echo -e "${BOLD}DevLoop Projects${RESET}  ${GRAY}(${project_count} registered)${RESET}"
      divider
      printf '  %-20s %-20s %-18s %-12s %s\n' "Name" "Stack" "Providers" "Last Run" "Status"
      echo -e "  ${GRAY}──────────────────── ──────────────────── ────────────────── ──────────── ──────────${RESET}"

      python3 - <<PYEOF
import json, os, sys
from datetime import datetime, timezone

try:
    with open("$registry") as f:
        projects = json.load(f)
    if not isinstance(projects, list):
        projects = []
except Exception:
    projects = []

if not projects:
    print("  (no projects registered — run devloop init in a project to register it)")
    sys.exit(0)

now_ts = datetime.now(timezone.utc)

for p in projects:
    name    = (p.get("name") or "?")[:20]
    stack   = (p.get("stack") or "?")[:20]
    main_p  = p.get("main_provider", "claude")[:6]
    wrkr_p  = p.get("worker_provider", "copilot")[:7]
    provs   = f"{main_p}+{wrkr_p}"

    last_run = p.get("last_run", "")
    if last_run:
        try:
            dt = datetime.fromisoformat(last_run.replace("Z", "+00:00"))
            diff = now_ts - dt
            s = int(diff.total_seconds())
            if s < 60:       ago = f"{s}s ago"
            elif s < 3600:   ago = f"{s//60}m ago"
            elif s < 86400:  ago = f"{s//3600}h ago"
            else:             ago = f"{s//86400}d ago"
        except Exception:
            ago = last_run[:10]
    else:
        ago = "never"

    # Quick status: check if project path still exists; check for daemon pid
    path  = p.get("path", "")
    if not os.path.isdir(path):
        status = "MISSING"
    else:
        dpid = p.get("daemon_pid")
        if dpid and os.path.exists(f"/proc/{dpid}"):
            status = "DAEMON ▶"
        else:
            status = "IDLE"

    print(f"  {name:<20} {stack:<20} {provs:<18} {ago:<12} {status}")

PYEOF
      echo ""
      echo -e "  ${GRAY}devloop projects switch <name>   — print cd path for a project${RESET}"
      echo -e "  ${GRAY}eval \$(devloop projects switch <name>)   — actually cd to it${RESET}"
      echo ""
      ;;
  esac
}

# ── cmd: replay — replay session logs with optional phase filter ──────────────

cmd_replay() {
  load_config
  local id="${1:-}"
  local phase_filter="${2:-}"

  # Parse optional --phase flag
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --phase) phase_filter="${2:-}"; shift 2 ;;
      *)       [[ -z "$id" ]] && id="$1"; shift ;;
    esac
  done

  if [[ -z "$id" ]]; then
    error "Usage: devloop replay <run-id> [--phase architect|worker|reviewer|fix-N|respec]"
    echo -e "  ${GRAY}List sessions: ${CYAN}devloop sessions${RESET}"
    exit 1
  fi

  local root; root="$(find_project_root 2>/dev/null || pwd)"
  local dir="$root/$DEVLOOP_DIR/sessions/$id"

  if [[ ! -d "$dir" ]]; then
    error "Session not found: $id"
    echo -e "  ${GRAY}List sessions: ${CYAN}devloop sessions${RESET}"
    exit 1
  fi

  local feature=""; local status=""
  [[ -f "$dir/feature.txt" ]] && feature="$(cat "$dir/feature.txt")"
  [[ -f "$dir/status" ]]      && status="$(cat "$dir/status")"

  echo ""
  echo -e "${BOLD}🎬 Replaying session: ${CYAN}$id${RESET}"
  echo -e "   Feature: $feature  |  Status: $status"
  divider
  echo ""

  # Determine which logs to replay
  local log_order=(architect worker reviewer fix-1 fix-2 fix-3 respec)
  local phases_replayed=0

  for phase in "${log_order[@]}"; do
    local log_file="$dir/$phase.log"
    [[ -f "$log_file" ]] || continue

    # Filter by phase if requested
    if [[ -n "$phase_filter" && "$phase" != "$phase_filter" ]]; then
      continue
    fi

    local line_count; line_count="$(wc -l < "$log_file" 2>/dev/null || echo 0)"
    echo -e "${BOLD}── Phase: ${CYAN}$phase${RESET} ${GRAY}($line_count lines)${RESET} ──"
    echo ""

    # Read and stream each line with a small delay for readability
    local line_num=0
    while IFS= read -r line; do
      (( line_num++ ))
      echo "$line"
      # Throttle replay to make it readable (every 50 lines, pause briefly)
      if (( line_num % 50 == 0 )); then
        sleep 0.05
      fi
    done < "$log_file"

    echo ""
    echo -e "${GRAY}── end $phase ──${RESET}"
    echo ""
    (( phases_replayed++ ))
  done

  if [[ "$phases_replayed" -eq 0 ]]; then
    if [[ -n "$phase_filter" ]]; then
      warn "No log found for phase: $phase_filter"
      echo -e "  ${GRAY}Available phases: architect, worker, reviewer, fix-1, fix-2, fix-3, respec${RESET}"
    else
      warn "No phase logs found for session: $id"
      echo -e "  ${GRAY}The session may still be running. Try: ${CYAN}devloop session $id${RESET}"
    fi
  else
    echo -e "${GRAY}Replayed $phases_replayed phase(s) for session: $id${RESET}"
    echo -e "  ${GRAY}Replay a specific phase: ${CYAN}devloop replay $id --phase worker${RESET}"
    echo ""
  fi
}

# ── cmd: inbox — human review queue ──────────────────────────────────────────

# Write an item to the project inbox (called by permission hooks and pipeline phases)
_inbox_write() {
  local project_root="${1:-$(find_project_root 2>/dev/null || pwd)}"
  local type="${2:-permission}"       # permission | needs-work | blocked | info
  local message="$3"
  local task_id="${4:-${DEVLOOP_CURRENT_SESSION_ID:-}}"
  local tool="${5:-}"
  local command_text="${6:-}"

  local inbox_dir="$project_root/$DEVLOOP_DIR"
  mkdir -p "$inbox_dir"
  local inbox_file="$inbox_dir/inbox.json"
  [[ -f "$inbox_file" ]] || echo "[]" > "$inbox_file"

  local item_id; item_id="inbox-$(date '+%Y%m%d-%H%M%S')-$$"
  local now; now="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')"
  local project_name; project_name="$(basename "$project_root")"

  python3 - <<PYEOF
import json, sys

inbox_path  = "$inbox_file"
item_id     = "$item_id"
project     = "$project_name"
task_id     = "$task_id"
itype       = "$type"
message     = """$message"""
tool        = "$tool"
cmd_text    = """$command_text"""
now         = "$now"

try:
    with open(inbox_path) as f:
        items = json.load(f)
    if not isinstance(items, list):
        items = []
except Exception:
    items = []

items.append({
    "id":           item_id,
    "project":      project,
    "task_id":      task_id,
    "type":         itype,
    "message":      message,
    "tool":         tool,
    "command":      cmd_text,
    "created_at":   now,
    "resolved_at":  None,
    "resolution":   None
})

with open(inbox_path, "w") as f:
    json.dump(items, f, indent=2)
PYEOF

  # macOS notification (non-blocking)
  if [[ "${DEVLOOP_NOTIFY_SOUND:-true}" == "true" ]] && command -v osascript &>/dev/null; then
    local notif_title="DevLoop: $project_name"
    local notif_body="$message"
    osascript -e "display notification \"$notif_body\" with title \"$notif_title\" sound name \"Glass\"" 2>/dev/null || true
  fi

  # Webhook notification
  if [[ -n "${DEVLOOP_NOTIFY_WEBHOOK:-}" ]]; then
    local payload; payload="$(python3 -c "
import json
print(json.dumps({'project': '$project_name', 'type': '$type', 'message': '''$message''', 'task_id': '$task_id'}))
" 2>/dev/null || true)"
    [[ -n "$payload" ]] && \
      curl -fsSL -X POST -H 'Content-Type: application/json' -d "$payload" "$DEVLOOP_NOTIFY_WEBHOOK" -o /dev/null 2>/dev/null || true
  fi
}

cmd_inbox() {
  load_config 2>/dev/null || true
  local subcmd="${1:-list}"; shift 2>/dev/null || true
  local show_all=false
  local project_root; project_root="$(find_project_root 2>/dev/null || pwd)"

  while [[ "${subcmd}" == --* ]]; do
    case "$subcmd" in
      --all) show_all=true; subcmd="${1:-list}"; shift 2>/dev/null || true ;;
      *)     subcmd="list" ;;
    esac
  done

  _inbox_list() {
    local inbox_file="$1"
    [[ -f "$inbox_file" ]] || { echo "  (no inbox file)"; return; }

    python3 - <<PYEOF
import json, sys
from datetime import datetime, timezone

try:
    with open("$inbox_file") as f:
        items = json.load(f)
    if not isinstance(items, list):
        items = []
except Exception:
    items = []

pending = [i for i in items if not i.get("resolved_at")]
resolved = [i for i in items if i.get("resolved_at")]

if not items:
    print("  (inbox is empty)")
    sys.exit(0)

now_ts = datetime.now(timezone.utc)

def ago(ts):
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        diff = now_ts - dt
        s = int(diff.total_seconds())
        if s < 60:      return f"{s}s ago"
        elif s < 3600:  return f"{s//60}m ago"
        elif s < 86400: return f"{s//3600}h ago"
        else:            return f"{s//86400}d ago"
    except Exception:
        return ts[:10]

RESET  = "\033[0m"
BOLD   = "\033[1m"
CYAN   = "\033[96m"
YELLOW = "\033[93m"
GREEN  = "\033[92m"
RED    = "\033[91m"
GRAY   = "\033[90m"

print(f"\n{BOLD}🔔 DevLoop Inbox{RESET}  {GRAY}({len(pending)} pending, {len(resolved)} resolved){RESET}\n")

for item in pending:
    itype = item.get("type", "?")
    if itype == "permission":
        icon = f"{YELLOW}⚠ PERMISSION{RESET}"
    elif itype == "needs-work":
        icon = f"{YELLOW}⟳ NEEDS_WORK{RESET}"
    elif itype == "blocked":
        icon = f"{RED}⛔ BLOCKED{RESET}"
    else:
        icon = f"{CYAN}ℹ {itype.upper()}{RESET}"

    proj    = item.get("project", "?")
    task_id = item.get("task_id", "?")
    msg     = item.get("message", "")
    tool    = item.get("tool", "")
    cmd     = item.get("command", "")
    created = ago(item.get("created_at", ""))
    iid     = item.get("id", "")

    print(f"  {BOLD}▶  [{proj} / {task_id}]{RESET}  {icon}")
    print(f"     {msg}")
    if tool:
        print(f"     Tool: {CYAN}{tool}{RESET}", end="")
        if cmd:
            print(f"  →  {GRAY}{cmd}{RESET}", end="")
        print()
    print(f"     Created: {GRAY}{created}{RESET}  ID: {GRAY}{iid}{RESET}")
    print()

if resolved:
    print(f"  {GRAY}── {len(resolved)} resolved item(s) (run devloop inbox history to view) ──{RESET}")
PYEOF
  }

  case "$subcmd" in
    # ── resolve: mark an item resolved ──────────────────────────────────────
    resolve)
      local item_id="${1:-}"
      local resolution="${2:-approved}"
      if [[ -z "$item_id" ]]; then
        error "Usage: devloop inbox resolve <item-id> [approved|denied|skipped]"
        exit 1
      fi
      local inbox_file="$project_root/$DEVLOOP_DIR/inbox.json"
      local now; now="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')"
      python3 - <<PYEOF
import json
inbox_path = "$inbox_file"
item_id    = "$item_id"
resolution = "$resolution"
now        = "$now"
try:
    with open(inbox_path) as f:
        items = json.load(f)
    if not isinstance(items, list):
        items = []
except Exception:
    items = []; ok = False
ok = False
for item in items:
    if item.get("id") == item_id:
        item["resolved_at"] = now
        item["resolution"]  = resolution
        ok = True
        break
with open(inbox_path, "w") as f:
    json.dump(items, f, indent=2)
print("resolved" if ok else "not-found")
PYEOF
      success "Inbox item $item_id marked as: $resolution"
      ;;

    # ── history: show resolved items ─────────────────────────────────────────
    history)
      local inbox_file="$project_root/$DEVLOOP_DIR/inbox.json"
      [[ -f "$inbox_file" ]] || { info "No inbox history."; return; }
      python3 - <<PYEOF
import json
try:
    with open("$inbox_file") as f:
        items = json.load(f)
except Exception:
    items = []
resolved = [i for i in items if i.get("resolved_at")]
if not resolved:
    print("  (no resolved items)")
else:
    for i in resolved:
        print(f"  {i.get('id','')}  [{i.get('resolution','')}]  {i.get('message','')[:60]}  ({i.get('resolved_at','')[:10]})")
PYEOF
      ;;

    # ── clear: remove all resolved items ─────────────────────────────────────
    clear)
      local inbox_file="$project_root/$DEVLOOP_DIR/inbox.json"
      [[ -f "$inbox_file" ]] || { info "Nothing to clear."; return; }
      python3 - <<PYEOF
import json
try:
    with open("$inbox_file") as f:
        items = json.load(f)
except Exception:
    items = []
pending = [i for i in items if not i.get("resolved_at")]
removed = len(items) - len(pending)
with open("$inbox_file", "w") as f:
    json.dump(pending, f, indent=2)
print(f"Cleared {removed} resolved item(s). {len(pending)} pending remain.")
PYEOF
      ;;

    # ── list (default) ────────────────────────────────────────────────────────
    list|*)
      if [[ "$show_all" == "true" ]]; then
        # Scan all registered projects
        local registry="$DEVLOOP_GLOBAL_DIR/projects.json"
        local proj_paths
        proj_paths="$(python3 -c "import json; d=json.load(open('$registry')); [print(p['path']) for p in d]" 2>/dev/null || true)"
        if [[ -z "$proj_paths" ]]; then
          info "No registered projects. Run devloop init in each project first."
          return
        fi
        local total_pending=0
        while IFS= read -r ppath; do
          local pinbox="$ppath/$DEVLOOP_DIR/inbox.json"
          if [[ -f "$pinbox" ]]; then
            local cnt; cnt="$(python3 -c "import json; d=json.load(open('$pinbox')); print(sum(1 for i in d if not i.get('resolved_at')))" 2>/dev/null || echo 0)"
            (( total_pending += cnt )) || true
            if (( cnt > 0 )); then
              echo -e "\n  ${BOLD}Project: $(basename "$ppath")${RESET}  ${GRAY}($cnt pending)${RESET}"
              _inbox_list "$pinbox"
            fi
          fi
        done <<< "$proj_paths"
        if (( total_pending == 0 )); then
          success "All inboxes clear across all registered projects"
        fi
      else
        _inbox_list "$project_root/$DEVLOOP_DIR/inbox.json"
        echo ""
        echo -e "  ${GRAY}devloop inbox resolve <id> [approved|denied|skipped]${RESET}"
        echo -e "  ${GRAY}devloop inbox history   — view resolved items${RESET}"
        echo -e "  ${GRAY}devloop inbox --all      — view across all registered projects${RESET}"
        echo ""
      fi
      ;;
  esac
}

# ── cmd: stats — aggregated pipeline metrics ──────────────────────────────────

cmd_stats() {
  load_config 2>/dev/null || true
  local root; root="$(find_project_root 2>/dev/null || pwd)"
  local sessions_dir="$root/$DEVLOOP_DIR/sessions"
  local project_name; project_name="$(basename "$root")"

  echo ""
  echo -e "${BOLD}DevLoop Stats — ${CYAN}$project_name${RESET}"
  divider

  if [[ ! -d "$sessions_dir" ]]; then
    info "No sessions recorded yet."
    echo -e "  ${GRAY}Run ${CYAN}devloop run \"feature\"${RESET}${GRAY} to start tracking pipeline metrics.${RESET}"
    return 0
  fi

  python3 - <<PYEOF
import os, json, re
from datetime import datetime, timezone

sessions_dir = "$sessions_dir"

total = 0
approved = 0
needs_work = 0
rejected = 0
total_fix_rounds = 0
durations_s = []
phase_durations = {"architect": [], "worker": [], "reviewer": []}

for entry in sorted(os.listdir(sessions_dir)):
    d = os.path.join(sessions_dir, entry)
    if not os.path.isdir(d):
        continue
    total += 1

    status_file = os.path.join(d, "status")
    status = ""
    if os.path.isfile(status_file):
        with open(status_file) as f:
            status = f.read().strip()

    if status == "approved":
        approved += 1
    elif "needs" in status:
        needs_work += 1
    elif status == "rejected":
        rejected += 1

    # Count fix rounds by counting fix-N.state files
    fix_rounds = 0
    for fname in os.listdir(d):
        if re.match(r"fix-\d+\.state", fname):
            fix_rounds += 1
    total_fix_rounds += fix_rounds

    # Compute total duration
    started_f  = os.path.join(d, "started_at")
    finished_f = os.path.join(d, "finished_at")
    if os.path.isfile(started_f) and os.path.isfile(finished_f):
        try:
            with open(started_f) as f:  s_ts = f.read().strip()
            with open(finished_f) as f: e_ts = f.read().strip()
            s_dt = datetime.fromisoformat(s_ts.replace("Z","+00:00"))
            e_dt = datetime.fromisoformat(e_ts.replace("Z","+00:00"))
            durations_s.append(int((e_dt - s_dt).total_seconds()))
        except Exception:
            pass

    # Phase durations from .state files: "done:HH:MM:SS-HH:MM:SS"
    for phase in ["architect", "worker", "reviewer"]:
        state_f = os.path.join(d, f"{phase}.state")
        if os.path.isfile(state_f):
            try:
                with open(state_f) as f:
                    line = f.read().strip()
                # Format: status:started:ended
                parts = line.split(":", 2)
                if len(parts) == 3:
                    _, ts_start, ts_end = parts
                    s_dt = datetime.fromisoformat(ts_start.replace("Z","+00:00"))
                    e_dt = datetime.fromisoformat(ts_end.replace("Z","+00:00"))
                    phase_durations[phase].append(int((e_dt - s_dt).total_seconds()))
            except Exception:
                pass

if total == 0:
    print("  No completed sessions yet.")
else:
    def fmt_s(s):
        if s < 60:   return f"{s}s"
        elif s < 3600: return f"{s//60}m {s%60}s"
        else:          return f"{s//3600}h {(s%3600)//60}m"

    def avg(lst):
        return sum(lst) // len(lst) if lst else 0

    RESET  = "\033[0m"
    BOLD   = "\033[1m"
    CYAN   = "\033[96m"
    GREEN  = "\033[92m"
    YELLOW = "\033[93m"
    GRAY   = "\033[90m"

    approved_pct = int(approved / total * 100) if total else 0
    fix_avg = total_fix_rounds / total if total else 0

    print(f"  {BOLD}Total pipeline runs:{RESET}       {CYAN}{total}{RESET}")
    print(f"  {BOLD}APPROVED (first pass):{RESET}     {GREEN}{approved}{RESET} / {total}  ({approved_pct}%)")
    print(f"  {BOLD}NEEDS_WORK (exhausted):{RESET}    {YELLOW}{needs_work}{RESET}")
    print(f"  {BOLD}REJECTED:{RESET}                  {needs_work and str(rejected) or str(rejected)}")
    print(f"  {BOLD}Avg fix rounds per run:{RESET}    {fix_avg:.1f}")
    print()

    if durations_s:
        print(f"  {BOLD}Avg total pipeline time:{RESET}   {fmt_s(avg(durations_s))}")
    for phase, times in phase_durations.items():
        if times:
            print(f"  {BOLD}Avg {phase} time:{RESET}{'':>{20-len(phase)}} {fmt_s(avg(times))}")
    print()

    # Session run history (last 5)
    print(f"  {GRAY}── Recent runs ──{RESET}")
    runs = sorted(
        [e for e in os.listdir(sessions_dir) if os.path.isdir(os.path.join(sessions_dir, e))],
        reverse=True
    )[:5]
    for run in runs:
        d2 = os.path.join(sessions_dir, run)
        feat = ""
        st   = ""
        feat_f = os.path.join(d2, "feature.txt")
        stat_f = os.path.join(d2, "status")
        if os.path.isfile(feat_f):
            with open(feat_f) as f: feat = f.read().strip()[:50]
        if os.path.isfile(stat_f):
            with open(stat_f) as f: st = f.read().strip()
        print(f"  {GRAY}{run}{RESET}  [{st:12}]  {feat}")
PYEOF
  echo ""
  echo -e "  ${GRAY}devloop sessions         — full session list${RESET}"
  echo -e "  ${GRAY}devloop session <id>     — per-run detail${RESET}"
  echo ""
}


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

  # Inject global lessons for this stack (from ~/.devloop/lessons.md) if available
  local global_lessons_preamble=""
  local global_lessons_file="$DEVLOOP_GLOBAL_DIR/lessons.md"
  if [[ -f "$global_lessons_file" ]]; then
    local stack_lessons
    stack_lessons="$(awk -v stack="$PROJECT_STACK" -v allstack="All Stacks" '
      /^## / { in_section = ($0 == "## " stack || $0 == "## " allstack); next }
      in_section && /^- / { print }
    ' "$global_lessons_file" 2>/dev/null || true)"
    if [[ -n "$stack_lessons" ]]; then
      global_lessons_preamble="
## Global Lessons (${PROJECT_STACK})
_Apply these lessons proactively when designing the spec:_
$stack_lessons
"
    fi
  fi

  local prompt
  prompt="$(cat <<PROMPT
You are a senior software architect. Design a precise implementation spec for GitHub Copilot CLI.
${global_lessons_preamble}
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
    if ! grep -q '^## Copilot Instructions Block' "$spec_file"; then
      warn "⚠  Spec $id appears INCOMPLETE — header '## Copilot Instructions Block' is missing."
      warn "   LLM output may have been truncated. Running 'devloop work $id' will fail."
      warn "   Re-run: devloop architect \"$feature\""
    fi
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
    local _feat; _feat="$(awk '/^\*\*Feature\*\*:/{sub(/^\*\*Feature\*\*: /,""); print; exit}' "$spec_file")"
    [[ -z "$_feat" ]] && _feat="<feature>"
    error "Spec $id is missing '## Copilot Instructions Block' — likely truncated by LLM."
    info  "Regenerate: devloop architect \"$_feat\""
    info  "Then retry: devloop work $id"
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
  # Use PID+RANDOM for guaranteed uniqueness; fall back to mktemp if needed
  tmp_spec="/tmp/devloop_task_$$_${RANDOM}.md"
  rm -f "$tmp_spec"   # remove any stale file at this path
  : > "$tmp_spec"     # create atomically
  echo "$launch_prompt" > "$tmp_spec"

  local attempt_provider="$provider"
  while true; do
    local tmp_out; tmp_out="/tmp/devloop_work_out_$$_${RANDOM}"
    rm -f "$tmp_out"; : > "$tmp_out"
    local rc=0
    case "$attempt_provider" in
      claude)
        # --allowedTools scopes what the worker can call (no system ops outside project)
        local _worker_tools="Read,Write,Edit,MultiEdit,Bash(git*),Bash(pytest*),Bash(npm*),Bash(yarn*),Bash(pnpm*),Bash(cargo*),Bash(go*),Bash(python*),Bash(make*),Bash(cat*),Bash(grep*),Bash(find*),Bash(ls*),Bash(mkdir*),Bash(mv*),Bash(cp*),Bash(rm -f*),Glob,LS"
        local _worker_model="${CLAUDE_WORKER_MODEL:-${CLAUDE_MODEL:-sonnet}}"
        if [[ -n "${DEVLOOP_SESSION_PHASE_LOG:-}" ]]; then
          if ! cat "$tmp_spec" | claude -p --model "$_worker_model" --allowedTools "$_worker_tools" 2>&1 | tee -a "$DEVLOOP_SESSION_PHASE_LOG" > "$tmp_out"; then
            cat "$tmp_spec" | claude -p --model "$_worker_model" 2>&1 | tee -a "$DEVLOOP_SESSION_PHASE_LOG" > "$tmp_out" || rc=$?
          fi
        else
          if ! cat "$tmp_spec" | claude -p --model "$_worker_model" --allowedTools "$_worker_tools" > "$tmp_out" 2>&1; then
            cat "$tmp_spec" | claude -p --model "$_worker_model" > "$tmp_out" 2>&1 || rc=$?
          fi
        fi
        ;;
      opencode)
        opencode run --file "$tmp_spec" "Implement the DevLoop task spec in the attached file exactly as described. Stage ALL changed files and commit with the TASK ID in the message. Summarize what was implemented." 2>&1 | tee "$tmp_out" || rc=$?
        ;;
      pi)
        pi --mode json "$launch_prompt" 2>&1 | tee "$tmp_out" | cat || rc=$?
        ;;
      *)  # copilot
        if [[ -n "${DEVLOOP_SESSION_PHASE_LOG:-}" ]]; then
          copilot --allow-all-tools --allow-all-paths -p "$(cat "$tmp_spec")" 2>&1 | tee -a "$DEVLOOP_SESSION_PHASE_LOG" | tee "$tmp_out" || rc=$?
        else
          copilot --allow-all-tools --allow-all-paths -p "$(cat "$tmp_spec")" 2>&1 | tee "$tmp_out" || rc=$?
        fi
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

  # Phase 3: opt-in extra instructions from the diff-gate edit-on-reject flow.
  if [[ -n "${DEVLOOP_FIX_EXTRA_INSTRUCTIONS:-}" && -f "$DEVLOOP_FIX_EXTRA_INSTRUCTIONS" ]]; then
    local _extra
    _extra="$(cat "$DEVLOOP_FIX_EXTRA_INSTRUCTIONS")"
    fix_prompt+="

## Additional human feedback

$_extra
"
  fi

  local attempt_fix_provider="$provider"
  while true; do
    local tmp_fix_out; tmp_fix_out="/tmp/devloop_fix_out_$$_${RANDOM}"
    rm -f "$tmp_fix_out"; : > "$tmp_fix_out"
    local rc=0
    if [[ "$attempt_fix_provider" == "claude" ]]; then
      local _worker_tools="Read,Write,Edit,MultiEdit,Bash(git*),Bash(pytest*),Bash(npm*),Bash(yarn*),Bash(pnpm*),Bash(cargo*),Bash(go*),Bash(python*),Bash(make*),Bash(cat*),Bash(grep*),Bash(find*),Bash(ls*),Bash(mkdir*),Bash(mv*),Bash(cp*),Bash(rm -f*),Glob,LS"
      local _worker_model="${CLAUDE_WORKER_MODEL:-${CLAUDE_MODEL:-sonnet}}"
      if ! echo "$fix_prompt" | claude -p --model "$_worker_model" --allowedTools "$_worker_tools" > "$tmp_fix_out" 2>&1; then
        echo "$fix_prompt" | claude -p --model "$_worker_model" > "$tmp_fix_out" 2>&1 || rc=$?
      fi
    elif [[ "$attempt_fix_provider" == "opencode" ]]; then
      local tmp_fix; tmp_fix="/tmp/devloop_fix_$$_${RANDOM}.md"
      rm -f "$tmp_fix"
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
  # Phase 3: if TTY + TUI binary + DEVLOOP_STATUS_VIEW != "text", delegate to live view.
  if [[ -t 1 ]] && [[ "${DEVLOOP_STATUS_VIEW:-tui}" != "text" ]]; then
    local _tui
    if _tui="$(_find_tui 2>/dev/null)"; then
      exec "$_tui" status "$@"
    fi
  fi
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

  # ── Propagate new config keys to all registered projects ───────────────────
  _propagate_update_to_registered_projects "${new_version:-$current_version}"
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

# Merge-only init: add missing config keys to devloop.config.sh without touching other files
_cmd_init_merge() {
  local root; root="$(find_project_root 2>/dev/null || echo "")"
  if [[ -z "$root" ]] || [[ ! -f "$root/$CONFIG_FILE" ]]; then
    error "No devloop.config.sh found. Run ${CYAN}devloop init${RESET} first."
    exit 1
  fi

  step "🔀 Merging new config keys into: ${CYAN}$(basename "$root")${RESET}"
  divider

  local added_keys; added_keys="$(_merge_devloop_config_defaults "$root/$CONFIG_FILE" 2>/dev/null || echo 0)"
  if (( added_keys > 0 )); then
    success "Added ${BOLD}$added_keys${RESET} new config key(s) to ${CYAN}devloop.config.sh${RESET}"
    echo -e "  ${GRAY}Review and configure them: ${CYAN}devloop configure${RESET}"
  else
    success "devloop.config.sh is already up to date ✅"
  fi
  echo ""
}

# After a binary update: offer to propagate new config keys to all registered projects
_propagate_update_to_registered_projects() {
  local new_ver="${1:-}"
  local registry="$DEVLOOP_GLOBAL_DIR/projects.json"
  [[ -f "$registry" ]] || return 0

  local project_count
  project_count="$(python3 -c "
import json
try:
    d = json.load(open('$registry'))
    print(len(d))
except Exception:
    print(0)
" 2>/dev/null || echo 0)"

  (( project_count == 0 )) && return 0

  # Skip propagation if auto-merge disabled globally
  if [[ "${DEVLOOP_AUTO_MERGE:-true}" == "false" ]]; then
    info "Skipping project propagation (DEVLOOP_AUTO_MERGE=false)"
    return 0
  fi

  echo ""
  step "📡 Propagating config keys to ${BOLD}$project_count${RESET} registered project(s)..."
  echo ""

  local current_dir="$PWD"

  python3 - <<PYEOF
import json, os, subprocess, sys
try:
    projects = json.load(open('$registry'))
except Exception:
    sys.exit(0)
for p in projects:
    path = p.get('path', '')
    name = p.get('name', os.path.basename(path))
    config = os.path.join(path, 'devloop.config.sh')
    if not path or not os.path.isfile(config):
        continue
    print(f"  {path}")
PYEOF

  while IFS= read -r proj_path; do
    proj_path="${proj_path#  }"  # strip leading spaces
    [[ -z "$proj_path" ]] && continue
    local proj_name; proj_name="$(basename "$proj_path")"
    local proj_config="$proj_path/$CONFIG_FILE"

    if [[ "$proj_path" == "$current_dir" ]] || [[ "$proj_path" == "$(find_project_root 2>/dev/null)" ]]; then
      # Already handled by _refresh_project_for_version
      echo -e "  ${GRAY}↳ $proj_name — skipped (current project)${RESET}"
      continue
    fi

    if [[ "${DEVLOOP_AUTO_MERGE:-true}" == "false" ]]; then
      echo -e "  ${YELLOW}↳ $proj_name — skipped (DEVLOOP_AUTO_MERGE=false)${RESET}"
      continue
    fi

    local added; added="$(cd "$proj_path" && _merge_devloop_config_defaults "$proj_config" 2>/dev/null || echo 0)"
    if (( added > 0 )); then
      echo -e "  ${GREEN}✓${RESET} $proj_name — merged $added new key(s)"
    else
      echo -e "  ${GRAY}✓ $proj_name — already up to date${RESET}"
    fi
  done < <(python3 - <<PYEOF
import json, os
try:
    projects = json.load(open('$registry'))
except Exception:
    import sys; sys.exit(0)
for p in projects:
    path = p.get('path', '')
    config = os.path.join(path, 'devloop.config.sh')
    if path and os.path.isfile(config):
        print(f"  {path}")
PYEOF
)
  echo ""
  success "Update propagation complete ✅"
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

# ── _parse_issues_table: extract issue rows from a review file ────────────────
# Parses "| # | Severity | File/Area | Issue |" markdown table.
# Outputs one "SEVERITY|AREA|ISSUE" line per data row (skips header/separator).
# Used by cmd_run to compute issue deltas between fix rounds.

_parse_issues_table() {
  local review_file="$1"
  [[ -f "$review_file" ]] || return 0
  awk '
    /\| *#.*Severity.*Issue/ { in_table=1; next }
    /^\|[-: |]+\|/           { next }
    in_table && /^\| *[0-9]/ {
      line = $0
      gsub(/^\| *[0-9]+ *\| */, "", line)   # strip "| N |"
      n = split(line, parts, "|")
      if (n >= 3) {
        sev  = parts[1]; sub(/^ +/, "", sev); sub(/ +$/, "", sev)
        area = parts[2]; sub(/^ +/, "", area); sub(/ +$/, "", area)
        issue= parts[3]; sub(/^ +/, "", issue); sub(/ +$/, "", issue)
        printf "%s|%s|%s
", sev, area, issue
      }
    }
    in_table && !/^\|/ { in_table=0 }
  ' "$review_file" 2>/dev/null
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

  # ── Step 0: diagnose root cause before redesigning ──────────────────────────
  local main_p; main_p="$(effective_main_provider)"
  local diagnosis=""
  local diag_tmp; diag_tmp="$(mktemp /tmp/devloop-diag-XXXXXX)"
  local diag_prompt
  printf '%s' "Given this task spec and its full fix history, write ONE sentence identifying the root cause of repeated failures. Root causes are typically: ambiguous requirements, wrong approach chosen, missing edge case enumeration, or implementation complexity mismatched to spec.

## Spec
$orig_spec

## Fix History
$fix_history_text

Respond with only a single sentence starting with: Root cause:" > "$diag_tmp.prompt"
  diag_prompt="$(cat "$diag_tmp.prompt")"
  rm -f "$diag_tmp.prompt"
  run_provider_prompt "$main_p" "$diag_prompt" "$diag_tmp"
  diagnosis="$(head -3 "$diag_tmp" 2>/dev/null)"
  rm -f "$diag_tmp"
  if [[ -n "$diagnosis" ]]; then
    info "Diagnosis: $diagnosis"
    echo ""
  fi

  local respec_prompt
  respec_prompt="You are redesigning a task spec that has repeatedly failed code review.
The original implementation kept getting NEEDS_WORK despite multiple fix attempts.
Your job: rewrite the spec to be clearer, more precise, and avoid the recurring pitfalls.

Diagnosed root cause: $diagnosis

## Original Spec
$orig_spec

## Full Review & Fix History (what kept failing)
$fix_history_text

## Your Task
1. Address the diagnosed root cause above first
2. Redesign the spec to eliminate those root causes
3. Add explicit acceptance criteria for every issue that kept recurring
4. Be more prescriptive about implementation details where workers went wrong

Output a complete revised spec in the SAME format as the original.
Keep the same task ID ($id) and title, but mark Status as: ♻️ respecced
Start the spec with: # $id (Respecced)"

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
  local _run_orig_args=("$@")   # preserve before any shifting for auto-view re-exec
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
      --auto|-y)        export DEVLOOP_AUTO=1;     shift   ;;
      *)                shift ;;
    esac
  done

  if [[ -z "$feature" ]]; then
    error "Usage: devloop run \"<description>\" [--type TYPE] [--files hints] [--max-retries N] [--auto] [--no-learn] [--no-respec]"
    echo -e "  ${GRAY}Example: devloop run \"add dark mode toggle\"${RESET}"
    echo -e "  ${GRAY}Example: devloop run \"fix login redirect\" --type bug${RESET}"
    echo -e "  ${GRAY}--auto / -y skips plan + diff approval gates${RESET}"
    exit 1
  fi

  load_config
  ensure_dirs
  check_deps
  _maybe_show_version_hint

  # ── Auto-view: re-exec inside tmux immediately (before any pipeline steps) ──
  # This opens the live view in the current terminal without needing a second window.
  if [[ "${DEVLOOP_AUTO_VIEW:-false}" == "true" ]] && _tmux_available && [[ -z "${TMUX:-}" ]]; then
    local _av_name="devloop-$(date +%s)"
    echo -e "${BOLD}🖥  Opening devloop live view${RESET}  ${GRAY}(tmux session: $_av_name)${RESET}"
    echo -e "  ${GRAY}Ctrl-b d  detach  |  click pane or Ctrl-b ←/→  switch  |  Ctrl-b [  scroll${RESET}"
    echo -e "  ${GRAY}In nested tmux: Ctrl-b Ctrl-b ← to switch panes${RESET}"
    echo ""
    sleep 0.3
    # Build the command string for devloop run inside tmux
    local _inner_cmd="env DEVLOOP_AUTO_VIEW=false devloop run"
    for _a in "${_run_orig_args[@]:-}"; do
      _inner_cmd="$_inner_cmd $(printf '%q' "$_a")"
    done
    # Create session detached, enable mouse, then attach
    tmux new-session -d -s "$_av_name" -n "pipeline" bash 2>/dev/null || true
    tmux set-option -t "$_av_name" -g mouse on 2>/dev/null || true
    tmux send-keys -t "$_av_name" "$_inner_cmd" Enter 2>/dev/null || true
    exec tmux attach-session -t "$_av_name"
  fi
  # If already inside tmux, enable mouse for this session (allows pane click-to-focus)
  if [[ -n "${TMUX:-}" ]]; then
    tmux set-option -g mouse on 2>/dev/null || true
  fi

  # Determine fix strategy: escalate (default) or standard
  local fix_strategy="${DEVLOOP_FIX_STRATEGY:-escalate}"
  # deep_threshold: rounds 1..threshold use standard fix; above uses deep fix
  local deep_threshold=$(( (max_retries + 1) / 2 ))

  # ── Status header state tracking ─────────────────────────────────────────────
  local arch_state="" work_state="" review_state="" fix_state=""
  _reset_status_header

  step "🚀 Full pipeline: ${BOLD}\"$feature\"${RESET}"
  echo -e "  ${GRAY}Stages: arch → work → review → [fix loop ×$max_retries max]${RESET}"
  if [[ "$fix_strategy" == "escalate" && "$no_respec" == "false" ]]; then
    echo -e "  ${GRAY}Strategy: standard fix (1-$deep_threshold) → deep fix ($((deep_threshold+1))-$max_retries) → re-architect${RESET}"
  fi
  divider
  echo ""

  # ── Live status pane (inside tmux) ──────────────────────────────────────────
  # Launched NOW (before architect) so user sees it from the very first stage.
  # The pane script dynamically finds the session dir once the architect creates it.
  if [[ -n "${TMUX:-}" && "${DEVLOOP_SESSION_LOGGING:-true}" == "true" ]]; then
    local _specs_path; _specs_path="$SPECS_PATH"
    local _project_root; _project_root="$(find_project_root 2>/dev/null || echo "$PWD")"
    local _sessions_base; _sessions_base="$_project_root/.devloop/sessions"
    local _feature_short; _feature_short="$(echo "$feature" | head -c 50)"
    tmux split-window -h -p 30 -d "bash -c '
BOLD=\"\$(tput bold 2>/dev/null)\"
RESET=\"\$(tput sgr0 2>/dev/null)\"
GREEN=\"\$(tput setaf 2 2>/dev/null)\"
YELLOW=\"\$(tput setaf 3 2>/dev/null)\"
CYAN=\"\$(tput setaf 6 2>/dev/null)\"
GRAY=\"\$(tput setaf 8 2>/dev/null)\"
SBASE=\"$_sessions_base\"
FEATURE=\"$_feature_short\"
spin=\"⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏\"
si=0
while true; do
  clear
  si=\$(( (si+1) % 10 ))
  S=\"\${spin:\$si:1}\"
  echo \"\${BOLD}DevLoop Live View\${RESET}\"
  echo \"\${GRAY}Feature: \${RESET}\${FEATURE}\"
  echo \"\${GRAY}────────────────────────────\${RESET}\"
  # Find newest session dir
  SDIR=\"\$(ls -dt \"\$SBASE\"/TASK-* 2>/dev/null | head -1)\"
  if [[ -z \"\$SDIR\" ]]; then
    echo \"\"
    echo \"  \$S  Waiting for architect...\"
    sleep 1; continue
  fi
  ID=\"\$(basename \"\$SDIR\")\"
  echo \"\${CYAN}Task:\${RESET}  \$ID\"
  echo \"\"
  # Phases
  echo \"\${BOLD}Phases:\${RESET}\"
  for stage in architect worker reviewer fix; do
    SF=\"\$SDIR/\${stage}.state\"
    if [[ -f \"\$SF\" ]]; then
      ST=\"\$(cat \"\$SF\" | head -1)\"
      case \"\$ST\" in
        running) IC=\"\${YELLOW}\$S\${RESET}\" ;;
        done)    IC=\"\${GREEN}✓\${RESET}\" ;;
        failed)  IC=\"✗\" ;;
        *)       IC=\"·\" ;;
      esac
      printf \"  %s  %-12s %s\n\" \"\$IC\" \"\$stage\" \"\$ST\"
    fi
  done
  # Fix round count
  RC=\"\$(ls \"\$SDIR\"/fix-*.state 2>/dev/null | wc -l | tr -d \" \")\"
  [[ \$RC -gt 0 ]] && echo \"\" && echo \"  Fix rounds: \$RC\"
  # Current status
  echo \"\"
  echo \"\${BOLD}Status:\${RESET}\"
  ST=\"\$(cat \"\$SDIR/status\" 2>/dev/null | tail -1 || echo running)\"
  echo \"  \$S  \$ST\"
  # Last 6 lines of session log
  LOGF=\"\$SDIR/pipeline.log\"
  if [[ -f \"\$LOGF\" ]]; then
    echo \"\"
    echo \"\${BOLD}Log:\${RESET}\"
    tail -6 \"\$LOGF\" 2>/dev/null | sed \"s/^/  /\" | cat
  fi
  echo \"\"
  echo \"\${GRAY}[click] or [Ctrl-b ←] focus main  [Ctrl-b d] detach\${RESET}\"
  echo \"\${GRAY}nested tmux? use Ctrl-b Ctrl-b ←\${RESET}\"
  sleep 1
done'" 2>/dev/null || true
  fi

  # ── Stage 1: Architect ───────────────────────────────────────────────────────
  arch_state="running"
  _render_status_header "$arch_state" "$work_state" "$review_state" "$fix_state" "" "$feature"
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

  # ── Session init (now that we have the real task ID) ─────────────────────────
  export DEVLOOP_CURRENT_SESSION_ID="$id"
  _session_init "$id" "$feature"
  _session_phase_end "architect" "done"
  if [[ "${DEVLOOP_SESSION_LOGGING:-true}" == "true" ]]; then
    echo -e "  ${GRAY}Session: ${CYAN}devloop session $id${RESET}"
  fi

  # Register this project in the global registry (updates last_run timestamp)
  _register_project "$(find_project_root)" 2>/dev/null || true

  arch_state="done"
  _render_status_header "$arch_state" "$work_state" "$review_state" "$fix_state" "$id" "$feature"
  success "Spec: ${CYAN}$id${RESET}"
  echo ""

  # ── Gate: Plan approval ──────────────────────────────────────────────────────
  # Pause between architect and worker so the operator can review the spec.
  # Bypass with --auto / DEVLOOP_AUTO=1, or pre-write approvals/plan.json.
  if [[ "${DEVLOOP_PLAN_GATE:-on}" != "off" ]]; then
    local _spec_path="$SPECS_PATH/$id.md"
    local _plan_summary
    _plan_summary="$(_extract_plan_summary "$_spec_path")"
    set +e
    approve_plan "$_plan_summary" "$_spec_path"
    local _plan_rc=$?
    set -e
    case "$_plan_rc" in
      0) success "Plan approved" ;;
      2)
        info "Plan edit requested — opening spec in \$EDITOR..."
        "${EDITOR:-vi}" "$_spec_path" </dev/tty >/dev/tty 2>/dev/tty || true
        info "Spec edited — continuing pipeline."
        ;;
      3)
        _session_finish "timed-out-at-plan"
        warn "⏱  Plan gate timed out — pipeline paused (not rejected)"
        echo -e "  ${GRAY}Task: ${CYAN}$id${RESET}   Resume: ${CYAN}devloop resume $id${RESET}"
        exit 1
        ;;
      *)
        _inbox_write "$(find_project_root)" "blocked" \
          "Pipeline halted at plan-approval gate for task $id." "$id" 2>/dev/null || true
        _session_finish "rejected-at-plan"
        error "❌ Plan rejected at approval gate — pipeline stopped"
        echo -e "  ${GRAY}Task: ${CYAN}$id${RESET}   Edit: ${CYAN}devloop open $id${RESET}"
        echo -e "  ${GRAY}Skip gate: ${CYAN}devloop work $id${RESET}   (goes directly to worker)"
        exit 1
        ;;
    esac
    echo ""
  fi

  # ── Stage 2: Work ────────────────────────────────────────────────────────────
  work_state="running"
  _render_status_header "$arch_state" "$work_state" "$review_state" "$fix_state" "$id" "$feature"
  step "🔨 [2] Implementing..."
  _session_phase_start "worker"
  cmd_work "$id"
  _session_phase_end "worker" "done"
  work_state="done"
  _render_status_header "$arch_state" "$work_state" "$review_state" "$fix_state" "$id" "$feature"
  echo ""

  # ── Gate: Diff approval ──────────────────────────────────────────────────────
  # Pause between worker and reviewer so the operator can review the changes.
  if [[ "${DEVLOOP_DIFF_GATE:-on}" != "off" ]]; then
    local _diff_summary _diff_full
    _diff_summary="$(_extract_diff_summary "$id")"
    _diff_full="$(_capture_worker_diff "$id")"
    if [[ -z "$_diff_summary" ]]; then
      info "No changes detected by worker — skipping diff gate."
    else
      local diff_edit_round=0
      local diff_max_edits="${DEVLOOP_DIFF_MAX_EDITS:-2}"
      while :; do
        set +e
        approve_diff "$_diff_summary" "$_diff_full"
        local _diff_rc=$?
        set -e
        case "$_diff_rc" in
          0)
            success "Diff approved"
            break
            ;;
          2)
            if (( diff_edit_round >= diff_max_edits )); then
              warn "⚠  Diff edit limit reached ($diff_max_edits rounds) — proceeding as-is."
              break
            fi
            diff_edit_round=$(( diff_edit_round + 1 ))

            # Build feedback file pre-populated with the current diff for context
            local _feedback_file
            _feedback_file="$(_session_dir "${DEVLOOP_CURRENT_SESSION_ID:-$id}")/diff-feedback-$diff_edit_round.md"
            _build_diff_feedback_template "$id" "$_diff_full" > "$_feedback_file"

            info "📝 Opening \$EDITOR for diff feedback (round $diff_edit_round/$diff_max_edits)..."
            "${EDITOR:-vi}" "$_feedback_file" </dev/tty >/dev/tty 2>/dev/tty || true

            # If user left the template body unmodified or empty, abort the loop
            if ! _diff_feedback_has_content "$_feedback_file"; then
              warn "No feedback content found in $_feedback_file — skipping fix round."
              break
            fi

            step "🔧 Applying fix from diff feedback (round $diff_edit_round)..."
            _session_phase_start "fix-edit-$diff_edit_round"
            DEVLOOP_FIX_EXTRA_INSTRUCTIONS="$_feedback_file" cmd_fix "$id"
            _session_phase_end "fix-edit-$diff_edit_round" "done"

            # Re-capture for the next gate iteration
            _diff_summary="$(_extract_diff_summary "$id")"
            _diff_full="$(_capture_worker_diff "$id")"
            if [[ -z "$_diff_summary" ]]; then
              info "No further changes after fix — accepting."
              break
            fi
            # Loop back to approve_diff
            ;;
          3)
            _session_finish "timed-out-at-diff"
            warn "⏱  Diff gate timed out — pipeline paused (not rejected)"
            echo -e "  ${GRAY}Task: ${CYAN}$id${RESET}   Resume: ${CYAN}devloop resume $id${RESET}"
            echo -e "  ${GRAY}          or force-approve: ${CYAN}devloop resume $id --approve-diff${RESET}"
            exit 1
            ;;
          *)
            _inbox_write "$(find_project_root)" "blocked" \
              "Pipeline halted at diff-approval gate for task $id." "$id" 2>/dev/null || true
            _session_finish "rejected-at-diff"
            error "❌ Diff rejected at approval gate — pipeline stopped"
            echo -e "  ${GRAY}Task: ${CYAN}$id${RESET}   Inspect: ${CYAN}git diff HEAD${RESET}"
            echo -e "  ${GRAY}Skip gate: ${CYAN}devloop review $id${RESET}   (goes directly to reviewer)"
            exit 1
            ;;
        esac
      done
      echo ""
    fi
  fi

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
      review_state="running"
      _render_status_header "$arch_state" "$work_state" "$review_state" "$fix_state" "$id" "$feature"
      step "🔍 [3] Reviewing..."
      _session_phase_start "reviewer"
    else
      local phase_label="standard"
      (( fix_round > deep_threshold )) && phase_label="deep"
      review_state="running"
      _render_status_header "$arch_state" "$work_state" "$review_state" "$fix_state" "$id" "$feature"
      step "🔍 Re-reviewing (fix $fix_round/$max_retries — $phase_label)..."
      _session_phase_start "reviewer"
    fi

    cmd_review "$id"
    echo ""

    verdict="$(parse_review_verdict "$review_file")"

    case "$verdict" in
      APPROVED)
        _session_phase_end "reviewer" "approved"
        review_state="approved"
        _render_status_header "$arch_state" "$work_state" "$review_state" "$fix_state" "$id" "$feature"
        break
        ;;
      REJECTED)
        _session_phase_end "reviewer" "rejected"
        review_state="rejected"
        _render_status_header "$arch_state" "$work_state" "$review_state" "$fix_state" "$id" "$feature"
        _session_finish "rejected"
        _inbox_write "$(find_project_root)" "blocked" "Pipeline REJECTED for task $id. Reviewer: $(head -5 "$review_file" 2>/dev/null | tr '\n' ' ')" "$id" || true
        error "❌ REJECTED — pipeline stopped"
        echo -e "  ${GRAY}Task: ${CYAN}$id${RESET}"
        echo -e "  ${GRAY}Review: ${CYAN}devloop status $id${RESET}"
        exit 1
        ;;
      NEEDS_WORK)
        _session_phase_end "reviewer" "needs-work"
        review_state="needs-work"
        unknown_round=0
        # Snapshot this review into history
        if [[ -f "$review_file" ]]; then
          fix_history_parts+=("=== Review after fix round $fix_round ===
$(cat "$review_file")
")
        fi

        fix_round=$(( fix_round + 1 ))

        # ── Human checkpoint on last fix round before escalation ──────────────
        if (( fix_round == max_retries )); then
          warn "⚠  Fix round $fix_round/$max_retries — last attempt before re-architect"
          _inbox_write "$(find_project_root)" "needs-work"             "Task $id: fix round $fix_round of $max_retries. If this fails, re-architect phase will start. Check: devloop status $id"             "$id" || true
        fi

        if (( fix_round > max_retries )); then
          # ── Phase 3: Re-architect (escalate strategy only) ──────────────
          if [[ "$fix_strategy" == "escalate" && "$no_respec" == "false" ]]; then
            warn "⚠  Max fix retries ($max_retries) reached — escalating to re-architect phase"
            _session_phase_start "respec"
            echo ""
            local combined_history=""
            local h
            for h in "${fix_history_parts[@]}"; do
              combined_history+="$h"$'\n'
            done
            if _run_respec_phase "$id" "$combined_history"; then
              _session_phase_end "respec" "approved"
              review_state="approved"; fix_state=""
              _render_status_header "$arch_state" "$work_state" "$review_state" "$fix_state" "$id" "$feature"
              verdict="APPROVED"
            else
              _session_phase_end "respec" "needs-work"
              _session_finish "needs-work"
              warn "Re-architect phase also could not get APPROVED"
              echo -e "  ${GRAY}Task needs manual review: ${CYAN}devloop status $id${RESET}"
              echo -e "  ${GRAY}Options:"
              echo -e "    ${CYAN}devloop fix $id${RESET}    — try another fix manually"
              echo -e "    ${CYAN}devloop status $id${RESET} — read full review"
              exit 2
            fi
            break
          else
            _session_finish "needs-work"
            _inbox_write "$(find_project_root)" "needs-work" "Max fix retries ($max_retries) reached for task $id. Manual review needed." "$id" || true
            warn "⚠  Max fix retries ($max_retries) reached — task left as NEEDS_WORK"
            echo -e "  ${GRAY}Continue manually:  ${CYAN}devloop fix $id${RESET}  then  ${CYAN}devloop review $id${RESET}"
            echo -e "  ${GRAY}Tip: ${CYAN}devloop run ... --no-respec${GRAY} disabled re-architect; remove it to enable${RESET}"
            exit 2
          fi
        fi

        # ── Phase 1 or 2: standard vs deep fix ──────────────────────────
        local fix_phase_name="fix-$fix_round"
        fix_state="fix-${fix_round}:running"
        _render_status_header "$arch_state" "$work_state" "$review_state" "$fix_state" "$id" "$feature"
        _session_phase_start "$fix_phase_name"
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
          # ── Issue-delta: flag issues persisting from previous round ──────────
          if [[ ${#fix_history_parts[@]} -ge 2 ]]; then
            local prev_tmp; prev_tmp="$(mktemp /tmp/devloop-prev-XXXXXX)"
            local prev_idx=$(( ${#fix_history_parts[@]} - 2 ))
            printf '%s' "${fix_history_parts[$prev_idx]}" > "$prev_tmp"
            local prev_count; prev_count="$(_parse_issues_table "$prev_tmp" | grep -c '[^[:space:]]' 2>/dev/null || echo 0)"
            rm -f "$prev_tmp"
            local curr_count; curr_count="$(_parse_issues_table "$review_file" | grep -c '[^[:space:]]' 2>/dev/null || echo 0)"
            combined_history+="
PERSISTING CONTEXT: Previous fix round had $prev_count tracked issues; this round has $curr_count. Focus specifically on the issues that were NOT resolved from the previous attempt."
          fi
          cmd_fix --history "$combined_history" "$id"
        fi
        _session_phase_end "$fix_phase_name" "done"
        fix_state="fix-${fix_round}:done"
        review_state=""
        _render_status_header "$arch_state" "$work_state" "$review_state" "$fix_state" "$id" "$feature"
        echo ""
        ;;
      *)
        _session_phase_end "reviewer" "unknown"
        unknown_round=$(( unknown_round + 1 ))
        warn "Could not determine verdict from review output: $review_file"
        echo -e "  ${GRAY}Expected first non-empty line:${RESET} ${CYAN}Verdict: APPROVED|NEEDS_WORK|REJECTED${RESET}"
        if (( unknown_round >= max_unknown_retries )); then
          _session_finish "error"
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

  _session_finish "approved"
  divider
  success "✅ Pipeline complete: ${CYAN}$id${RESET}"
  if (( fix_round > 0 )); then
    echo -e "  ${GRAY}Approved after $fix_round fix round(s)${RESET}"
  fi
  if [[ "${DEVLOOP_SESSION_LOGGING:-true}" == "true" ]]; then
    echo -e "  ${GRAY}Session history: ${CYAN}devloop session $id${RESET}"
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

# ── cmd: resume — resume an interrupted pipeline from last completed phase ────

# _compute_resume_from <session_dir>
# Pure function — no side effects, no I/O beyond reading the events file.
# Returns the next phase name to execute (or "complete" if already finished).
# Stage ordering: architect → worker → reviewer → fix-N loop
_compute_resume_from() {
  local sdir="${1:-}"
  local events_file="$sdir/events.ndjson"

  # Missing events file → start from scratch after architect
  if [[ ! -f "$events_file" ]]; then
    echo "worker"
    return 0
  fi

  # Find the last phase.end event
  local last_phase_end_line
  last_phase_end_line="$(grep '"kind":"phase.end"' "$events_file" 2>/dev/null | tail -1 || true)"

  if [[ -z "$last_phase_end_line" ]]; then
    # No phase.end found at all — resume from architect (re-run worker)
    echo "worker"
    return 0
  fi

  # Extract phase and status from JSON (jq preferred; sed fallback)
  local phase status
  if command -v jq >/dev/null 2>&1; then
    phase="$(printf '%s' "$last_phase_end_line"  | jq -r '.phase  // empty' 2>/dev/null || true)"
    status="$(printf '%s' "$last_phase_end_line" | jq -r '.status // empty' 2>/dev/null || true)"
  else
    phase="$(printf '%s'  "$last_phase_end_line" | sed 's/.*"phase":"\([^"]*\)".*/\1/' 2>/dev/null || true)"
    status="$(printf '%s' "$last_phase_end_line" | sed 's/.*"status":"\([^"]*\)".*/\1/' 2>/dev/null || true)"
  fi

  case "$phase" in
    architect)
      echo "worker"
      ;;
    worker)
      echo "reviewer"
      ;;
    reviewer)
      case "$status" in
        approved)   echo "complete" ;;
        rejected)   echo "complete" ;;
        needs-work) echo "fix" ;;
        *)          echo "reviewer" ;;
      esac
      ;;
    fix-*)
      # After any fix-N, we re-review
      echo "reviewer"
      ;;
    respec)
      echo "complete"
      ;;
    *)
      # Unknown last phase — safe fallback is re-run reviewer
      echo "reviewer"
      ;;
  esac
}

cmd_resume() {
  local dry_run=false
  local do_list=false
  local target_id=""
  local do_approve_diff=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        echo -e "Usage: ${BOLD}devloop resume${RESET} [TASK-ID] [--dry-run] [--list] [--approve-diff]"
        echo ""
        echo -e "  ${CYAN}devloop resume${RESET}                          Resume the newest unfinished session"
        echo -e "  ${CYAN}devloop resume TASK-ID${RESET}                  Resume the specified session"
        echo -e "  ${CYAN}devloop resume --dry-run${RESET}                Print would-resume info without executing"
        echo -e "  ${CYAN}devloop resume --list${RESET}                   List resumable sessions and exit"
        echo -e "  ${CYAN}devloop resume [TASK-ID] --approve-diff${RESET}  Force-approve the diff gate and continue to review"
        echo ""
        echo -e "  Resumable statuses: ${GRAY}running, needs-work, timed-out-at-plan, timed-out-at-diff, rejected-at-plan, rejected-at-diff, (absent)${RESET}"
        echo -e "  Skips sessions already ${GRAY}approved${RESET} or ${GRAY}rejected${RESET} (reviewer-rejected, no retries left)."
        exit 0
        ;;
      --dry-run)      dry_run=true;          shift ;;
      --list)         do_list=true;          shift ;;
      --approve-diff) do_approve_diff=true;  shift ;;
      TASK-*)         target_id="$1";        shift ;;
      *)              shift ;;
    esac
  done

  load_config
  ensure_dirs

  local root; root="$(find_project_root 2>/dev/null || pwd)"
  local sessions_base="$root/$DEVLOOP_DIR/sessions"

  # ── --list mode ─────────────────────────────────────────────────────────────
  if [[ "$do_list" == "true" ]]; then
    local found=0
    local sdir sname sstatus sfeature
    while IFS= read -r sdir; do
      [[ -d "$sdir" ]] || continue
      sname="$(basename "$sdir")"
      sstatus="$(cat "$sdir/status" 2>/dev/null || echo "running")"
      case "$sstatus" in
        approved|rejected) continue ;;
      esac
      sfeature="$(cat "$sdir/feature.txt" 2>/dev/null | head -1 | head -c 60 || echo "(no feature)")"
      printf '%-32s  %-14s  %s\n' "$sname" "$sstatus" "$sfeature"
      found=$(( found + 1 ))
    done < <(ls -dt "$sessions_base"/TASK-* 2>/dev/null || true)
    if [[ "$found" -eq 0 ]]; then
      info "No resumable sessions found."
    fi
    exit 0
  fi

  # ── Resolve target session ────────────────────────────────────────────────
  local id=""
  if [[ -n "$target_id" ]]; then
    id="$target_id"
  else
    # Find the newest session that is not already finished
    local sdir sname sstatus
    while IFS= read -r sdir; do
      [[ -d "$sdir" ]] || continue
      sname="$(basename "$sdir")"
      sstatus="$(cat "$sdir/status" 2>/dev/null || echo "running")"
      case "$sstatus" in
        approved|rejected) continue ;;
      esac
      id="$sname"
      break
    done < <(ls -dt "$sessions_base"/TASK-* 2>/dev/null || true)
  fi

  if [[ -z "$id" ]]; then
    error "No resumable session found."
    echo -e "  ${GRAY}Use ${CYAN}devloop resume --list${GRAY} to see available sessions.${RESET}"
    exit 1
  fi

  # ── Validate session ──────────────────────────────────────────────────────
  local session_dir="$sessions_base/$id"
  if [[ ! -d "$session_dir" ]]; then
    error "Session directory not found: $session_dir"
    exit 1
  fi

  # Check if already complete (reviewer-rejected with no retries = truly terminal)
  local cur_status; cur_status="$(cat "$session_dir/status" 2>/dev/null || echo "running")"
  case "$cur_status" in
    approved|rejected)
      info "Session $id already finished with status: $cur_status — nothing to resume."
      exit 0
      ;;
  esac

  # Validate spec file exists
  local spec_file="$SPECS_PATH/$id.md"
  if [[ ! -f "$spec_file" ]]; then
    error "Spec file not found: $spec_file"
    echo -e "  ${GRAY}Cannot resume without the spec. Check: ${CYAN}$SPECS_PATH/${RESET}"
    exit 1
  fi

  # ── Compute resume point ──────────────────────────────────────────────────
  local next_phase
  next_phase="$(_compute_resume_from "$session_dir")"

  # If the session timed out or was rejected at the diff gate, the worker already completed.
  # Override next_phase so we re-present only the diff gate, not re-run the worker.
  if [[ "$cur_status" == "timed-out-at-diff" || "$cur_status" == "rejected-at-diff" ]] && \
     [[ "$next_phase" == "reviewer" ]]; then
    next_phase="diff-gate"
  fi

  # If the session was rejected at the plan gate, we want to re-present the plan gate.
  # _compute_resume_from returns "worker" since architect finished but worker hasn't run,
  # which causes plan gate to be shown first — correct behavior, no override needed.
  # But add an informational hint when status is rejected-at-plan:
  if [[ "$cur_status" == "rejected-at-plan" ]]; then
    info "Session was previously rejected at the plan gate — re-presenting plan for approval."
  fi

  if [[ -z "$next_phase" || "$next_phase" == "complete" ]]; then
    # Events say approved/complete — close out cleanly
    export DEVLOOP_CURRENT_SESSION_ID="$id"
    if [[ "$dry_run" == "false" ]]; then
      _session_finish "approved"
    fi
    info "Session $id already reached a terminal state — marking approved."
    exit 0
  fi

  # ── --dry-run mode ────────────────────────────────────────────────────────
  if [[ "$dry_run" == "true" ]]; then
    echo "Would resume $id from architect → next phase: $next_phase"
    exit 0
  fi

  # ── Set up env and emit session.resume event ──────────────────────────────
  export DEVLOOP_CURRENT_SESSION_ID="$id"

  # Determine the "from_phase" (last completed) by re-reading last phase.end
  local from_phase="(none)"
  if [[ -f "$session_dir/events.ndjson" ]]; then
    local _lpe
    _lpe="$(grep '"kind":"phase.end"' "$session_dir/events.ndjson" 2>/dev/null | tail -1 || true)"
    if [[ -n "$_lpe" ]]; then
      if command -v jq >/dev/null 2>&1; then
        from_phase="$(printf '%s' "$_lpe" | jq -r '.phase // empty' 2>/dev/null || true)"
      else
        from_phase="$(printf '%s' "$_lpe" | sed 's/.*"phase":"\([^"]*\)".*/\1/' 2>/dev/null || true)"
      fi
    fi
  fi

  emit_event "session.resume" from_phase="$from_phase" next_phase="$next_phase"

  local feature; feature="$(cat "$session_dir/feature.txt" 2>/dev/null | head -1 || echo "(unknown)")"
  step "▶ Resuming ${BOLD}$id${RESET}"
  echo -e "  ${GRAY}Feature:  ${RESET}$feature"
  echo -e "  ${GRAY}From:     ${RESET}$from_phase"
  echo -e "  ${GRAY}Next:     ${CYAN}$next_phase${RESET}"
  echo ""

  # ── Pipeline parameters (mirror cmd_run defaults) ─────────────────────────
  local max_retries=3
  local fix_strategy="${DEVLOOP_FIX_STRATEGY:-escalate}"
  local deep_threshold=$(( (max_retries + 1) / 2 ))
  local review_file="$SPECS_PATH/$id-review.md"
  local fix_history_parts=()

  # Count how many fix rounds have already completed (for correct numbering)
  local existing_fix_rounds=0
  if [[ -f "$session_dir/events.ndjson" ]]; then
    existing_fix_rounds="$(grep '"kind":"phase.end"' "$session_dir/events.ndjson" 2>/dev/null \
      | grep '"phase":"fix-' | wc -l | tr -d ' ' || echo 0)"
  fi
  local fix_round="$existing_fix_rounds"

  # ── Status header: initialise from existing events then render once ────────
  local arch_state="" work_state="" review_state="" fix_state=""
  _reset_status_header
  eval "$(_read_session_states "$session_dir")"
  _render_status_header "$arch_state" "$work_state" "$review_state" "$fix_state" "$id" "$feature"

  # ── Execute pipeline tail ─────────────────────────────────────────────────

  # Worker stage (if needed)
  if [[ "$next_phase" == "worker" ]]; then
    # Run plan gate if configured
    if [[ "${DEVLOOP_PLAN_GATE:-on}" != "off" ]]; then
      local _spec_path="$SPECS_PATH/$id.md"
      local _plan_summary; _plan_summary="$(_extract_plan_summary "$_spec_path")"
      set +e
      approve_plan "$_plan_summary" "$_spec_path"
      local _plan_rc=$?
      set -e
      case "$_plan_rc" in
        0) success "Plan approved" ;;
        2)
          info "Plan edit requested — opening spec in \$EDITOR..."
          "${EDITOR:-vi}" "$_spec_path" </dev/tty >/dev/tty 2>/dev/tty || true
          info "Spec edited — continuing."
          ;;
        3)
          _session_finish "timed-out-at-plan"
          warn "⏱  Plan gate timed out — pipeline paused (not rejected)"
          echo -e "  ${GRAY}Task: ${CYAN}$id${RESET}   Resume: ${CYAN}devloop resume $id${RESET}"
          exit 1
          ;;
        *)
          _session_finish "rejected-at-plan"
          error "Plan rejected — pipeline stopped"
          echo -e "  ${GRAY}Skip gate: ${CYAN}devloop work $id${RESET}   (goes directly to worker)"
          exit 1
          ;;
      esac
      echo ""
    fi

    work_state="running"
    _render_status_header "$arch_state" "$work_state" "$review_state" "$fix_state" "$id" "$feature"
    step "🔨 Implementing..."
    _session_phase_start "worker"
    cmd_work "$id"
    _session_phase_end "worker" "done"
    work_state="done"
    _render_status_header "$arch_state" "$work_state" "$review_state" "$fix_state" "$id" "$feature"
    echo ""
    next_phase="reviewer"

    # Diff gate
    if [[ "${DEVLOOP_DIFF_GATE:-on}" != "off" ]]; then
      local _diff_summary _diff_full
      _diff_summary="$(_extract_diff_summary "$id")"
      _diff_full="$(_capture_worker_diff "$id")"
      if [[ -n "$_diff_summary" ]]; then
        local diff_edit_round=0
        local diff_max_edits="${DEVLOOP_DIFF_MAX_EDITS:-2}"
        while :; do
          set +e; approve_diff "$_diff_summary" "$_diff_full"; local _diff_rc=$?; set -e
          case "$_diff_rc" in
            0) success "Diff approved"; break ;;
            2)
              if (( diff_edit_round >= diff_max_edits )); then
                warn "Diff edit limit reached — proceeding."
                break
              fi
              diff_edit_round=$(( diff_edit_round + 1 ))
              local _feedback_file="$session_dir/diff-feedback-$diff_edit_round.md"
              _build_diff_feedback_template "$id" "$_diff_full" > "$_feedback_file"
              "${EDITOR:-vi}" "$_feedback_file" </dev/tty >/dev/tty 2>/dev/tty || true
              if ! _diff_feedback_has_content "$_feedback_file"; then
                warn "No feedback content — skipping fix round."; break
              fi
              _session_phase_start "fix-edit-$diff_edit_round"
              DEVLOOP_FIX_EXTRA_INSTRUCTIONS="$_feedback_file" cmd_fix "$id"
              _session_phase_end "fix-edit-$diff_edit_round" "done"
              _diff_summary="$(_extract_diff_summary "$id")"
              _diff_full="$(_capture_worker_diff "$id")"
              [[ -z "$_diff_summary" ]] && { info "No further changes — accepting."; break; }
              ;;
            3)
              _session_finish "timed-out-at-diff"
              warn "⏱  Diff gate timed out — pipeline paused (not rejected)"
              echo -e "  ${GRAY}Task: ${CYAN}$id${RESET}   Resume: ${CYAN}devloop resume $id${RESET}"
              echo -e "  ${GRAY}          or force-approve: ${CYAN}devloop resume $id --approve-diff${RESET}"
              exit 1 ;;
            *)
              _session_finish "rejected-at-diff"
              error "Diff rejected — pipeline stopped"
              echo -e "  ${GRAY}Skip gate: ${CYAN}devloop review $id${RESET}   (goes directly to reviewer)"
              exit 1 ;;
          esac
        done
        echo ""
      fi
    fi
  fi

  # Diff-gate stage only (timed-out-at-diff: worker already ran, re-present gate)
  if [[ "$next_phase" == "diff-gate" ]]; then
    if [[ "$do_approve_diff" == "true" ]]; then
      success "Diff auto-approved via --approve-diff"
    elif [[ "${DEVLOOP_DIFF_GATE:-on}" != "off" ]]; then
      local _diff_summary _diff_full
      _diff_summary="$(_extract_diff_summary "$id")"
      _diff_full="$(_capture_worker_diff "$id")"
      if [[ -n "$_diff_summary" ]]; then
        local diff_edit_round=0
        local diff_max_edits="${DEVLOOP_DIFF_MAX_EDITS:-2}"
        while :; do
          set +e; approve_diff "$_diff_summary" "$_diff_full"; local _diff_rc=$?; set -e
          case "$_diff_rc" in
            0) success "Diff approved"; break ;;
            2)
              if (( diff_edit_round >= diff_max_edits )); then
                warn "Diff edit limit reached — proceeding."
                break
              fi
              diff_edit_round=$(( diff_edit_round + 1 ))
              local _feedback_file="$session_dir/diff-feedback-$diff_edit_round.md"
              _build_diff_feedback_template "$id" "$_diff_full" > "$_feedback_file"
              "${EDITOR:-vi}" "$_feedback_file" </dev/tty >/dev/tty 2>/dev/tty || true
              if ! _diff_feedback_has_content "$_feedback_file"; then
                warn "No feedback content — skipping fix round."; break
              fi
              _session_phase_start "fix-edit-$diff_edit_round"
              DEVLOOP_FIX_EXTRA_INSTRUCTIONS="$_feedback_file" cmd_fix "$id"
              _session_phase_end "fix-edit-$diff_edit_round" "done"
              _diff_summary="$(_extract_diff_summary "$id")"
              _diff_full="$(_capture_worker_diff "$id")"
              [[ -z "$_diff_summary" ]] && { info "No further changes — accepting."; break; }
              ;;
            3)
              _session_finish "timed-out-at-diff"
              warn "⏱  Diff gate timed out — pipeline paused (not rejected)"
              echo -e "  ${GRAY}Task: ${CYAN}$id${RESET}   Resume: ${CYAN}devloop resume $id${RESET}"
              echo -e "  ${GRAY}          or force-approve: ${CYAN}devloop resume $id --approve-diff${RESET}"
              exit 1 ;;
            *)
              _session_finish "rejected-at-diff"
              error "Diff rejected — pipeline stopped"; exit 1 ;;
          esac
        done
        echo ""
      else
        info "No changes detected — diff gate skipped."
      fi
    fi
    next_phase="reviewer"
  fi

  # Reviewer + fix loop
  local verdict="NEEDS_WORK"
  local unknown_round=0
  local max_unknown_retries=2

  # If next_phase is "fix", we need to run a fix first then reviewer
  local start_with_fix=false
  [[ "$next_phase" == "fix" ]] && start_with_fix=true

  if [[ "$start_with_fix" == "true" ]]; then
    # We're resuming into a fix round
    fix_round=$(( fix_round + 1 ))
    local fix_phase_name="fix-$fix_round"
    fix_state="fix-${fix_round}:running"
    _render_status_header "$arch_state" "$work_state" "$review_state" "$fix_state" "$id" "$feature"
    step "🔧 Fixing (attempt $fix_round — resume)..."
    _session_phase_start "$fix_phase_name"
    cmd_fix "$id"
    _session_phase_end "$fix_phase_name" "done"
    fix_state="fix-${fix_round}:done"
    review_state=""
    _render_status_header "$arch_state" "$work_state" "$review_state" "$fix_state" "$id" "$feature"
    echo ""
    verdict="NEEDS_WORK"
  elif [[ "$next_phase" == "reviewer" ]]; then
    # Start with reviewer (verdict loop handles it below)
    true
  else
    # next_phase == "worker" is handled above; anything else falls to reviewer
    true
  fi

  # Reviewer / fix loop
  while [[ "$verdict" != "APPROVED" && "$verdict" != "REJECTED" ]]; do
    review_state="running"
    _render_status_header "$arch_state" "$work_state" "$review_state" "$fix_state" "$id" "$feature"
    if (( fix_round == 0 )); then
      step "🔍 Reviewing..."
    else
      step "🔍 Re-reviewing (fix $fix_round/$max_retries)..."
    fi
    _session_phase_start "reviewer"
    cmd_review "$id"
    echo ""
    verdict="$(parse_review_verdict "$review_file")"

    case "$verdict" in
      APPROVED)
        _session_phase_end "reviewer" "approved"
        review_state="approved"
        _render_status_header "$arch_state" "$work_state" "$review_state" "$fix_state" "$id" "$feature"
        break
        ;;
      REJECTED)
        _session_phase_end "reviewer" "rejected"
        review_state="rejected"
        _render_status_header "$arch_state" "$work_state" "$review_state" "$fix_state" "$id" "$feature"
        _session_finish "rejected"
        error "REJECTED — pipeline stopped"
        echo -e "  ${GRAY}Task: ${CYAN}$id${RESET}   Review: ${CYAN}devloop status $id${RESET}"
        exit 1
        ;;
      NEEDS_WORK)
        _session_phase_end "reviewer" "needs-work"
        review_state="needs-work"
        unknown_round=0
        if [[ -f "$review_file" ]]; then
          fix_history_parts+=("=== Review after fix round $fix_round ===$(printf '\n')$(cat "$review_file")")
        fi
        fix_round=$(( fix_round + 1 ))
        if (( fix_round > max_retries )); then
          if [[ "$fix_strategy" == "escalate" ]]; then
            warn "Max fix retries reached — task left as NEEDS_WORK"
          fi
          _session_finish "needs-work"
          warn "Max fix retries ($max_retries) reached"
          echo -e "  ${GRAY}Continue: ${CYAN}devloop fix $id${RESET}  then  ${CYAN}devloop review $id${RESET}"
          exit 2
        fi
        local fix_phase_name="fix-$fix_round"
        fix_state="fix-${fix_round}:running"
        _render_status_header "$arch_state" "$work_state" "$review_state" "$fix_state" "$id" "$feature"
        _session_phase_start "$fix_phase_name"
        if (( fix_round <= deep_threshold )); then
          step "🔧 Fixing (attempt $fix_round/$max_retries — standard)..."
          cmd_fix "$id"
        else
          step "🔧 Fixing (attempt $fix_round/$max_retries — deep)..."
          local combined_history=""; local h
          for h in "${fix_history_parts[@]}"; do combined_history+="$h"$'\n'; done
          cmd_fix --history "$combined_history" "$id"
        fi
        _session_phase_end "$fix_phase_name" "done"
        fix_state="fix-${fix_round}:done"
        review_state=""
        _render_status_header "$arch_state" "$work_state" "$review_state" "$fix_state" "$id" "$feature"
        echo ""
        ;;
      *)
        _session_phase_end "reviewer" "unknown"
        unknown_round=$(( unknown_round + 1 ))
        warn "Could not determine verdict from review output."
        if (( unknown_round >= max_unknown_retries )); then
          _session_finish "error"
          error "Unknown verdict repeated — stopping."
          exit 2
        fi
        ;;
    esac
  done

  _session_finish "approved"
  divider
  success "Pipeline complete: ${CYAN}$id${RESET}"
  if (( fix_round > 0 )); then
    echo -e "  ${GRAY}Approved after $fix_round fix round(s)${RESET}"
  fi
  echo ""
}

# ── cmd: permissions — interactive allow/deny editor ─────────────────────────

cmd_permissions() {
  local PERMISSIONS_YAML
  PERMISSIONS_YAML="$(find_project_root 2>/dev/null || pwd)/.devloop/permissions.yaml"

  # ── Internal helpers ────────────────────────────────────────────────────────

  _perms_ensure_yaml() {
    if [[ ! -f "$PERMISSIONS_YAML" ]]; then
      mkdir -p "$(dirname "$PERMISSIONS_YAML")"
      cat > "$PERMISSIONS_YAML" <<'YAML'
# DevLoop persistent permission policy
# See: docs in .claude/hooks/devloop-permission.sh

deny: []

allow: []
YAML
    fi
  }

  _perms_list() {
    # _perms_list <key>  -> prints each entry on its own line
    local key="$1"
    [[ -f "$PERMISSIONS_YAML" ]] || return 0
    awk -v key="$key" '
      BEGIN { in_section=0 }
      /^[^[:space:]#]/ {
        if ($0 ~ "^"key":[[:space:]]*(\\[\\])?[[:space:]]*$") { in_section=1; next }
        in_section=0
      }
      in_section && /^[[:space:]]*-/ {
        line=$0
        sub(/^[[:space:]]*-[[:space:]]*/, "", line)
        sub(/^"/, "", line); sub(/"$/, "", line)
        sub(/^'\''/, "", line); sub(/'\''$/, "", line)
        print line
      }
    ' "$PERMISSIONS_YAML"
  }

  _perms_append() {
    # _perms_append <key> <pattern>   atomic add
    local key="$1"; local pattern="$2"
    _perms_ensure_yaml
    python3 - "$PERMISSIONS_YAML" "$key" "$pattern" <<'PY'
import sys, re, pathlib
path, key, pattern = sys.argv[1], sys.argv[2], sys.argv[3]
text = pathlib.Path(path).read_text()
# Convert `key: []` (possibly with trailing comment / spaces) to `key:` block form.
text = re.sub(rf'^({re.escape(key)}):\s*\[\]\s*$', rf'\1:', text, count=1, flags=re.MULTILINE)
# If the key block doesn't exist, append it at the end.
if not re.search(rf'^{re.escape(key)}:\s*$', text, flags=re.MULTILINE):
    text = text.rstrip() + f'\n\n{key}:\n'
# Append the new entry after the key header (and any existing entries / comments
# that belong to this section before the next top-level key).
lines = text.splitlines(keepends=True)
out = []
i = 0
inserted = False
while i < len(lines):
    line_str = lines[i]
    # Ensure the key header line ends with a newline (it may not if it's the last line)
    if not line_str.endswith('\n'):
        line_str += '\n'
    out.append(line_str)
    if not inserted and re.match(rf'^{re.escape(key)}:\s*$', lines[i].rstrip('\n')):
        # Find end of this section.
        j = i + 1
        while j < len(lines):
            ln = lines[j]
            # New top-level key (no leading whitespace, ends with :)
            if re.match(r'^[A-Za-z_][\w-]*:', ln):
                break
            out.append(ln)
            j += 1
        # Insert before whatever comes after the section.
        out.append(f'  - "{pattern}"\n')
        i = j
        inserted = True
        continue
    i += 1
pathlib.Path(path).write_text(''.join(out))
PY
  }

  _perms_remove() {
    # _perms_remove <key> <pattern>   removes one exact-match line under key
    local key="$1"; local pattern="$2"
    python3 - "$PERMISSIONS_YAML" "$key" "$pattern" <<'PY'
import sys, re, pathlib
path, key, pattern = sys.argv[1], sys.argv[2], sys.argv[3]
text = pathlib.Path(path).read_text()
lines = text.splitlines(keepends=True)
in_section = False
out = []
for ln in lines:
    if re.match(rf'^{re.escape(key)}:\s*$', ln):
        in_section = True
        out.append(ln); continue
    if in_section and re.match(r'^[A-Za-z_][\w-]*:', ln):
        in_section = False
    if in_section:
        m = re.match(r'^\s*-\s*"?([^"]*)"?\s*$', ln)
        if m and m.group(1).strip() == pattern.strip():
            continue  # drop this line
    out.append(ln)
pathlib.Path(path).write_text(''.join(out))
PY
  }

  _perms_validate() {
    # Quick round-trip check — mirrors hook's _yaml_extract_list logic.
    # Returns 0 if both keys parse without error.
    _perms_list allow >/dev/null 2>&1 && _perms_list deny >/dev/null 2>&1
  }

  _perms_print_lists() {
    echo -e "\n${BOLD}allow:${RESET}"
    local idx=1 pat
    while IFS= read -r pat; do
      echo -e "  ${GREEN}$idx)${RESET} $pat"
      idx=$((idx+1))
    done < <(_perms_list allow)
    [[ $idx -eq 1 ]] && echo -e "  ${GRAY}(empty)${RESET}"

    echo -e "\n${BOLD}deny:${RESET}"
    idx=1
    while IFS= read -r pat; do
      echo -e "  ${RED}$idx)${RESET} $pat"
      idx=$((idx+1))
    done < <(_perms_list deny)
    [[ $idx -eq 1 ]] && echo -e "  ${GRAY}(empty)${RESET}"
    echo ""
  }

  _perms_pick_from_list() {
    # _perms_pick_from_list <key>  → prints chosen pattern or empty string
    local key="$1"
    local -a entries=()
    local pat
    while IFS= read -r pat; do
      entries+=("$pat")
    done < <(_perms_list "$key")

    if [[ ${#entries[@]} -eq 0 ]]; then
      warn "No entries in $key list."
      return 1
    fi

    if command -v gum &>/dev/null; then
      gum choose "${entries[@]}"
    else
      local i=1
      for pat in "${entries[@]}"; do
        echo "  $i) $pat"
        i=$((i+1))
      done
      printf "  Enter number [1]: "
      local _n=""
      read -r _n 2>/dev/null </dev/tty || _n=""
      _n="${_n:-1}"
      if [[ "$_n" =~ ^[0-9]+$ ]] && (( _n >= 1 && _n <= ${#entries[@]} )); then
        echo "${entries[$((_n-1))]}"
      else
        warn "Invalid selection."
        return 1
      fi
    fi
  }

  _perms_prompt_pattern() {
    # _perms_prompt_pattern <prompt-label>  → prints entered pattern
    local label="$1"
    if command -v gum &>/dev/null; then
      gum input --prompt "  $label: " --placeholder "e.g. make *"
    else
      printf "  %s: " "$label"
      local _pat=""
      read -r _pat 2>/dev/null </dev/tty || _pat=""
      echo "$_pat"
    fi
  }

  _perms_confirm() {
    # _perms_confirm <question>  → returns 0 if yes
    local question="$1"
    if command -v gum &>/dev/null; then
      gum confirm "$question"
    else
      printf "  %s [y/N]: " "$question"
      local _ans=""
      read -r _ans 2>/dev/null </dev/tty || _ans=""
      [[ "${_ans,,}" == "y" || "${_ans,,}" == "yes" ]]
    fi
  }

  # ── Subcommand dispatch ─────────────────────────────────────────────────────

  local subcmd="${1:-}"

  case "$subcmd" in
    --help|-h)
      echo -e "${BOLD}devloop permissions${RESET} — manage .devloop/permissions.yaml"
      echo ""
      echo -e "  ${CYAN}devloop permissions${RESET}              interactive menu"
      echo -e "  ${CYAN}devloop permissions list${RESET}         print allow + deny lists"
      echo -e "  ${CYAN}devloop permissions allow <pat>${RESET}  append pattern to allow list"
      echo -e "  ${CYAN}devloop permissions deny  <pat>${RESET}  append pattern to deny list"
      echo -e "  ${CYAN}devloop permissions remove allow|deny <pat>${RESET}  remove a pattern"
      echo -e "  ${CYAN}devloop permissions edit${RESET}         open in \$EDITOR"
      echo ""
      echo -e "  Patterns use shell-style globs (* = wildcard)."
      echo -e "  File: ${GRAY}$PERMISSIONS_YAML${RESET}"
      return 0
      ;;

    list)
      _perms_ensure_yaml
      step "Permissions — ${GRAY}$PERMISSIONS_YAML${RESET}"
      divider
      _perms_print_lists
      return 0
      ;;

    allow|deny)
      local key="$subcmd"
      local pattern="${2:-}"
      if [[ -z "$pattern" ]]; then
        error "Usage: devloop permissions $key <pattern>"
        return 1
      fi
      _perms_ensure_yaml
      if _perms_append "$key" "$pattern"; then
        success "Added to ${key}: $pattern"
      else
        error "Failed to update $PERMISSIONS_YAML"
        return 1
      fi
      return 0
      ;;

    remove)
      local key="${2:-}"
      local pattern="${3:-}"
      if [[ -z "$key" || -z "$pattern" ]]; then
        error "Usage: devloop permissions remove allow|deny <pattern>"
        return 1
      fi
      if [[ "$key" != "allow" && "$key" != "deny" ]]; then
        error "Key must be 'allow' or 'deny', got: $key"
        return 1
      fi
      if [[ ! -f "$PERMISSIONS_YAML" ]]; then
        error "No permissions.yaml found: $PERMISSIONS_YAML"
        return 1
      fi
      if _perms_remove "$key" "$pattern"; then
        success "Removed from ${key}: $pattern"
      else
        error "Failed to update $PERMISSIONS_YAML"
        return 1
      fi
      return 0
      ;;

    edit)
      _perms_ensure_yaml
      local editor="${EDITOR:-}"
      [[ -z "$editor" ]] && command -v nano &>/dev/null && editor="nano"
      [[ -z "$editor" ]] && command -v vi   &>/dev/null && editor="vi"
      if [[ -z "$editor" ]]; then
        error "No editor found. Set \$EDITOR or edit manually: $PERMISSIONS_YAML"
        return 1
      fi
      "$editor" "$PERMISSIONS_YAML"
      # Validate after edit
      if ! _perms_validate; then
        warn "YAML validation warning — check $PERMISSIONS_YAML for syntax issues"
      else
        success "Permissions file saved: $PERMISSIONS_YAML"
      fi
      return 0
      ;;

    "")
      # ── Interactive menu ────────────────────────────────────────────────────
      _perms_ensure_yaml
      step "DevLoop Permissions Editor"
      divider
      info "File: ${GRAY}$PERMISSIONS_YAML${RESET}"
      echo ""

      local _menu_items=(
        "view current rules"
        "add allow pattern"
        "add deny pattern"
        "remove allow pattern"
        "remove deny pattern"
        "open in \$EDITOR"
        "quit"
      )

      while true; do
        local _choice
        if command -v gum &>/dev/null; then
          _choice="$(gum choose "${_menu_items[@]}" 2>/dev/null)" || _choice="quit"
        else
          echo -e "${BOLD}Actions:${RESET}"
          local _i=1
          local _item
          for _item in "${_menu_items[@]}"; do
            echo -e "  ${CYAN}$_i)${RESET} $_item"
            _i=$((_i+1))
          done
          echo ""
          printf "  Choose [1-%d]: " "${#_menu_items[@]}"
          local _n=""
          read -r _n 2>/dev/null </dev/tty || _n=""
          _n="${_n:-7}"
          if [[ "$_n" =~ ^[0-9]+$ ]] && (( _n >= 1 && _n <= ${#_menu_items[@]} )); then
            _choice="${_menu_items[$((_n-1))]}"
          else
            _choice="quit"
          fi
        fi

        case "$_choice" in
          "view current rules")
            _perms_print_lists
            ;;

          "add allow pattern")
            local _pat
            _pat="$(_perms_prompt_pattern "Allow pattern (glob)")"
            if [[ -n "$_pat" ]]; then
              if _perms_confirm "Add to allow: $_pat"; then
                if _perms_append "allow" "$_pat"; then
                  success "Added to allow: $_pat"
                else
                  error "Failed to update permissions file"
                fi
              else
                info "Cancelled."
              fi
            fi
            ;;

          "add deny pattern")
            local _pat
            _pat="$(_perms_prompt_pattern "Deny pattern (glob)")"
            if [[ -n "$_pat" ]]; then
              if _perms_confirm "Add to deny: $_pat"; then
                if _perms_append "deny" "$_pat"; then
                  success "Added to deny: $_pat"
                else
                  error "Failed to update permissions file"
                fi
              else
                info "Cancelled."
              fi
            fi
            ;;

          "remove allow pattern")
            local _picked
            if _picked="$(_perms_pick_from_list allow)" && [[ -n "$_picked" ]]; then
              if _perms_confirm "Remove from allow: $_picked"; then
                if _perms_remove "allow" "$_picked"; then
                  success "Removed from allow: $_picked"
                else
                  error "Failed to update permissions file"
                fi
              else
                info "Cancelled."
              fi
            fi
            ;;

          "remove deny pattern")
            local _picked
            if _picked="$(_perms_pick_from_list deny)" && [[ -n "$_picked" ]]; then
              if _perms_confirm "Remove from deny: $_picked"; then
                if _perms_remove "deny" "$_picked"; then
                  success "Removed from deny: $_picked"
                else
                  error "Failed to update permissions file"
                fi
              else
                info "Cancelled."
              fi
            fi
            ;;

          "open in \$EDITOR")
            local _editor="${EDITOR:-}"
            [[ -z "$_editor" ]] && command -v nano &>/dev/null && _editor="nano"
            [[ -z "$_editor" ]] && command -v vi   &>/dev/null && _editor="vi"
            if [[ -z "$_editor" ]]; then
              error "No editor found. Set \$EDITOR."
            else
              "$_editor" "$PERMISSIONS_YAML"
              if ! _perms_validate; then
                warn "YAML validation warning — check $PERMISSIONS_YAML"
              else
                success "File saved."
              fi
            fi
            ;;

          "quit"|*)
            info "Exiting permissions editor."
            break
            ;;
        esac
        echo ""
      done
      return 0
      ;;

    *)
      error "Unknown subcommand: $subcmd"
      echo -e "  Run ${CYAN}devloop permissions --help${RESET} for usage."
      return 1
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
  echo -e "    Use ${GRAY}--configure${RESET} to re-run the wizard on an existing project."
  echo -e "  ${CYAN}devloop init --merge${RESET}"
  echo -e "    Safe re-init: only add missing config keys from the latest devloop version"
  echo -e "    Does NOT overwrite existing values or re-run the wizard.\n"
  echo -e "  ${CYAN}devloop configure${RESET}  ${GRAY}aliases: setup, wizard${RESET}"
  echo -e "    Re-run the interactive setup wizard to change providers, models, and permissions"
  echo -e "    Updates devloop.config.sh and regenerates agent prompt files."
  echo -e "  ${CYAN}devloop configure --global${RESET}"
  echo -e "    Edit global defaults in ${GRAY}~/.devloop/config.sh${RESET} (applies to all projects)"
  echo -e "    Project devloop.config.sh always overrides global values.\n"
  echo -e "  ${CYAN}devloop run \"feature\" [--type TYPE] [--files hints] [--max-retries N] [--no-learn] [--no-respec]${RESET}  ${GRAY}alias: go${RESET}"
  echo -e "    Full automated pipeline: architect → work → review → fix loop → learn"
  echo -e "    Fix escalation (DEVLOOP_FIX_STRATEGY=escalate, default):"
  echo -e "      Rounds 1-N/2: standard fix   |  Rounds N/2-N: deep fix (history injected)  |  After N: re-architect"
  echo -e "    ${GRAY}--no-respec${RESET}  skip the re-architect phase after all fix rounds are exhausted"
  echo -e "    One command replaces: architect + work + review + fix + review + ...\n"
  echo -e "  ${CYAN}devloop resume [TASK-ID]${RESET}${GRAY}                — resume an interrupted pipeline from the last completed phase${RESET}"
  echo -e "    ${GRAY}--list${RESET}      list resumable sessions"
  echo -e "    ${GRAY}--dry-run${RESET}   print would-resume info without executing\n"
  echo -e "  ${CYAN}devloop queue [add|list|run|clear]${RESET}  ${GRAY}alias: q${RESET}"
  echo -e "    Batch mode: queue multiple tasks and run them all sequentially"
  echo -e "    ${GRAY}add [--type TYPE] \"desc\"${RESET}  — enqueue a task"
  echo -e "    ${GRAY}list${RESET}                     — show pending tasks"
  echo -e "    ${GRAY}run [--stop-on-fail]${RESET}     — process all queued tasks"
  echo -e "    ${GRAY}clear${RESET}                    — empty the queue\n"
  echo -e "  ${CYAN}devloop sessions [--last N] [--status STATUS]${RESET}"
  echo -e "    List past pipeline runs with status, duration, and feature description\n"
  echo -e "  ${CYAN}devloop session <task-id>${RESET}"
  echo -e "    Show phase timeline and logs for a specific run\n"
  echo -e "  ${CYAN}devloop replay <task-id> [--phase PHASE]${RESET}"
  echo -e "    Replay recorded phase logs. PHASE: architect|worker|reviewer|fix-N|respec\n"
  echo -e "  ${CYAN}devloop${RESET}${GRAY}                                 — launch the live dashboard (TUI)${RESET}"
  echo -e "  ${CYAN}devloop dashboard${RESET}${GRAY}                       — same, explicit${RESET}"
  echo -e "    Go/Bubble Tea session dashboard. Build: ${GRAY}make tui-install${RESET}${GRAY} | env: DEVLOOP_DEFAULT_VIEW=help to disable${RESET}\n"
  echo -e "  ${CYAN}devloop view [task-id]${RESET}"
  echo -e "    Open live tmux dashboard: Architect | Worker | Reviewer | Fix/Decisions+Permissions"
  echo -e "    Falls back to inline log tail if tmux not installed\n"
  echo -e "  ${CYAN}devloop projects${RESET}"
  echo -e "    List all registered DevLoop projects with provider, last-run time, and status"
  echo -e "  ${CYAN}devloop projects switch <name>${RESET}"
  echo -e "    Print the path to a registered project (eval to cd: ${GRAY}eval \$(devloop projects switch myapp)${RESET})\n"
  echo -e "  ${CYAN}devloop inbox${RESET}"
  echo -e "    View pending human decisions: permissions, NEEDS_WORK, blocked tasks (current project)"
  echo -e "  ${CYAN}devloop inbox --all${RESET}"
  echo -e "    View pending items across ALL registered projects"
  echo -e "  ${CYAN}devloop inbox resolve <id> [approved|denied|skipped]${RESET}"
  echo -e "    Resolve a specific inbox item by ID"
  echo -e "  ${CYAN}devloop inbox history${RESET} / ${CYAN}devloop inbox clear${RESET}"
  echo -e "    View resolved items / remove resolved items from inbox\n"
  echo -e "  ${CYAN}devloop stats${RESET}"
  echo -e "    Show aggregated pipeline metrics: approval rates, avg phase times, fix rounds\n"
  echo -e "  ${CYAN}devloop start [project-name]${RESET}  ${GRAY}alias: s${RESET}"
  echo -e "    Launch provider session + orchestrator agent"
  echo -e "    Claude: remote-control (access from mobile/browser); Copilot: remote (GitHub web + mobile)"
  echo -e "    Prevents Mac sleep via caffeinate for session duration\n"
  echo -e "  ${CYAN}devloop daemon [project-name]${RESET}  ${GRAY}alias: d${RESET}"
  echo -e "    Run in background with auto-restart + sleep prevention"
  echo -e "    Claude: remote-control daemon (claude.ai/code); Copilot: remote daemon (github.com/copilot)"
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
  echo -e "  ${CYAN}devloop status [TASK-ID]${RESET}${GRAY}                — live single-session view (TUI; falls back to text when piped / env=text)${RESET}"
  echo -e "    Show full spec and latest review\n"
  echo -e "  ${CYAN}devloop chat${RESET}${GRAY}                            — slash-command REPL (TUI)${RESET}\n"
  echo -e "  ${CYAN}devloop open [TASK-ID]${RESET}  ${GRAY}alias: o${RESET}"
  echo -e "    Open spec in \$EDITOR (defaults to vi)\n"
  echo -e "  ${CYAN}devloop block [TASK-ID]${RESET}  ${GRAY}alias: b${RESET}"
  echo -e "    Print the Copilot Instructions Block for a task\n"
  echo -e "  ${CYAN}devloop clean [--days N] [--dry-run]${RESET}"
  echo -e "    Remove finalized (approved/rejected) specs older than N days (default: 30)"
  echo -e "    Use ${CYAN}--dry-run${RESET} to preview what would be removed\n"
  echo -e "  ${CYAN}devloop learn [TASK-ID]${RESET}"
  echo -e "    Extract lessons from the latest review and append to CLAUDE.md"
  echo -e "  ${CYAN}devloop learn --global [TASK-ID]${RESET}"
  echo -e "    Promote lessons to ${GRAY}~/.devloop/lessons.md${RESET} (shared across all projects)"
  echo -e "    Global lessons are injected into architect prompts for matching stacks\n"
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
  echo -e "  ${CYAN}devloop permissions${RESET}${GRAY}                     — edit .devloop/permissions.yaml (allow/deny lists)${RESET}"
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
  echo -e "  ${CYAN}copilot${RESET} as main → remote session (github.com/copilot + GitHub mobile app)\n"
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
  echo -e "${BOLD}SESSION VIEWER${RESET}\n"
  echo -e "  Every ${CYAN}devloop run${RESET} creates a session in ${CYAN}.devloop/sessions/<task-id>/${RESET}"
  echo -e "  Each phase writes a live log: architect.log | worker.log | reviewer.log | fix-N.log\n"
  echo -e "  ${CYAN}devloop sessions [--last N] [--status approved|running|needs-work]${RESET}"
  echo -e "    List past pipeline runs with status, duration, and feature description\n"
  echo -e "  ${CYAN}devloop session <task-id>${RESET}"
  echo -e "    Show phase timeline, log file sizes, and tail the main log\n"
  echo -e "  ${CYAN}devloop view [task-id]${RESET}"
  echo -e "    Open a live tmux dashboard: Architect | Worker | Reviewer | Fix/Decisions+Permissions"
  echo -e "    Requires tmux (${CYAN}brew install tmux${RESET}). Falls back to inline log tail if not installed."
  echo -e "    Decisions pane runs ${CYAN}devloop permit watch${RESET} to handle permission requests live\n"
  echo -e "  ${CYAN}devloop replay <task-id> [--phase architect|worker|reviewer|fix-N|respec]${RESET}"
  echo -e "    Replay recorded phase logs from a completed session. Supports phase filter.\n"
  echo -e "  ${BOLD}Config:${RESET} ${CYAN}DEVLOOP_SESSION_LOGGING=true${RESET}    enable/disable session logging"
  echo -e "           ${CYAN}DEVLOOP_AUTO_VIEW=false${RESET}        auto-open tmux view on devloop run"
  echo -e "           ${CYAN}DEVLOOP_SESSION_KEEP_DAYS=30${RESET}   auto-prune sessions older than N days (0=keep all)"
  echo -e "           ${CYAN}DEVLOOP_STATUS_HEADER=on${RESET}       pipeline status header in devloop run/resume (off to disable)\n"
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

  # ── Auto-launch dashboard when truly no-args + interactive + TUI present ──
  # Gated by DEVLOOP_DEFAULT_VIEW (dashboard|help, default dashboard).
  # Skipped when piped/redirected (no TTY) or when the binary isn't built.
  if [[ "$cmd" == "help" ]] && [[ $# -eq 0 ]] && [[ -t 1 ]]; then
    if [[ "${DEVLOOP_DEFAULT_VIEW:-dashboard}" == "dashboard" ]]; then
      if _find_tui >/dev/null 2>&1; then
        cmd_dashboard
        # cmd_dashboard execs; control does not return.
      fi
    fi
  fi

  # Bootstrap global ~/.devloop/ structure silently on every run
  _ensure_global_dirs

  header

  # ── Natural-language pre-detection ─────────────────────────────────────────
  # When a "utility" command (that takes no positional args) is followed by
  # plain-English words (not flags or task IDs), treat the whole thing as NL.
  # e.g. "devloop check the latest progress..." → cmd_do instead of cmd_check
  # IMPORTANT: commands that accept subcommands (failover, daemon, tools, hooks, permit)
  # must NOT be in this list — their single-word args are subcommands, not NL prose.
  local _zero_arg_cmds=" check update doctor agent-sync sync-agents agentsync logs clean ci tasks "
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
    sessions)         cmd_sessions "$@" ;;
    session)          cmd_session  "$@" ;;
    replay)           cmd_replay   "$@" ;;
    dashboard|dash)   cmd_dashboard "$@" ;;
    chat)             cmd_chat "$@" ;;
    view)             cmd_view     "$@" ;;
    projects)         cmd_projects "$@" ;;
    inbox)            cmd_inbox    "$@" ;;
    stats)            cmd_stats    "$@" ;;
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
    permit)           cmd_permit      "$@" ;;
    resume|continue)   cmd_resume      "$@" ;;
    permissions|perms) cmd_permissions "$@" ;;
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
      # Guard: if the command itself is a TASK-ID, user likely meant 'devloop resume TASK-...'
      if [[ "$cmd" =~ ^TASK-[0-9]{8}-[0-9]{6}$ ]]; then
        warn "Looks like a task ID — routing to: devloop resume $cmd"
        echo -e "  ${GRAY}Tip: ${CYAN}devloop resume $cmd${GRAY} to be explicit next time${RESET}"
        cmd_resume "$cmd" "$@"
      elif [[ "$cmd" != -* ]] && [[ "$_nl_candidate" == *" "* ]]; then
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
