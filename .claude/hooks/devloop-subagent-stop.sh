#!/usr/bin/env bash
# DevLoop SubagentStop hook — logs when an agent (architect/reviewer) completes
LOG="$(git rev-parse --show-toplevel 2>/dev/null)/.devloop/pipeline.log"
mkdir -p "$(dirname "$LOG")"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
INPUT="$(cat)"
AGENT="$(printf '%s' "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('agent_name', d.get('subagent_name','unknown')))" 2>/dev/null || echo "unknown")"
printf '[%s] Subagent completed — agent: %s\n' "$TIMESTAMP" "$AGENT" >> "$LOG"
