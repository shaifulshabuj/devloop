# DevLoop — End-to-End Usage Guide

Five complete walkthroughs from zero to approved implementation.

---

## Scenario 1 — New Project, Default Setup (Claude + Copilot)

The most common starting point. Claude designs specs and reviews code; Copilot implements.

### Prerequisites
```bash
# Install the required CLIs
curl -fsSL https://claude.ai/install.sh | bash          # Claude Code CLI
npm install -g @github/copilot                           # Copilot CLI
brew install git                                         # Git

# Install DevLoop globally
curl -fsSL https://raw.githubusercontent.com/your-org/devloop/main/devloop.sh \
  -o /tmp/devloop && chmod +x /tmp/devloop && sudo mv /tmp/devloop /usr/local/bin/devloop
```

### Step 1 — Initialize the project
```bash
cd ~/projects/my-api
devloop init
```

Output:
```
✔  Created: devloop.config.sh
✔  Auto-configured: devloop.config.sh (updated N values from project analysis)
✔  Created: CLAUDE.md
✔  Created: .github/copilot-instructions.md
✔  Created: .claude/agents/devloop-orchestrator.md
✔  Created: .claude/agents/devloop-architect.md
✔  Created: .claude/agents/devloop-reviewer.md
```

### Step 2 — Configure your stack
`devloop init` now auto-populates `devloop.config.sh` by analyzing your project files. Review and adjust if needed:
```bash
PROJECT_NAME="my-api"
PROJECT_STACK="Python, FastAPI, PostgreSQL"
PROJECT_PATTERNS="SOLID, Repository Pattern, Clean Architecture"
PROJECT_CONVENTIONS="type hints everywhere, custom exceptions, no magic strings"
TEST_FRAMEWORK="pytest"
DEVLOOP_MAIN_PROVIDER="claude"    # architect + reviewer
DEVLOOP_WORKER_PROVIDER="copilot" # implementer
CLAUDE_MODEL="sonnet"
```

### Step 3 — Validate your setup
```bash
devloop doctor
```
Expected output:
```
✔  claude      authenticated
✔  copilot     authenticated
✔  git         configured
✔  agents      3 files present
✔  config      devloop.config.sh loaded
```

### Step 4 — Design a spec
```bash
devloop architect "add GET /orders endpoint with date range filter"
```

Claude designs a full spec saved to `.devloop/specs/TASK-20260509-143022.md`.  
The **Copilot Instructions Block** is printed and saved to `.devloop/prompts/`.

### Step 5 — Implement
```bash
devloop work
# or with an explicit task ID:
devloop work TASK-20260509-143022
```

Copilot CLI launches with the full spec pre-loaded. It plans, implements, runs tests, stages all files, and commits.

### Step 6 — Review
```bash
devloop review
```

Claude diffs exactly what Copilot committed against the original spec and returns:
- `✅ APPROVED` → done
- `⚠️ NEEDS_WORK` → fix and re-review
- `❌ REJECTED` → redesign spec

### Step 7 — Fix (if needed)
```bash
devloop fix
devloop review   # re-review after fixes
```

Repeat until `APPROVED`.

### Step 8 — Capture lessons
```bash
devloop learn
```

Lessons are appended to `CLAUDE.md` and inform future sessions automatically.

### Step 9 — Clean up old specs
```bash
devloop clean --dry-run     # preview
devloop clean --days 30     # remove approved specs older than 30 days
```

---

## Scenario 2 — Existing Project, Mobile-First (Remote Control via Phone)

Work on an existing codebase entirely from your phone while your Mac runs headlessly.

### Step 1 — Install DevLoop into the existing project
```bash
cd ~/projects/existing-app
devloop init
```
Existing files are merged safely: DevLoop updates its own managed blocks and appends missing config keys while preserving custom content.

Configure your actual stack in `devloop.config.sh`.

### Step 2 — Install pipeline hooks (optional but recommended)
```bash
devloop hooks
```

Hooks give you real-time visibility into what Claude is doing without polling.

### Step 3 — Start the daemon (background, survives terminal close)
```bash
devloop daemon
```

Output:
```
✔  DevLoop daemon started (PID 9182)
✔  launchd agent registered → auto-starts on login
   Connect from: Claude app → "DevLoop: existing-app" (green dot)
   Logs: devloop daemon log
```

You can now **close the terminal**. The session keeps running.

### Step 4 — Connect from your phone
1. Open the **Claude app** on your iPhone/Android
2. Look for **"DevLoop: existing-app"** with a 🟢 green dot
3. Type your request:

