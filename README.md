# 🔁 DevLoop

**Claude Code (Architect) + GitHub Copilot CLI (Worker) — remote-controllable dev pipeline**

A single shell script that wires Claude Code and Copilot CLI into a fully automated development loop. Instruct from your phone or browser while everything runs on your Mac.

```
You (mobile / browser — remotely)
         ↓ "add order filtering by date range"
Claude Code --remote-control (your Mac)
         ↓
  @devloop-architect  → designs implementation spec
         ↓
  copilot CLI         → implements with /plan mode
         ↓
  @devloop-reviewer   → reviews git diff against spec
         ↓
  APPROVED ✅  or  loop back for fixes ⚠️
```

---

## Requirements

| Tool | Install |
|------|---------|
| `claude` | `curl -fsSL https://claude.ai/install.sh \| bash` |
| `copilot` | `gh extension install github/gh-copilot` |
| `git` | https://git-scm.com |

---

## Install

```bash
# Download
curl -fsSL https://your-host/devloop.sh -o devloop.sh

# Make executable and install globally
chmod +x devloop.sh
sudo mv devloop.sh /usr/local/bin/devloop

# Verify
devloop --version
```

Or use the `install` command if you already have the file:
```bash
devloop install            # installs to /usr/local/bin/devloop
devloop install ~/bin/devloop  # custom path
```

---

## Quick Start

```bash
cd your-project/

# 1. Initialize DevLoop (one-time per project)
devloop init

# 2. Edit your stack
nano devloop.config.sh

# 3. Start the session
devloop start
# → scan QR code or open claude.ai/code on your phone

# 4. From your phone, type:
#    "add GET /orders endpoint with date range filter"
#    → Claude designs spec, Copilot implements, Claude reviews — automatically
```

---

## Commands

### `devloop install [path]`
Copies the script to `/usr/local/bin/devloop` (or a custom path). Uses `sudo` if needed.

---

### `devloop init`
Sets up DevLoop in the current project. Run once per project.

**Creates:**
| File | Purpose |
|------|---------|
| `devloop.config.sh` | Your project stack, patterns, conventions |
| `CLAUDE.md` | Persistent instructions for Claude Code sessions |
| `.github/copilot-instructions.md` | Persistent instructions for Copilot |
| `.claude/agents/devloop-orchestrator.md` | Main agent — coordinates the loop |
| `.claude/agents/devloop-architect.md` | Subagent — designs specs |
| `.claude/agents/devloop-reviewer.md` | Subagent — reviews implementation |
| `.devloop/specs/` | Where task specs and reviews are saved |
| `.devloop/prompts/` | Extracted Copilot instruction blocks |

**After init, edit `devloop.config.sh`:**
```bash
PROJECT_NAME="MyProject"
PROJECT_STACK="C#, .NET 8, ASP.NET Web API, MSSQL"
PROJECT_PATTERNS="SOLID, Repository Pattern, Clean Architecture"
PROJECT_CONVENTIONS="async/await throughout, custom exceptions, no magic strings"
TEST_FRAMEWORK="xUnit"
CLAUDE_MODEL="sonnet"   # or "opus" for more capable architect/reviewer
```

---

### `devloop start [project-name]`  · alias: `s`
Launches Claude Code with remote control and the orchestrator agent.

- **Prevents Mac sleep** via `caffeinate -is` for the entire session duration
- Sleep prevention is stopped automatically when you press Ctrl+C

```bash
devloop start
devloop start "Avail OMS"   # custom session name
```

**Connect from:**
- 📱 Claude app → look for `"DevLoop: project-name"` with a green dot
- 🌐 https://claude.ai/code → session list

**What runs under the hood:**
```bash
caffeinate -is &   # prevent sleep
claude \
  --remote-control "DevLoop: project-name" \
  --agent devloop-orchestrator \
  --permission-mode acceptEdits
```

---

