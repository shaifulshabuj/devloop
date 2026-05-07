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

VERSION="2.1.0"
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
  local provider="${1:-}"
  provider="$(printf '%s' "$provider" | tr '[:upper:]' '[:lower:]')"
  case "$provider" in
    claude|copilot) echo "$provider" ;;
    *)
      error "Invalid DevLoop provider: ${provider:-<empty>}"
      error "Expected one of: claude, copilot"
      exit 1
      ;;
  esac
}

provider_label() {
  case "$1" in
    claude) echo "Claude" ;;
    copilot) echo "Copilot" ;;
    *) echo "$1" ;;
  esac
}

main_provider() {
  normalize_provider "${DEVLOOP_MAIN_PROVIDER:-claude}"
}

worker_provider() {
  normalize_provider "${DEVLOOP_WORKER_PROVIDER:-copilot}"
}

run_provider_prompt() {
  local provider="$1"
  local prompt="$2"
  local output_file="$3"

  case "$provider" in
    claude)
      if ! echo "$prompt" | claude -p --model "$CLAUDE_MODEL" > "$output_file" 2>/dev/null; then
        echo "$prompt" | claude -p > "$output_file"
      fi
      ;;
    copilot)
      echo "$prompt" | copilot > "$output_file"
      ;;
    *)
      error "Unsupported provider: $provider"
      exit 1
      ;;
  esac
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
- `copilot: not found` → tell user: `gh extension install github/gh-copilot`
- No git changes after work → ask user to confirm Copilot finished
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

# ── cmd: init ────────────────────────────────────────────────────────────────

cmd_init() {
  load_config
  ensure_dirs

  step "Initializing DevLoop in: ${CYAN}$(basename "$(find_project_root)")${RESET}"
  divider

  # 1. Write agent definitions — FIX #5: pass CLAUDE_MODEL so agents stay in sync with config
  write_agent_orchestrator
  success "Agent: ${CYAN}$AGENTS_PATH/devloop-orchestrator.md${RESET}"
  write_agent_architect "$CLAUDE_MODEL"
  success "Agent: ${CYAN}$AGENTS_PATH/devloop-architect.md${RESET}"
  write_agent_reviewer "$CLAUDE_MODEL"
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

# Provider routing
# main = orchestrator / architect / reviewer
# worker = work / fix
# Valid values: claude, copilot
DEVLOOP_MAIN_PROVIDER="claude"
DEVLOOP_WORKER_PROVIDER="copilot"

# Model for claude -p calls when a role uses Claude
# "sonnet" = faster/cheaper   "opus" = more capable
CLAUDE_MODEL="sonnet"

# Optional: set to enable 'devloop update'
# DEVLOOP_SOURCE_URL="https://raw.githubusercontent.com/you/devloop/main/devloop.sh"
CONFIG
    success "Created: ${CYAN}devloop.config.sh${RESET}"
    warn "Edit devloop.config.sh then re-run ${CYAN}devloop init${RESET} to apply stack to all files"
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
- Provider routing is controlled in `devloop.config.sh`:
  - `DEVLOOP_MAIN_PROVIDER` for orchestrator / architect / reviewer
  - `DEVLOOP_WORKER_PROVIDER` for work / fix
- The current launcher stays Claude remote-control in v1.

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
- `devloop open [TASK-ID]`      — open spec in $EDITOR
- `devloop block [TASK-ID]`     — print Copilot Instructions Block
- `devloop clean [--days N]`    — remove old specs
- `devloop update`              — self-upgrade devloop

## Stack
See devloop.config.sh for project-specific stack details.
CLAUDEMD
    success "Created: ${CYAN}CLAUDE.md${RESET}"
  else
    warn "CLAUDE.md already exists — skipping"
  fi

  # 4. Copilot instructions — FIX #9 #11: rich template with stack context
  mkdir -p .github
  if [[ ! -f ".github/copilot-instructions.md" ]]; then
    _write_copilot_instructions
    success "Created: ${CYAN}.github/copilot-instructions.md${RESET}"
  else
    warn ".github/copilot-instructions.md already exists — skipping"
    info "Regenerate with: ${CYAN}rm .github/copilot-instructions.md && devloop init${RESET}"
  fi

  divider
  echo ""
  echo -e "${GREEN}${BOLD}✅ DevLoop initialized!${RESET}\n"
  echo -e "${BOLD}Next steps:${RESET}"
  echo -e "  1. Edit ${CYAN}devloop.config.sh${RESET} with your project stack"
  echo -e "  2. Re-run ${CYAN}devloop init${RESET} to apply stack to agent + copilot files"
  echo -e "  3. Run ${CYAN}devloop start${RESET} to launch the orchestrator"
  echo -e "  4. Open ${CYAN}claude.ai/code${RESET} or the Claude app and find your session"
  echo -e "  5. Send a feature request — the pipeline runs automatically"
  echo ""
}

