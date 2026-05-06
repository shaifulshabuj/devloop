#!/usr/bin/env bash
# =============================================================================
# devloop — Claude Code (Architect) + Copilot CLI (Worker) orchestration tool
#
# Install globally:
#   curl -fsSL https://raw.githubusercontent.com/you/devloop/main/devloop \
#     -o /usr/local/bin/devloop && chmod +x /usr/local/bin/devloop
#
# Or manually:
#   chmod +x devloop && sudo mv devloop /usr/local/bin/devloop
#
# Usage:
#   devloop init     — set up a project (agents, CLAUDE.md, config)
#   devloop start    — launch Claude with remote control + orchestrator agent
#   devloop architect "feature"
#   devloop work [TASK-ID]
#   devloop review [TASK-ID]
#   devloop fix [TASK-ID]
#   devloop tasks
#   devloop status [TASK-ID]
# =============================================================================

set -euo pipefail

VERSION="2.0.0"
DEVLOOP_DIR=".devloop"
SPECS_DIR="$DEVLOOP_DIR/specs"
PROMPTS_DIR="$DEVLOOP_DIR/prompts"
AGENTS_DIR=".claude/agents"
CONFIG_FILE="devloop.config.sh"

# ── Colors ────────────────────────────────────────────────────────────────────
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
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

  if [[ -f "$CONFIG_PATH" ]]; then source "$CONFIG_PATH"; fi
}

ensure_dirs() {
  mkdir -p "$SPECS_PATH" "$PROMPTS_PATH" "$AGENTS_PATH"
}

check_deps() {
  local missing=()
  command -v claude  &>/dev/null || missing+=("claude  → curl -fsSL https://claude.ai/install.sh | bash")
  command -v copilot &>/dev/null || missing+=("copilot → gh extension install github/gh-copilot")
  command -v git     &>/dev/null || missing+=("git     → https://git-scm.com")
  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing required tools:"
    for m in "${missing[@]}"; do echo -e "    ${GRAY}$m${RESET}"; done
    exit 1
  fi
}