```
Add input validation to the user registration endpoint.
Reject if email format is invalid or password < 8 chars.
Return 422 with field-specific error messages.
```

### Step 5 — Watch it happen automatically
The orchestrator agent picks up your request and runs the full loop:
```
📐 Designing spec... (Claude architect)
🤖 Implementing... (Copilot worker)
🔍 Reviewing... (Claude reviewer)
✅ APPROVED — 3 files changed, 12 tests added
```

All from your phone, zero terminal interaction required.

### Step 6 — Check status any time
From your phone (still in the Claude session):
```
run: devloop tasks
```

Or from terminal:
```bash
devloop tasks
# ✅ TASK-20260509-150022   user registration validation   ✅ approved
```

### Step 7 — Stop the daemon when done
```bash
devloop daemon stop
# To remove auto-start on login:
devloop daemon uninstall
```

### Step 8 — View logs from the session
```bash
devloop logs pipeline        # all architect/work/review events
devloop logs notifications   # Claude notifications
devloop logs sessions        # session start/end history
```

---

## Scenario 3 — All-Claude Mode (No Copilot Required)

Use Claude as both the main (architect/reviewer) and worker (implementer). Ideal when you don't have Copilot access or want a uniform Claude-only workflow.

### Step 1 — Configure all-Claude routing
In `devloop.config.sh`:
```bash
DEVLOOP_MAIN_PROVIDER="claude"
DEVLOOP_WORKER_PROVIDER="claude"
CLAUDE_MODEL="sonnet"   # "opus" for more complex tasks
```

### Step 2 — Reinitialize agents
```bash
devloop init
```

Agent files are regenerated to reflect the new worker routing.

### Step 3 — Design and implement
```bash
# Design a spec (Claude main)
devloop architect "extract payment processing into a separate PaymentService" refactor

# Implement (Claude worker — uses claude -p in headless mode)
devloop work

# Review (Claude main reviews Claude worker's output)
devloop review
```

### Step 4 — Fix if needed
```bash
devloop fix      # Claude worker applies fix instructions from Claude reviewer
devloop review   # re-review
```

### Step 5 — Full remote loop in all-Claude mode
You can still use `devloop start` or `devloop daemon` — the orchestrator (Claude Code session) delegates to Claude-as-worker via `claude -p`, so the remote control session remains intact and you can send requests from your phone exactly as in Scenario 2.

**Trade-offs:**
| | All-Claude | Claude + Copilot |
|--|-----------|------------------|
| Cost | Higher | Balanced |
| Consistency | High (same model) | Mixed |
| Copilot required | No | Yes |
| Speed | Same | Similar |

---

## Scenario 4 — Copilot Main + Claude/OpenCode Workers

Swap the default roles: Copilot orchestrates and designs specs, while Claude or OpenCode implements. Useful when your Claude usage is limited but Copilot subscription has headroom.

### Step 1 — Configure reverse routing
In `devloop.config.sh`:
```bash
DEVLOOP_MAIN_PROVIDER="copilot"    # orchestrator, architect, reviewer
DEVLOOP_WORKER_PROVIDER="claude"   # implementer (or "opencode" / "pi")
```

### Step 2 — Reinitialize
```bash
devloop init
```

### Step 3 — Start the session
```bash
devloop start
# → Copilot CLI launches as the remote-control session
# → Connect from the Copilot interface
```

### Step 4 — Use the same commands
```bash
devloop architect "add rate limiting middleware"   # Copilot designs the spec
devloop work                                       # Claude implements
devloop review                                     # Copilot reviews
devloop fix                                        # Claude applies fixes
```

### Step 5 — Try OpenCode or Pi as workers
For lightweight tasks, route the worker to OpenCode or Pi:
```bash
# In devloop.config.sh:
DEVLOOP_MAIN_PROVIDER="claude"
DEVLOOP_WORKER_PROVIDER="opencode"   # or "pi"

# Install OpenCode if needed:
npm install -g opencode-ai
```

```bash
devloop work    # OpenCode implements from the spec file
devloop review  # Claude reviews OpenCode's output
```

**All supported combinations:**

| Main | Worker | Use case |
|------|--------|----------|
| `claude` | `copilot` | Default — best balance |
| `claude` | `claude` | No Copilot, uniform Claude |
| `copilot` | `copilot` | No Claude, uniform Copilot |
| `copilot` | `claude` | Copilot quota heavy, Claude implementation |
| `claude` | `opencode` | Lightweight worker for smaller tasks |
| `claude` | `pi` | Minimal footprint worker |