### `devloop daemon [project-name]`  · alias: `d`
Runs DevLoop in the **background** with auto-restart and sleep prevention. Best for long sessions or when you want to close the terminal.

```bash
devloop daemon              # start in background
devloop daemon status       # check if running + last 10 log lines
devloop daemon log          # tail live logs
devloop daemon stop         # stop the daemon
devloop daemon uninstall    # remove launchd entry
```

**What daemon does differently from `start`:**
- Runs the Claude session in a background process — you can close the terminal
- **Auto-restarts** if Claude crashes or the connection drops
- Uses exponential backoff between restarts (5s → 10s → ... → 60s max)
- Restarts `caffeinate -is` fresh on each attempt — survives wake from sleep
- **Registers a macOS launchd agent** so DevLoop starts automatically after reboot or login
- Logs everything to `.devloop/daemon.log`

**Recommended for Mac mini (always-on):**
```bash
devloop daemon        # start once, close terminal
# work from phone all day
devloop daemon stop   # done for the day
```

**Logs:**
```
.devloop/daemon.log         ← session events + restart history
.devloop/launchd.log        ← stdout from launchd-managed process
.devloop/launchd-error.log  ← stderr from launchd-managed process
```

**launchd agent** (`~/Library/LaunchAgents/com.devloop.projectname.plist`):
- `RunAtLoad: true` — starts when you log in
- `KeepAlive: true` — macOS restarts it if it crashes
- `ProcessType: Interactive` — hints to macOS not to aggressively suspend it
- Remove with: `devloop daemon uninstall`

---

### `devloop architect "feature" [type] [files]`  · alias: `a`
Claude designs a precise implementation spec for Copilot to follow.

```bash
devloop architect "add GET /orders endpoint with date range filter"
devloop architect "null ref in OrderService.GetActive()" bugfix "OrderService.cs"
devloop architect "extract IOrderRepository interface" refactor
```

Types: `feature` (default) | `bugfix` | `refactor` | `test`

**What it produces:**
- Full spec in `.devloop/specs/TASK-YYYYMMDD-HHMM.md`
- Copilot Instructions Block printed to terminal and saved to `.devloop/prompts/`
- Task ID for use in subsequent commands

> Normally called automatically by the orchestrator agent. Run manually to design a spec without starting a full session.

---

### `devloop work [TASK-ID]`  · alias: `w`
Launches Copilot CLI with the task spec pre-loaded in `/plan` mode.

```bash
devloop work                        # uses latest task
devloop work TASK-20260504-0930
```

Copilot reads the spec, creates an implementation plan, implements each step, runs tests if available, and summarizes what was done. You can supervise interactively in the terminal.

---

### `devloop review [TASK-ID]`  · alias: `r`
Claude reviews Copilot's implementation against the original spec using `git diff`.

```bash
devloop review
devloop review TASK-20260504-0930
```

**Reads:**
- Staged changes (`git diff --cached`)
- Unstaged changes (`git diff`)
- New untracked files

**Returns:**
| Verdict | Meaning |
|---------|---------|
| `✅ APPROVED` | Implementation matches spec, tests present |
| `⚠️ NEEDS_WORK` | Fixable issues — Copilot Instructions block provided |
| `❌ REJECTED` | Wrong approach or security issue — consider restarting |

Review is saved to `.devloop/specs/TASK-ID-review.md` and the spec status is updated.

---

### `devloop fix [TASK-ID]`  · alias: `f`
Launches Copilot CLI with Claude's fix instructions from the latest review.

```bash
devloop fix
devloop fix TASK-20260504-0930
```

Run `devloop review` again after Copilot fixes. Repeat until `APPROVED`.

---

### `devloop tasks`  · alias: `t`
Lists all task specs with status icons.

```bash
devloop tasks

# Output:
# ✅ TASK-20260504-0930   add order filtering by date range   ✅ approved
# ⚠️  TASK-20260503-1415   paginate product listing            ⚠️ needs-work
# ⏳ TASK-20260503-1100   add auth middleware                  pending
```

