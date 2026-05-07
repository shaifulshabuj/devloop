# 🔁 DevLoop

**Claude Code (Architect + Reviewer) + GitHub Copilot CLI (Worker) — remote-controllable dev pipeline**

A single shell script that wires Claude Code and Copilot CLI into a fully automated development loop. Design specs, implement features, and review code — all from your phone or browser while everything runs on your Mac.

```
You (mobile / browser — remotely)
         ↓ "add order filtering by date range"
Claude Code --remote-control (your Mac)
         ↓
  @devloop-architect  → designs precise implementation spec
         ↓
  copilot CLI         → implements with /plan mode (full spec)
         ↓
  @devloop-reviewer   → reviews git diff against spec
         ↓
  APPROVED ✅  or  loop back for fixes ⚠️
```

---

## Architecture Diagrams

Detailed Mermaid diagrams covering every aspect of the pipeline, file lifecycle, agent collaboration, daemon behaviour, and data flow:

📊 **[DEVLOOP-GRAPH.md](./DEVLOOP-GRAPH.md)**

| Diagram | Description |
|---------|-------------|
| 1. Full Pipeline | End-to-end flow from user request to APPROVED |
| 2. Command Reference | Every command grouped by category with aliases |
| 3. `devloop init` | All files created and CLAUDE_MODEL propagation |
| 4. File Lifecycle | All 4 files per task — who writes, reads, and deletes each |
| 5. Git Baseline | How `.pre-commit` enables precise multi-commit diffs |
| 6. `devloop work` prompt | Exact structure sent to Copilot |
| 7. `devloop review` prompt | Diff computation, compact spec assembly, Claude prompt |
| 8. Daemon & Auto-restart | Background loop, backoff, launchd/systemd registration |
| 9. Status State Machine | `pending → approved/needs_work/rejected` transitions |
| 10. Agent Collaboration | Orchestrator ↔ Architect ↔ Reviewer ↔ Copilot roles |
| 11. `devloop clean` | File selection logic and dry-run path |

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
curl -fsSL https://raw.githubusercontent.com/you/devloop/main/devloop.sh -o devloop.sh

# Make executable and install globally
chmod +x devloop.sh
sudo mv devloop.sh /usr/local/bin/devloop