# ── Copilot instructions writer ────────────────────────────────────────────────
# FIX #9 #11: Detailed template with live stack config values.
# Called from cmd_init. Re-run `devloop init` after editing devloop.config.sh
# to refresh this file with new stack values.

_write_copilot_instructions() {
  mkdir -p .github
  cat > .github/copilot-instructions.md <<COPILOT
# GitHub Copilot Instructions — DevLoop Worker

## Your Role
You are the implementation worker in the DevLoop pipeline.
Follow DEVLOOP TASK specs exactly — no improvisation on behaviour not specified in the spec.
If `DEVLOOP_WORKER_PROVIDER` is set to `claude`, DevLoop will route worker tasks through Claude instead of Copilot.

## Project Stack
- **Stack**: $PROJECT_STACK
- **Patterns**: $PROJECT_PATTERNS
- **Conventions**: $PROJECT_CONVENTIONS
- **Test framework**: $TEST_FRAMEWORK

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
2. Use \`/plan\` to build a step-by-step implementation checklist
3. Implement each step in order, following every rule listed
4. Write tests for every row in the Test Scenarios table
5. Run tests (\`$TEST_FRAMEWORK\`) — fix failures before committing
6. Stage **all** changed files and commit in a single commit

## Commit Message Format
\`\`\`
feat(TASK-ID): <one-line summary of what was implemented>
\`\`\`
Example: \`feat(TASK-20260506-143022): add GET /orders endpoint with date range filter\`

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
- [ ] Tests written and passing (framework: $TEST_FRAMEWORK)
- [ ] Single commit with TASK ID in message (feat(TASK-ID): ...)
COPILOT
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
  provider="$(main_provider)"

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
  provider="$(worker_provider)"

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
  if [[ "$provider" == "claude" ]]; then
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
  else
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
  fi

  if [[ "$provider" == "claude" ]]; then
    if ! echo "$launch_prompt" | claude -p --model "$CLAUDE_MODEL"; then
      echo "$launch_prompt" | claude -p
    fi
  else
    echo "$launch_prompt" | copilot
  fi

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
  provider="$(main_provider)"

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
  provider="$(worker_provider)"

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

  if [[ "$provider" == "claude" ]]; then
    if ! echo "$fix_prompt" | claude -p --model "$CLAUDE_MODEL"; then
      echo "$fix_prompt" | claude -p
    fi
  else
    echo "$fix_prompt" | copilot
  fi

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
}

# ── cmd: open — FIX #12 ───────────────────────────────────────────────────────

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

# ── cmd: help ─────────────────────────────────────────────────────────────────

cmd_help() {
  echo -e "${BOLD}COMMANDS${RESET}\n"
  echo -e "  ${CYAN}devloop install${RESET}"
  echo -e "    Install devloop to /usr/local/bin (run once)\n"
  echo -e "  ${CYAN}devloop init${RESET}"
  echo -e "    Set up DevLoop in current project. Re-run after editing devloop.config.sh"
  echo -e "    Writes: agents, CLAUDE.md, devloop.config.sh, copilot-instructions\n"
  echo -e "  ${CYAN}devloop start [project-name]${RESET}  ${GRAY}alias: s${RESET}"
  echo -e "    Launch Claude with remote control + orchestrator agent"
  echo -e "    Prevents Mac sleep via caffeinate for session duration\n"
  echo -e "  ${CYAN}devloop daemon [project-name]${RESET}  ${GRAY}alias: d${RESET}"
  echo -e "    Run in background with auto-restart + sleep prevention"
  echo -e "    Registers launchd (macOS) or systemd (Linux) for auto-start on login"
  echo -e "    Sub-commands: stop | status | log | uninstall\n"
  echo -e "  ${CYAN}devloop architect \"feature\" [type] [files]${RESET}  ${GRAY}alias: a${RESET}"
  echo -e "    Claude designs an implementation spec (called by orchestrator)\n"
  echo -e "  ${CYAN}devloop work [TASK-ID]${RESET}  ${GRAY}alias: w${RESET}"
  echo -e "    Launch Copilot CLI to implement the full spec\n"
  echo -e "  ${CYAN}devloop review [TASK-ID]${RESET}  ${GRAY}alias: r${RESET}"
  echo -e "    Claude reviews git diff → APPROVED / NEEDS_WORK / REJECTED\n"
  echo -e "  ${CYAN}devloop fix [TASK-ID]${RESET}  ${GRAY}alias: f${RESET}"
  echo -e "    Launch Copilot with Claude's fix instructions\n"
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
  echo -e "  ${CYAN}devloop update${RESET}"
  echo -e "    Self-upgrade devloop (requires DEVLOOP_SOURCE_URL in devloop.config.sh)\n"
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
