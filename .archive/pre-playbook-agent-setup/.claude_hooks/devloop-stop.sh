#!/usr/bin/env bash
# DevLoop Stop hook — logs when Claude finishes a turn
LOG="$(git rev-parse --show-toplevel 2>/dev/null)/.devloop/pipeline.log"
mkdir -p "$(dirname "$LOG")"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
INPUT="$(cat)"
STOP_REASON="$(printf '%s' "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('stop_reason','unknown'))" 2>/dev/null || echo "unknown")"
printf '[%s] Claude turn ended — stop_reason: %s\n' "$TIMESTAMP" "$STOP_REASON" >> "$LOG"