# Verify
devloop --version
```

Or use the built-in `install` command if you already have the file:
```bash
devloop install              # installs to /usr/local/bin/devloop
devloop install ~/bin/devloop  # custom path
```

Enable self-updates by setting in `devloop.config.sh`:
```bash
DEVLOOP_SOURCE_URL="https://raw.githubusercontent.com/you/devloop/main/devloop.sh"
```
Then run `devloop update` to upgrade in place.

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
| `.github/copilot-instructions.md` | Persistent instructions for Copilot (includes stack, patterns, commit format) |
| `.claude/agents/devloop-orchestrator.md` | Main agent — coordinates the loop |
| `.claude/agents/devloop-architect.md` | Subagent — designs specs |
| `.claude/agents/devloop-reviewer.md` | Subagent — reviews implementation |
| `.devloop/specs/` | Where task specs and reviews are saved |
| `.devloop/prompts/` | Extracted Copilot instruction blocks |

Running `devloop init` again is safe — existing files are skipped, so your customizations are preserved.

**After init, edit `devloop.config.sh`:**
```bash
PROJECT_NAME="MyProject"
PROJECT_STACK="Python, Flask, PostgreSQL"
PROJECT_PATTERNS="SOLID, Repository Pattern, Clean Architecture"
PROJECT_CONVENTIONS="type hints everywhere, custom exceptions, no magic strings"
TEST_FRAMEWORK="pytest"
CLAUDE_MODEL="sonnet"   # or "opus" for more capable architect/reviewer
```

Agent `.md` files in `.claude/agents/` are regenerated automatically to stay in sync with `CLAUDE_MODEL` whenever you run `devloop init`.

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

---

### `devloop daemon [project-name]`  · alias: `d`
Runs DevLoop in the **background** with auto-restart and sleep prevention. Best for long sessions or when you want to close the terminal.

```bash
devloop daemon              # start in background
devloop daemon status       # check if running + last 10 log lines
devloop daemon log          # tail live logs
devloop daemon stop         # stop the daemon
devloop daemon uninstall    # remove auto-start entry (launchd or systemd)
```

**What daemon does differently from `start`:**
- Runs the Claude session in a background process — you can close the terminal
- **Auto-restarts** if Claude crashes or the connection drops
- Uses exponential backoff between restarts (5s → 10s → ... → 60s max, 20 retries)
- Restarts `caffeinate -is` fresh on each attempt — survives wake from sleep
- **macOS**: Registers a launchd agent so DevLoop starts automatically on login
- **Linux**: Registers a systemd user service so DevLoop starts automatically on login
- Logs everything to `.devloop/daemon.log`

**Recommended for Mac mini (always-on):**
```bash
devloop daemon        # start once, close terminal
# work from phone all day
devloop daemon stop   # done for the day
```

**Logs:**
```
.devloop/daemon.log              ← session events + restart history
.devloop/launchd.log             ← stdout from launchd-managed process (macOS)
.devloop/launchd-error.log       ← stderr from launchd-managed process (macOS)
```

**macOS launchd agent** (`~/Library/LaunchAgents/com.devloop.projectname.plist`):
- `RunAtLoad: true` — starts when you log in
- `KeepAlive: true` — macOS restarts it if it crashes
- `ProcessType: Interactive` — hints to macOS not to aggressively suspend it
- Remove with: `devloop daemon uninstall`

**Linux systemd user service** (`~/.config/systemd/user/devloop-projectname.service`):
- `WantedBy: default.target` — starts on user login
- `Restart: on-failure` — systemd restarts on crash
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
- Full spec in `.devloop/specs/TASK-YYYYMMDD-HHMMSS.md` (seconds precision — no same-minute collisions)
- Copilot Instructions Block printed to terminal and saved to `.devloop/prompts/`
- Task ID for use in subsequent commands

> Normally called automatically by the orchestrator agent. Run manually to design a spec without starting a full session.

---

### `devloop work [TASK-ID]`  · alias: `w`
Launches Copilot CLI with the **full task spec** pre-loaded in `/plan` mode.

```bash
devloop work                        # uses latest task
devloop work TASK-20260504-093022
```

- Validates spec completeness before launching (checks for `## Copilot Instructions Block` section)
- Records a **git baseline** (current HEAD) to `.devloop/specs/TASK-ID.pre-commit` so `devloop review` can diff exactly what Copilot changed
- Prepends **live runtime context** (stack, patterns, conventions, test framework) from `devloop.config.sh` — always up to date even on re-runs
- Prints the runtime context to terminal for visibility

---

### `devloop review [TASK-ID]`  · alias: `r`
Claude reviews Copilot's implementation against the original spec using `git diff`.

```bash
devloop review
devloop review TASK-20260504-093022
```

**How the diff is computed:**
- Uses the git baseline saved by `devloop work` (`TASK-ID.pre-commit`) to diff exactly what Copilot added — even across multiple commits
- Falls back to uncommitted `git diff` / `git diff --cached` if no baseline exists

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
devloop fix TASK-20260504-093022
```

- Extracts fix instructions from the review (handles fenced code blocks with or without language tags)
- **Updates the git baseline** after Copilot commits so the next `devloop review` diffs only the new changes

Run `devloop review` again after Copilot fixes. Repeat until `APPROVED`.

---

### `devloop tasks`  · alias: `t`
Lists all task specs with status icons.

```bash
devloop tasks

# Output:
# ✅ TASK-20260504-093022   add order filtering by date range   ✅ approved
# ⚠️  TASK-20260503-141530   paginate product listing            ⚠️ needs-work
# ⏳ TASK-20260503-110045   add auth middleware                  pending
```

---

### `devloop status [TASK-ID]`
Shows the full spec and latest review for a task.

```bash
devloop status                          # latest task
devloop status TASK-20260504-093022
```

---

### `devloop open [TASK-ID]`  · alias: `o`
Opens the task spec in `$EDITOR` (falls back to `vi`).

```bash
devloop open                            # latest task
devloop open TASK-20260504-093022
```

---

### `devloop block [TASK-ID]`  · alias: `b`
Prints the Copilot Instructions Block from a spec — useful for manually pasting into Copilot chat.

```bash
devloop block                           # latest task
devloop block TASK-20260504-093022
```

---

### `devloop clean [--days N] [--dry-run]`
Removes finalized specs (approved/rejected) older than N days. Pending and needs-work tasks are **always preserved**.

```bash
devloop clean                   # remove approved/rejected specs older than 30 days
devloop clean --days 7          # use 7-day threshold
devloop clean --dry-run         # preview what would be removed, no changes made
```

Also removes associated files per task: review `.md`, `.pre-commit` baseline, and `-copilot.txt` prompt.

---

### `devloop update`
Self-upgrades devloop by downloading from `DEVLOOP_SOURCE_URL`.

```bash
# Set in devloop.config.sh:
DEVLOOP_SOURCE_URL="https://raw.githubusercontent.com/you/devloop/main/devloop.sh"

