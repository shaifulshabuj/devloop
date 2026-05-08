#!/usr/bin/env bash
# DevLoop Notification hook — forwards Claude notifications to a log
LOG="$(git rev-parse --show-toplevel 2>/dev/null)/.devloop/notifications.log"
mkdir -p "$(dirname "$LOG")"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
INPUT="$(cat)"
MSG="$(printf '%s' "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('message',''))" 2>/dev/null || echo "$INPUT")"
printf '[%s] %s\n' "$TIMESTAMP" "$MSG" >> "$LOG"