task_id()     { echo "TASK-$(date +%Y%m%d-%H%M)"; }
latest_task() { ls -1t "$SPECS_PATH"/*.md 2>/dev/null | grep -v '\-review' | head -1 | xargs basename 2>/dev/null | sed 's/.md//' || echo ""; }

# ── Embedded Agent Definitions ────────────────────────────────────────────────
# These are written to .claude/agents/ by `devloop init`

write_agent_orchestrator() {
  cat > "$AGENTS_PATH/devloop-orchestrator.md" <<'AGENT'
---
name: devloop-orchestrator
description: Main DevLoop orchestrator. Receives feature requests remotely and coordinates the architect and reviewer agents through the full build loop until approved. Use for all feature development, bugfixes, and refactoring.
tools: Agent(devloop-architect, devloop-reviewer), Bash, Read, Write
model: sonnet
color: cyan
---

You are the DevLoop Orchestrator — the main coordinator of a three-agent development pipeline. The user sends instructions remotely from claude.ai or the Claude mobile app.

## Pipeline
```
User (remote: mobile / browser)
  → You (orchestrator, main thread)
    → @devloop-architect (subagent: designs spec)
    → Bash: devloop work  (Copilot CLI implements)
    → @devloop-reviewer   (subagent: reviews result)
    → loop until APPROVED
```

## Workflow

### On receiving a task from the user:

**Step 1 — Confirm**
Echo back what you understood. State the plan in one line.

**Step 2 — Architect**
Delegate to the architect subagent:
```
@devloop-architect Design spec for: [feature]
Type: [feature|bugfix|refactor|test]
Files: [any file hints, or omit]
```
Wait for the Task ID (e.g. TASK-20260504-0930).

**Step 3 — Implement**
Tell the user: "📐 Spec ready. Launching Copilot to implement..."
Run:
```bash
devloop work TASK-ID
```

**Step 4 — Review**
```
@devloop-reviewer Review task: TASK-ID
```

**Step 5 — Handle verdict**
- **APPROVED** → Summarize what was built. Done. ✅
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
- `copilot: not found` → tell user: `gh extension install github/gh-copilot`
- No git changes after work → ask user to confirm Copilot finished
AGENT
}

write_agent_architect() {
  cat > "$AGENTS_PATH/devloop-architect.md" <<'AGENT'
---
name: devloop-architect
description: DevLoop architect. Designs precise implementation specs for Copilot. Called by orchestrator with a feature description. Returns Task ID and spec summary.
tools: Bash, Read, Glob, Grep
model: opus
color: blue
---

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
- Task ID (e.g. `TASK-20260504-0930`)
- 2-sentence summary of what the spec covers
- Key signatures from the spec

## Spec requirements
- Exact method signatures with full types
- Explicit business rules
- All edge cases enumerated
- Test scenarios in table format
- Copilot Instructions Block included
AGENT
}

write_agent_reviewer() {
  cat > "$AGENTS_PATH/devloop-reviewer.md" <<'AGENT'
---
name: devloop-reviewer
description: DevLoop reviewer. Reviews Copilot's implementation against the task spec via git diff. Returns APPROVED, NEEDS_WORK, or REJECTED with specific issues and fix instructions.
tools: Bash, Read, Glob, Grep
model: sonnet
color: yellow
---

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
AGENT
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

# ── cmd: init ────────────────────────────────────────────────────────────────

cmd_init() {
  load_config
  ensure_dirs

  step "Initializing DevLoop in: ${CYAN}$(basename "$(find_project_root)")${RESET}"
  divider

  # 1. Write agent definitions
  write_agent_orchestrator
  success "Agent: ${CYAN}$AGENTS_PATH/devloop-orchestrator.md${RESET}"
  write_agent_architect
  success "Agent: ${CYAN}$AGENTS_PATH/devloop-architect.md${RESET}"
  write_agent_reviewer
  success "Agent: ${CYAN}$AGENTS_PATH/devloop-reviewer.md${RESET}"

  # 2. Project config
  if [[ -f "$CONFIG_PATH" ]]; then
    warn "devloop.config.sh already exists — skipping"
  else
    cat > "$CONFIG_PATH" <<'CONFIG'
# DevLoop Project Configuration — edit to match your stack

PROJECT_NAME="$(basename "$PWD")"
PROJECT_STACK="C#, .NET 8, ASP.NET Web API, MSSQL"
PROJECT_PATTERNS="SOLID, Repository Pattern, Clean Architecture"
PROJECT_CONVENTIONS="async/await throughout, custom exception classes, no magic strings, XML doc comments on public APIs"
TEST_FRAMEWORK="xUnit"

# Model for architect/reviewer calls via claude -p
# "sonnet" = faster/cheaper, "opus" = more capable
CLAUDE_MODEL="sonnet"
CONFIG
    success "Created: ${CYAN}devloop.config.sh${RESET}"
  fi

  # 3. CLAUDE.md
  if [[ ! -f "CLAUDE.md" ]]; then
    cat > CLAUDE.md <<'CLAUDEMD'
# Claude Code — DevLoop Project

## System
This project uses the DevLoop multi-agent pipeline:
- `devloop-orchestrator` — main thread, receives remote instructions
- `devloop-architect`    — subagent, designs implementation specs
- `devloop-reviewer`     — subagent, reviews Copilot's implementation
- `copilot CLI`          — external worker, implements specs

## Start the system
```bash
devloop start
```
Then connect from claude.ai/code or the Claude mobile app.

## DevLoop commands
- `devloop architect "feature"` — design a spec
- `devloop work [TASK-ID]`      — launch Copilot to implement
- `devloop review [TASK-ID]`    — review implementation
- `devloop fix [TASK-ID]`       — launch Copilot with fix instructions
- `devloop tasks`               — list all specs
- `devloop status [TASK-ID]`    — show spec + review

## Stack
See devloop.config.sh for project-specific stack details.
CLAUDEMD
    success "Created: ${CYAN}CLAUDE.md${RESET}"
  else
    warn "CLAUDE.md already exists — skipping"
  fi

  # 4. Copilot instructions
  mkdir -p .github
  if [[ ! -f ".github/copilot-instructions.md" ]]; then
    cat > .github/copilot-instructions.md <<'COPILOT'
# GitHub Copilot Instructions — DevLoop Worker

## Your Role
You are the implementation worker. Follow DEVLOOP TASK specs exactly.

## Workflow
1. Read the task spec and Copilot Instructions Block carefully
2. Use /plan to create an implementation checklist
3. Implement each step in order
4. Run tests if the framework is available
5. Summarize what was implemented

## Standards
- Follow every rule in the task spec
- Handle all edge cases listed
- Write tests for all scenarios
- Never skip error handling
- Commit with a descriptive message when done
COPILOT
    success "Created: ${CYAN}.github/copilot-instructions.md${RESET}"
  else
    warn ".github/copilot-instructions.md already exists — skipping"
  fi

  divider
  echo ""
  echo -e "${GREEN}${BOLD}✅ DevLoop initialized!${RESET}\n"
  echo -e "${BOLD}Next steps:${RESET}"
  echo -e "  1. Edit ${CYAN}devloop.config.sh${RESET} with your project stack"
  echo -e "  2. Run ${CYAN}devloop start${RESET} to launch the orchestrator"
  echo -e "  3. Open ${CYAN}claude.ai/code${RESET} or the Claude app and find your session"
  echo -e "  4. Send a feature request — the pipeline runs automatically"
  echo ""
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
  # caffeinate keeps macOS awake: -i=on idle, -s=on AC power (handles sleep button too)
  if command -v caffeinate &>/dev/null; then
    caffeinate -is &
    CAFFEINATE_PID=$!
    success "Sleep prevention active ${GRAY}(caffeinate PID $CAFFEINATE_PID)${RESET}"
  else
    warn "caffeinate not found — Mac may sleep during session"
    warn "Install: brew install caffeinate  or use macOS built-in /usr/bin/caffeinate"
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

  step "Starting DevLoop for: ${CYAN}$project_name${RESET}"
  divider
  echo ""
  echo -e "${BOLD}Launching:${RESET}"
  echo -e "  ${CYAN}--remote-control${RESET}      accessible from mobile + browser"
  echo -e "  ${CYAN}--agent orchestrator${RESET}  main thread is the orchestrator"
  echo -e "  ${CYAN}caffeinate -is${RESET}        Mac stays awake while session runs"
  echo ""
  echo -e "${BOLD}Connect from:${RESET}"
  echo -e "  📱 Claude app → find ${CYAN}\"DevLoop: $project_name\"${RESET} with green dot"
  echo -e "  🌐 ${CYAN}https://claude.ai/code${RESET} → session list"
  echo ""
  echo -e "${GRAY}Press Ctrl+C to stop.${RESET}"
  divider
  echo ""

  # Prevent Mac sleep for the entire session duration
  CAFFEINATE_PID=""
  _prevent_sleep

  # Ensure caffeinate is killed on exit/interrupt
  trap '_stop_sleep_prevention; exit 0' INT TERM EXIT

  _launch_claude "$project_name"
}

# ── cmd: daemon ───────────────────────────────────────────────────────────────
# Runs in background with auto-restart on crash/wake — survives sleep cycles

cmd_daemon() {
  load_config
  check_deps
  _verify_agents

  local project_name="${1:-$PROJECT_NAME}"
  local log_file="${DEVLOOP_DIR}/daemon.log"
  local pid_file="${DEVLOOP_DIR}/daemon.pid"
  local restart_delay=5
  local max_restarts=20

  # ── subcommands: stop / status ─────────────────────────────────────────────
  local subcmd="${2:-}"
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
  esac

  # ── start daemon ───────────────────────────────────────────────────────────
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

  # Launch the restart loop in background
  (
    local attempt=0
    local cafpid=""

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

      # Start caffeinate fresh each attempt (survives wake from sleep)
      [[ -n "$cafpid" ]] && kill "$cafpid" 2>/dev/null || true
      /usr/bin/caffeinate -is &
      cafpid=$!

      # Run claude, capture exit code
      _launch_claude "$project_name" >> "$log_file" 2>&1
      local exit_code=$?

      echo "[$(date)] Session ended (exit $exit_code)" >> "$log_file"

      # Exit cleanly on Ctrl+C (SIGINT propagated)
      if (( exit_code == 130 )); then
        echo "[$(date)] Stopped by user" >> "$log_file"
        break
      fi

      # Brief pause before restart to avoid tight crash loops
      echo "[$(date)] Restarting in ${restart_delay}s..." >> "$log_file"
      sleep "$restart_delay"

      # Backoff: increase delay each restart (cap at 60s)
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
  echo -e "  ${CYAN}devloop daemon status${RESET}  check if running"
  echo -e "  ${CYAN}devloop daemon log${RESET}     tail live logs"
  echo -e "  ${CYAN}devloop daemon stop${RESET}    stop the daemon"
  echo ""

  # Also set up a launchd plist so it survives login/reboot
  _write_launchd "$project_name"
}

# ── launchd: survive reboot ───────────────────────────────────────────────────

_write_launchd() {
  local project_name="$1"
  local label="com.devloop.$(echo "$project_name" | tr '[:upper:] ' '[:lower:]_')"
  local plist="$HOME/Library/LaunchAgents/$label.plist"
  local project_dir; project_dir="$(find_project_root)"
  local devloop_bin; devloop_bin="$(command -v devloop)"
  local log_dir; log_dir="$project_dir/$DEVLOOP_DIR"

  # Only write on macOS
  [[ "$(uname)" != "Darwin" ]] && return

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

  <!-- Prevent system sleep while running -->
  <key>ProcessType</key>
  <string>Interactive</string>

  <key>StandardOutPath</key>
  <string>$log_dir/launchd.log</string>
  <key>StandardErrorPath</key>
  <string>$log_dir/launchd-error.log</string>
</dict>
</plist>
PLIST

  # Load it now
  launchctl unload "$plist" 2>/dev/null || true
  launchctl load "$plist" 2>/dev/null && \
    info "launchd agent registered — DevLoop starts automatically on login" || \
    warn "Could not register launchd agent (run manually if needed)"

  info "Plist: ${GRAY}$plist${RESET}"
  echo -e "  ${GRAY}Remove with: devloop daemon uninstall${RESET}"
}

_remove_launchd() {
  load_config
  local project_name="${1:-$PROJECT_NAME}"
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

  step "📐 Claude designing spec: ${BOLD}\"$feature\"${RESET}"
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

  info "Calling claude -p (print mode)..."
  echo ""

  if ! echo "$prompt" | claude -p --model "$CLAUDE_MODEL" > "$spec_file" 2>/dev/null; then
    echo "$prompt" | claude -p > "$spec_file"
  fi

  success "Spec saved: ${CYAN}$spec_file${RESET}"
  divider

  # Extract and show the Copilot Instructions Block
  step "📋 Copilot Instructions Block"
  local block
  block="$(awk '/^## Copilot Instructions Block/{f=1;next} f&&/^```$/{c++;if(c==2)exit} f&&c==1' "$spec_file")"

  if [[ -n "$block" ]]; then
    divider
    echo -e "${YELLOW}$block${RESET}"
    divider
    local instructions_file="$PROMPTS_PATH/$id-copilot.txt"
    echo "$block" > "$instructions_file"
    success "Instructions saved: ${CYAN}$instructions_file${RESET}"
  else
    tail -20 "$spec_file"
  fi

  echo ""
  echo -e "${BOLD}Next:${RESET}  ${CYAN}devloop work $id${RESET}"
  echo ""
}

# ── cmd: work ────────────────────────────────────────────────────────────────

cmd_work() {
  local id="${1:-$(latest_task)}"
  [[ -z "$id" ]] && { error "No task found. Run: devloop architect \"feature\""; exit 1; }

  load_config
  check_deps

  local spec_file="$SPECS_PATH/$id.md"
  local instructions_file="$PROMPTS_PATH/$id-copilot.txt"
  [[ ! -f "$spec_file" ]] && { error "Spec not found: $id"; exit 1; }

  step "🤖 Copilot implementing: ${BOLD}$id${RESET}"
  divider

  local task_prompt
  if [[ -f "$instructions_file" ]]; then
    task_prompt="$(cat "$instructions_file")"
  else
    task_prompt="$(awk '/^## Copilot Instructions Block/{f=1;next} f&&/^```$/{c++;if(c==2)exit} f&&c==1' "$spec_file")"
  fi

  [[ -z "$task_prompt" ]] && task_prompt="$(cat "$spec_file")"

  info "Launching Copilot CLI with /plan mode..."
  echo ""

  echo "/plan Implement the following DevLoop task:

$task_prompt

After planning, implement all steps. Run tests if possible. Summarize what was implemented." | copilot

  echo ""
  success "Copilot session ended"
  echo -e "  ${CYAN}devloop review $id${RESET}"
  echo ""
}

# ── cmd: review ──────────────────────────────────────────────────────────────

cmd_review() {
  local id="${1:-$(latest_task)}"
  [[ -z "$id" ]] && { error "No task found."; exit 1; }

  load_config
  ensure_dirs
  check_deps

  local spec_file="$SPECS_PATH/$id.md"
  [[ ! -f "$spec_file" ]] && { error "Spec not found: $id"; exit 1; }

  step "🔍 Claude reviewing: ${BOLD}$id${RESET}"
  divider

  info "Reading git changes..."
  local impl=""
  local diff; diff="$(git diff HEAD 2>/dev/null || git diff 2>/dev/null || echo "")"
  local staged; staged="$(git diff --cached 2>/dev/null || echo "")"
  local new_files; new_files="$(git ls-files --others --exclude-standard 2>/dev/null | head -8 || echo "")"

  [[ -n "$diff"   ]] && impl+="## Modified files\n\`\`\`diff\n$diff\n\`\`\`\n\n"
  [[ -n "$staged" ]] && impl+="## Staged changes\n\`\`\`diff\n$staged\n\`\`\`\n\n"

  while IFS= read -r file; do
    [[ -f "$file" ]] && impl+="## New file: $file\n\`\`\`\n$(cat "$file")\n\`\`\`\n\n"
  done <<< "$new_files"

  [[ -z "$impl" ]] && { warn "No git changes detected — Copilot may not have committed yet."; impl="(No git changes)"; }

  local spec_content; spec_content="$(cat "$spec_file")"

  local review_prompt
  review_prompt="$(cat <<PROMPT
You are a strict senior code reviewer.

## Project
- Stack: $PROJECT_STACK
- Patterns: $PROJECT_PATTERNS
- Conventions: $PROJECT_CONVENTIONS

## Original Spec
$spec_content

## Implementation (git diff)
$(echo -e "$impl")

## Review criteria (priority order)
1. Spec compliance
2. Correctness / edge cases
3. Error handling
4. Code quality (SOLID)
5. Security
6. Test coverage

## Required output format

### Verdict: APPROVED | NEEDS_WORK | REJECTED

**Score**: X/10
**Summary**: [one sentence]

### What's Good
- [specific positive]

### Issues Found
| # | Severity | File/Area | Issue |
|---|----------|-----------|-------|
| 1 | CRITICAL/HIGH/MEDIUM/LOW | area | description |

### Required Fixes
**Fix 1**: description
\`\`\`
// exact code
\`\`\`

### Copilot Fix Instructions
\`\`\`
DEVLOOP REVIEW: $id
VERDICT: [verdict]

FIX #1:
  IN: [file/method]
  PROBLEM: [what's wrong]
  SOLUTION: [what to do]
\`\`\`

If APPROVED: "Implementation matches spec. No fixes required."
PROMPT
)"

  info "Calling claude -p for review..."
  echo ""

  local review_file="$SPECS_PATH/$id-review.md"
  if ! echo "$review_prompt" | claude -p --model "$CLAUDE_MODEL" | tee "$review_file"; then
    echo "$review_prompt" | claude -p | tee "$review_file"
  fi

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
  esac

  echo ""
  info "Review saved: ${CYAN}$review_file${RESET}"
  echo ""
}

# ── cmd: fix ─────────────────────────────────────────────────────────────────

cmd_fix() {
  local id="${1:-$(latest_task)}"
  [[ -z "$id" ]] && { error "No task found."; exit 1; }

  load_config
  check_deps

  local review_file="$SPECS_PATH/$id-review.md"
  [[ ! -f "$review_file" ]] && { error "No review found. Run: devloop review $id"; exit 1; }

  step "🔧 Copilot fixing: ${BOLD}$id${RESET}"
  divider

  local fix_instructions
  fix_instructions="$(awk '/^### Copilot Fix Instructions/{f=1;next} f&&/^```$/{c++;if(c==2)exit} f&&c==1' "$review_file")"
  [[ -z "$fix_instructions" ]] && fix_instructions="$(cat "$review_file")"

  info "Launching Copilot CLI with Claude's fix instructions..."
  echo ""

  echo "The following issues were identified in a code review. Fix each one:

$fix_instructions

Fix all CRITICAL and HIGH severity issues. After fixing, summarize the changes made." | copilot

  echo ""
  success "Fix session ended"
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
  printf "  %-25s %-45s %s\n" "TASK ID" "FEATURE" "STATUS"
  divider

  for spec in $(ls -1t "$SPECS_PATH"/*.md 2>/dev/null | grep -v '\-review\.md'); do
    local id; id="$(basename "$spec" .md)"
    local feature; feature="$(grep '^\*\*Feature\*\*:' "$spec" 2>/dev/null | sed 's/\*\*Feature\*\*: //' | head -1)"
    local status; status="$(grep '^\*\*Status\*\*:' "$spec" 2>/dev/null | sed 's/\*\*Status\*\*: //' | head -1)"
    local icon="⏳"
    [[ "$status" == *approved*  ]] && icon="✅"
    [[ "$status" == *rejected*  ]] && icon="❌"
    [[ "$status" == *needs-work* ]] && icon="⚠️ "
    printf "  %s %-23s %-45s %s\n" "$icon" "$id" "${feature:0:44}" "${status:-pending}"
  done

  divider
  echo ""
}

# ── cmd: status ───────────────────────────────────────────────────────────────

cmd_status() {
  local id="${1:-$(latest_task)}"
  load_config

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
}

# ── cmd: help ─────────────────────────────────────────────────────────────────

cmd_help() {
  echo -e "${BOLD}COMMANDS${RESET}\n"
  echo -e "  ${CYAN}devloop install${RESET}"
  echo -e "    Install devloop to /usr/local/bin (run once)\n"
  echo -e "  ${CYAN}devloop init${RESET}"
  echo -e "    Set up DevLoop in current project"
  echo -e "    Writes: agents, CLAUDE.md, devloop.config.sh, copilot-instructions\n"
  echo -e "  ${CYAN}devloop start [project-name]${RESET}  ${GRAY}alias: s${RESET}"
  echo -e "    Launch Claude with remote control + orchestrator agent"
  echo -e "    Prevents Mac sleep via caffeinate for session duration\n"
  echo -e "  ${CYAN}devloop daemon [project-name]${RESET}  ${GRAY}alias: d${RESET}"
  echo -e "    Run in background with auto-restart + sleep prevention"
  echo -e "    Registers launchd agent so it survives reboot/logout"
  echo -e "    Sub-commands: stop | status | log | uninstall\n"
  echo -e "  ${CYAN}devloop architect \"feature\" [type] [files]${RESET}  ${GRAY}alias: a${RESET}"
  echo -e "    Claude designs an implementation spec (called by orchestrator)\n"
  echo -e "  ${CYAN}devloop work [TASK-ID]${RESET}  ${GRAY}alias: w${RESET}"
  echo -e "    Launch Copilot CLI to implement the spec\n"
  echo -e "  ${CYAN}devloop review [TASK-ID]${RESET}  ${GRAY}alias: r${RESET}"
  echo -e "    Claude reviews git diff → APPROVED / NEEDS_WORK / REJECTED\n"
  echo -e "  ${CYAN}devloop fix [TASK-ID]${RESET}  ${GRAY}alias: f${RESET}"
  echo -e "    Launch Copilot with Claude's fix instructions\n"
  echo -e "  ${CYAN}devloop tasks${RESET}  ${GRAY}alias: t${RESET}"
  echo -e "    List all task specs with status\n"
  echo -e "  ${CYAN}devloop status [TASK-ID]${RESET}"
  echo -e "    Show full spec and latest review\n"
  echo -e "${BOLD}SETUP (one-time)${RESET}\n"
  echo -e "  ${GRAY}# Install devloop globally${RESET}"
  echo -e "  ${CYAN}curl -fsSL https://your-host/devloop -o /tmp/devloop${RESET}"
  echo -e "  ${CYAN}chmod +x /tmp/devloop && sudo mv /tmp/devloop /usr/local/bin/devloop${RESET}\n"
  echo -e "  ${GRAY}# In each project:${RESET}"
  echo -e "  ${CYAN}cd your-project/${RESET}"
  echo -e "  ${CYAN}devloop init${RESET}"
  echo -e "  ${CYAN}devloop start${RESET}  ${GRAY}← connect from mobile/browser${RESET}\n"
  echo -e "${BOLD}REQUIREMENTS${RESET}\n"
  echo -e "  ${CYAN}claude${RESET}   Claude Code CLI   ${GRAY}curl -fsSL https://claude.ai/install.sh | bash${RESET}"
  echo -e "  ${CYAN}copilot${RESET}  Copilot CLI        ${GRAY}gh extension install github/gh-copilot${RESET}"
  echo -e "  ${CYAN}git${RESET}      Git\n"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  local cmd="${1:-help}"
  shift 2>/dev/null || true

  # Version / help flags (no header needed)
  case "$cmd" in
    -v|-V|--version|version) echo -e "${CYAN}${BOLD}devloop${RESET} v${VERSION}"; exit 0 ;;
    --help|-h) header; cmd_help; exit 0 ;;
  esac

  header

  case "$cmd" in
    install)             cmd_install "$@" ;;
    init)                cmd_init "$@" ;;
    start|s)             cmd_start "$@" ;;
    daemon|d)
      load_config
      case "${2:-}" in
        uninstall) _remove_launchd "${3:-$PROJECT_NAME}" ;;
        *)         cmd_daemon "$@" ;;
      esac
      ;;
    architect|a)         cmd_architect "$@" ;;
    work|w)              cmd_work "$@" ;;
    review|r)            cmd_review "$@" ;;
    fix|f)               cmd_fix "$@" ;;
    tasks|t)             cmd_tasks "$@" ;;
    status)              cmd_status "$@" ;;
    help)                cmd_help ;;
    *)
      error "Unknown command: $cmd"
      echo ""
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"