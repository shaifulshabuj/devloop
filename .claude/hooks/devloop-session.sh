#!/usr/bin/env bash
# DevLoop SessionStart/End hook — records session boundaries
LOG="$(git rev-parse --show-toplevel 2>/dev/null)/.devloop/sessions.log"
mkdir -p "$(dirname "$LOG")"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
INPUT="$(cat)"
EVENT="$(printf '%s' "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('event','session_event'))" 2>/dev/null || echo "session_event")"
SESSION="$(printf '%s' "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('session_id','')[:8])" 2>/dev/null || echo "?")"
printf '[%s] %s session=%s\n' "$TIMESTAMP" "$EVENT" "$SESSION" >> "$LOG"
