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
