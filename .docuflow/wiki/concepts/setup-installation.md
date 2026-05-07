---
title: "Setup & Installation"
category: concept
tags: [setup, installation, prerequisites, quickstart, init]
created: 2026-05-06
---

# Setup & Installation

This guide covers everything from installing the prerequisites to sending your first remote feature request.

---

## Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| `claude` | Claude Code CLI — runs the agent pipeline | `curl -fsSL https://claude.ai/install.sh \| bash` |
| `copilot` | GitHub Copilot CLI — implements specs | `gh extension install github/gh-copilot` |
| `git` | Version control — reviewer reads git diff | https://git-scm.com |

DevLoop checks for all three at startup and prints install instructions for any that are missing.

### Verify prerequisites

```bash
claude --version
gh copilot --version
git --version
```

---

## Step 1 — Install DevLoop

### Option A: Download and install in one step

```bash
curl -fsSL https://raw.githubusercontent.com/shaifulshabuj/devloop/main/devloop.sh \
  -o /tmp/devloop.sh \
  && chmod +x /tmp/devloop.sh \
  && sudo mv /tmp/devloop.sh /usr/local/bin/devloop
```

### Option B: Install from a local copy

```bash
chmod +x devloop.sh
devloop.sh install            # installs to /usr/local/bin/devloop
# or
devloop.sh install ~/bin/devloop   # custom path
```

### Verify

```bash
devloop --version
# DevLoop v3.1.0
```

---

## Step 2 — Initialize a project

Run `devloop init` once in each project where you want to use DevLoop.

```bash
cd your-project/
devloop init
```

This creates:

```
your-project/
├── devloop.config.sh
├── CLAUDE.md
├── .github/
│   └── copilot-instructions.md
└── .claude/
    └── agents/
        ├── devloop-orchestrator.md
        ├── devloop-architect.md
        └── devloop-reviewer.md
```

Files that already exist are skipped (not overwritten).

---

## Step 3 — Configure your stack

Edit `devloop.config.sh` to match your actual project:

```bash
PROJECT_NAME="MyProject"
PROJECT_STACK="TypeScript, Node.js 20, Express, PostgreSQL"
PROJECT_PATTERNS="SOLID, Repository Pattern"
PROJECT_CONVENTIONS="async/await throughout, Result<T> returns, JSDoc on exports"
TEST_FRAMEWORK="Jest"
CLAUDE_MODEL="sonnet"

# Provider routing (optional — defaults shown)
DEVLOOP_MAIN_PROVIDER="claude"
DEVLOOP_WORKER_PROVIDER="copilot"
DEVLOOP_WORKER_MODE="cli"

# Self-improvement (optional)
DEVLOOP_VERSION_URL="https://raw.githubusercontent.com/shaifulshabuj/devloop/main/VERSION"
```

This file is injected into every architect and reviewer prompt. See [Configuration Reference](configuration.md) for all options.

---

## Step 4 — Install hooks and get tool recommendations

```bash
# Install Claude Code pipeline hooks
devloop hooks

# Get stack-relevant MCP/skill/plugin recommendations
devloop tools suggest

# Install recommended tools interactively
devloop tools add
```

---

## Step 5 — Start a session

### Foreground (terminal stays open)

```bash
devloop start
```

Press Ctrl+C to stop. Mac sleep is prevented while the session runs.

### Background daemon (recommended for Mac mini / always-on)

```bash
devloop daemon
```

Close the terminal — the session keeps running. It auto-restarts on crash and registers a launchd agent so it survives reboots.

---

## Step 6 — Connect from your device

After starting, DevLoop prints connection info:

```
Connect from:
  📱 Claude app → find "DevLoop: MyProject" with green dot
  🌐 https://claude.ai/code → session list
```

Open the Claude app on your phone or https://claude.ai/code in your browser and find the session by name.

---

## Step 7 — Send your first feature request

Type a natural-language feature request in the chat:

```
add pagination to the GET /orders endpoint
```

The orchestrator responds with phase indicators as it runs:

```
📐 Designing spec...
   @devloop-architect is creating the implementation spec

🤖 Copilot implementing...
   devloop work TASK-20260506-1030

🔍 Reviewing...
   @devloop-reviewer is checking the git diff

✅ Approved!
   Added GetOrdersPaged() with page/pageSize params and xUnit tests.
   3 files modified: OrdersController.cs, IOrderRepository.cs, OrderRepository.cs
```

---

## Gitignore Setup

Add these entries to `.gitignore` to avoid committing ephemeral daemon files while keeping specs in version history:

```gitignore
# DevLoop — ignore runtime files, keep specs
.devloop/daemon.pid
.devloop/daemon.log
.devloop/launchd.log
.devloop/launchd-error.log
# .devloop/specs/ ← DO commit this
# .devloop/prompts/ ← optional
```

---

## macOS Sleep & Connectivity Notes

For always-on Mac mini setups:

| Problem | Solution |
|---------|----------|
| Mac sleeps → session drops | `devloop daemon` uses `caffeinate -is` |
| Terminal closed → session dies | `devloop daemon` runs in background |
| Mac reboots → session gone | `devloop daemon` registers launchd agent |
| Crash loop | Exponential backoff 5s→60s, stops after 20 restarts |
| Check what happened | `devloop daemon log` |
| Start fresh | `devloop daemon stop && devloop daemon` |

Also recommended: **System Settings → Battery → Prevent automatic sleeping when display is off**.

---

## Troubleshooting

### `devloop: command not found`

The script is not on your PATH. Run:

```bash
sudo devloop.sh install
```

or move it manually to `/usr/local/bin/devloop`.

### `claude: command not found`

Install Claude Code CLI:

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

### `copilot: command not found`

Install the GitHub Copilot CLI extension:

```bash
gh extension install github/gh-copilot
```

Requires `gh` (GitHub CLI) to be installed and authenticated.

### Agents missing error on `devloop start`

```
Error: Missing agent definitions: devloop-orchestrator devloop-architect devloop-reviewer
Run devloop init first
```

Run `devloop init` in the project directory.

### Session not appearing in Claude app

- Check that `devloop start` or `devloop daemon` is running (no error output)
- Ensure your Claude account is the same on both devices
- Check `devloop daemon status` if using daemon mode

### No git changes after `devloop work`

Copilot may not have finished or may have exited without committing. The reviewer will report "No git changes found." Options:
- Run `devloop work TASK-ID` again and supervise Copilot in the terminal
- Stage changes manually and run `devloop review TASK-ID`

---

## Uninstalling

```bash
# Stop and remove the daemon for this project
devloop daemon stop
devloop daemon uninstall

# Remove devloop itself
sudo rm /usr/local/bin/devloop

# Remove project files (optional)
rm -rf .devloop/ .claude/agents/devloop-*.md devloop.config.sh
```