---

## Scenario 5 — Smart Provider Failover (Automatic Limit Handling)

DevLoop automatically switches providers when a rate limit is hit and restores the original provider the moment it's available again — without stopping mid-task.

### How it works
```
Claude hits limit mid-session
        ↓
DevLoop detects rate-limit error in output
        ↓
Saves health state to .devloop/provider-health.sh
        ↓
Switches main → Copilot (or worker → opencode → pi)
        ↓
Continues the task with the fallback provider
        ↓
Every 5 minutes (on next command): probes Claude
        ↓
Claude responds OK → restored immediately, no wait
```

### Step 1 — Enable failover (it's on by default)
In `devloop.config.sh`:
```bash
DEVLOOP_FAILOVER_ENABLED="true"
DEVLOOP_PROBE_INTERVAL="5"   # minutes between availability probes
```

### Step 2 — Run normally — failover is invisible
```bash
devloop start
```

If Claude hits its usage limit mid-session:
```
⚠  Claude hit its limit — switching main to Copilot
ℹ  Completed via fallback provider: Copilot
ℹ  Original provider Claude will be re-tested every 5m
```

The loop continues without interruption.

### Step 3 — Check failover status
```bash
devloop failover status
```

Output when failover is active:
```
🔄 Provider Failover Status
────────────────────────────────────────────
  Failover enabled: true
  Probe interval:   every 5m

  Main provider
    Configured: Claude
    ⚠️  Limited! Switched to: Copilot (12m ago)
    Last probed: 3m ago | Next probe in: ~2m

  Worker provider
    Configured: Copilot
    ✔  Healthy — active: Copilot
────────────────────────────────────────────
```

### Step 4 — Watch automatic recovery
When you run the next command (e.g., `devloop work`) and 5+ minutes have passed:
```
ℹ  Probing Claude for availability...
✔  Claude is available — restoring as main provider
```

No intervention needed. Claude resumes its main role.

### Step 5 — Manual failover controls
Force a provider override or reset manually:
```bash
# Check status
devloop failover status

# Test providers right now (without running a real task)
devloop failover probe

# Force manual override (e.g., you know Claude is limited)
devloop failover main copilot

# Restore manually (don't wait for probe)
devloop failover main clear

# Reset everything to configured defaults
devloop failover reset
```

### Step 6 — Worker failover cascade
If the worker provider also hits a limit, DevLoop cascades:
```
Copilot worker → hit limit → switch to OpenCode
OpenCode → hit limit → switch to Pi
Pi → hit limit → error (all providers exhausted)
```

Each level is probed independently and restored when available.

### Step 7 — Disable failover
If you prefer a hard stop rather than automatic switching:
```bash
# In devloop.config.sh:
DEVLOOP_FAILOVER_ENABLED="false"
```

---

## Quick Reference

```bash
# Project setup
devloop init                          # set up in current project
devloop doctor                        # validate all dependencies
devloop agent-sync                    # refresh provider docs + version check

# Core loop
devloop architect "feature desc"      # design spec (main provider)
devloop work [TASK-ID]                # implement (worker provider)
devloop review [TASK-ID]              # review diff (main provider)
devloop fix [TASK-ID]                 # apply fixes (worker provider)
devloop learn [TASK-ID]               # extract lessons → CLAUDE.md

# Session management
devloop start [name]                  # foreground session with remote control
devloop daemon [name]                 # background daemon (close terminal safely)
devloop daemon stop|status|log        # manage daemon

# Provider failover
devloop failover status               # show current health
devloop failover reset                # clear all overrides
devloop failover probe                # test providers now
devloop failover main <p|clear>       # force main override
devloop failover worker <p|clear>     # force worker override

# Task management
devloop tasks                         # list all tasks with status
devloop status [TASK-ID]              # full spec + latest review
devloop open [TASK-ID]                # open spec in $EDITOR
devloop block [TASK-ID]               # print Copilot Instructions Block
devloop clean [--days N] [--dry-run]  # remove old finalized specs

# Tooling
devloop hooks                         # install Claude pipeline hooks
devloop logs [pipeline|notifications] # view session logs
devloop tools audit                   # MCP servers + skills inventory
devloop tools suggest                 # stack-based tool recommendations
devloop ci                            # generate GitHub Actions review workflow
devloop update                        # self-upgrade devloop script
```