---

### `devloop status [TASK-ID]`
Shows the full spec and latest review for a task.

```bash
devloop status                      # latest task
devloop status TASK-20260504-0930
```

---

## The Full Remote Loop

```bash
# On your Mac (terminal):
devloop daemon            # start once, close terminal

# On your phone (Claude app):
# Find "DevLoop: MyProject" → open session

# Type:
"add pagination to the orders list endpoint"

# Claude orchestrator responds:
# 📐 Designing spec...
#    @devloop-architect is creating the implementation spec

# 🤖 Copilot implementing...
#    devloop work TASK-20260504-1030

# 🔍 Reviewing...
#    @devloop-reviewer is checking the git diff

# ✅ Approved!
#    Added GetOrdersPaged() with page/pageSize params and xUnit tests.
#    3 files modified: OrdersController.cs, IOrderRepository.cs, OrderRepository.cs
```

---

## File Structure

```
your-project/
├── devloop.config.sh                        ← edit this with your stack
├── CLAUDE.md                                ← Claude Code persistent context
├── .github/
│   └── copilot-instructions.md              ← Copilot persistent context
├── .claude/
│   └── agents/
│       ├── devloop-orchestrator.md          ← main agent (written by init)
│       ├── devloop-architect.md             ← subagent (written by init)
│       └── devloop-reviewer.md              ← subagent (written by init)
└── .devloop/
    ├── daemon.pid                           ← daemon process ID
    ├── daemon.log                           ← restart history + events
    ├── specs/
    │   ├── TASK-20260504-0930.md            ← full spec
    │   ├── TASK-20260504-0930-review.md     ← Claude's review
    │   └── ...
    └── prompts/
        ├── TASK-20260504-0930-copilot.txt   ← extracted Copilot block
        └── ...
```

---

## Agent Model Routing

Each agent uses a different model to balance quality and quota usage:

| Agent | Model | Reason |
|-------|-------|--------|
| `devloop-orchestrator` | `sonnet` | Just coordination — no heavy reasoning needed |
| `devloop-architect` | `opus` | Complex spec design — worth the stronger model |
| `devloop-reviewer` | `sonnet` | Structured output — sonnet handles this well |

Change in `devloop.config.sh`:
```bash
CLAUDE_MODEL="opus"    # used by architect/reviewer claude -p calls
```

Or edit the agent `.md` files directly in `.claude/agents/` to change per-agent models.

---

## Sleep & Connectivity Issues (Mac mini)

| Problem | Solution |
|---------|----------|
| Mac sleeps → session drops | `devloop daemon` uses `caffeinate -is` |
| Terminal closed → session dies | `devloop daemon` runs in background |
| Mac reboots → session gone | `devloop daemon` registers launchd agent |
| Crash loop | Exponential backoff (5s→60s), stops after 20 restarts |
| Check what happened | `devloop daemon log` |
| Start fresh | `devloop daemon stop && devloop daemon` |

**System Preferences → Battery → Prevent automatic sleeping** is also recommended for always-on Mac mini use.

---

## Tips

**Model cost control:**
Use `CLAUDE_MODEL="sonnet"` in `devloop.config.sh` for routine features. Switch to `opus` only for complex architecture tasks.

**Multiple projects:**
Each project gets its own daemon with its own launchd entry. Run `devloop daemon` in each project directory.

**VS Code integration** — add to `.vscode/tasks.json`:
```json
{
  "label": "DevLoop Review",
  "type": "shell",
  "command": "devloop review",
  "group": "build"
}
```

**Keep specs in git:**
Add `.devloop/specs/` to version control. Specs document every feature decision and review outcome.
```bash
# .gitignore
.devloop/daemon.pid
.devloop/daemon.log
.devloop/launchd*.log
# keep: .devloop/specs/
```