# Then run:
devloop update
```

Shows a diff of what changed before applying. Backs up the current binary to `devloop.sh.bak`. Exits with an error (and instructions) if `DEVLOOP_SOURCE_URL` is not configured.

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
#    devloop work TASK-20260504-103022

# 🔍 Reviewing...
#    @devloop-reviewer is checking the git diff

# ✅ Approved!
#    Added GetOrdersPaged() with page/pageSize params and pytest tests.
#    3 files modified: routes.py, repository.py, tests/test_orders.py
```

---

## File Structure

```
your-project/
├── devloop.config.sh                        ← edit this with your stack
├── CLAUDE.md                                ← Claude Code persistent context
├── .github/
│   └── copilot-instructions.md              ← Copilot persistent context (stack + commit format)
├── .claude/
│   └── agents/
│       ├── devloop-orchestrator.md          ← main agent (written by init)
│       ├── devloop-architect.md             ← subagent (written by init)
│       └── devloop-reviewer.md              ← subagent (written by init)
└── .devloop/
    ├── daemon.pid                           ← daemon process ID
    ├── daemon.log                           ← restart history + events
    ├── specs/
    │   ├── TASK-20260504-093022.md          ← full spec
    │   ├── TASK-20260504-093022.pre-commit  ← git baseline for review diff
    │   ├── TASK-20260504-093022-review.md   ← Claude's review
    │   └── ...
    └── prompts/
        ├── TASK-20260504-093022-copilot.txt ← extracted Copilot block
        └── ...
```

---

## Agent Model Routing

Each agent uses a configurable model to balance quality and quota usage:

| Agent | Default Model | Reason |
|-------|---------------|--------|
| `devloop-orchestrator` | `sonnet` | Just coordination — no heavy reasoning needed |
| `devloop-architect` | `CLAUDE_MODEL` | Complex spec design — worth the stronger model |
| `devloop-reviewer` | `CLAUDE_MODEL` | Structured review output |

Set `CLAUDE_MODEL` in `devloop.config.sh`:
```bash
CLAUDE_MODEL="opus"    # used by architect + reviewer; sonnet is the default
```

Agent `.md` files are regenerated on `devloop init` to stay in sync with this setting. Edit `.claude/agents/*.md` directly for per-agent overrides.

---

## Sleep & Connectivity Issues (Mac mini / Linux server)

| Problem | Solution |
|---------|----------|
| Mac sleeps → session drops | `devloop daemon` uses `caffeinate -is` |
| Terminal closed → session dies | `devloop daemon` runs in background |
| Mac reboots → session gone | `devloop daemon` registers launchd agent |
| Linux reboots → session gone | `devloop daemon` registers systemd user service |
| Crash loop | Exponential backoff (5s→60s), stops after 20 restarts |
| Check what happened | `devloop daemon log` |
| Start fresh | `devloop daemon stop && devloop daemon` |
| Remove auto-start | `devloop daemon uninstall` |

**Mac mini tip:** System Preferences → Battery → Prevent automatic sleeping is also recommended for always-on use.

---

## Tips

**Model cost control:**
Use `CLAUDE_MODEL="sonnet"` in `devloop.config.sh` for routine features. Switch to `opus` only for complex architecture tasks.

**Multiple projects:**
Each project gets its own daemon with its own launchd/systemd entry. Run `devloop daemon` in each project directory.

**Refresh Copilot instructions after config changes:**
```bash
rm .github/copilot-instructions.md
devloop init
```

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
# keep: .devloop/prompts/
```

**Open a spec quickly:**
```bash
devloop open          # opens latest spec in $EDITOR
devloop block         # print just the Copilot Instructions Block
```

**Preview before cleaning:**
```bash
devloop clean --days 14 --dry-run   # see what would be removed
devloop clean --days 14             # apply
```

**Understand the full data flow:**
See [DEVLOOP-GRAPH.md](./DEVLOOP-GRAPH.md) for 11 Mermaid diagrams covering the pipeline, file lifecycle, git baseline mechanism, agent collaboration, daemon behaviour, and every command in detail.