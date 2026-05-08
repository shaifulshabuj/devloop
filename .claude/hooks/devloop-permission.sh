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
