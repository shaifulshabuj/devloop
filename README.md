# 🔁 DevLoop

**Multi-agent AI development pipeline — remote-controllable, self-healing, provider-flexible**

A single shell script that orchestrates Claude Code, GitHub Copilot, OpenCode, and Pi into a fully automated design → implement → review loop. Configure which AI handles which role, start a remote session, and send feature requests from your phone.

```
You (mobile / browser — anywhere)
         ↓  "add order filtering by date range"
Main provider  (architect + reviewer: Claude or Copilot)
          ↓  precise implementation spec
Worker provider (implementer: Claude | Copilot | OpenCode | Pi)
          ↓  commit
Main provider  (reviews git diff vs spec)
         ↓
  APPROVED ✅  or  loop back for fixes ⚠️
         ↓  auto-failover if any provider hits its rate limit
```

📖 **[USAGE.md](./USAGE.md)** — Five complete end-to-end walkthroughs

📊 **[DEVLOOP-GRAPH.md](./DEVLOOP-GRAPH.md)** — 11 Mermaid architecture diagrams

---

## Requirements

| Tool | Role | Install |
|------|------|---------|
| `claude` | Main/worker CLI | `curl -fsSL https://claude.ai/install.sh \| bash` |
| `copilot` | Main/worker CLI | `npm install -g @github/copilot` |
| `opencode` | Worker only (optional) | `npm install -g opencode-ai` |
| `pi` | Worker only (optional) | https://pi.dev/docs/latest |
| `gh` | GitHub agent mode | `brew install gh` |
| `git` | Always required | https://git-scm.com |

---

## Install

```bash
# Download and install globally
curl -fsSL https://raw.githubusercontent.com/you/devloop/main/devloop.sh -o /tmp/devloop
chmod +x /tmp/devloop && sudo mv /tmp/devloop /usr/local/bin/devloop

# Or use the built-in installer if you already have the file:
devloop install              # → /usr/local/bin/devloop
devloop install ~/bin/devloop  # custom path

# Verify
devloop --version            # DevLoop v4.1.0
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

# 1. Initialize (one-time per project)
devloop init

# 2. Review auto-generated stack/config (optional adjustments)
nano devloop.config.sh

# 3. Validate everything is wired up
devloop doctor

# 4. Start the session
devloop start
# → find "DevLoop: your-project" in Claude app or claude.ai/code

# 5. From your phone:
#    "add GET /orders endpoint with date range filter"
#    → providers design, implement, and review automatically
```

→ Full walkthrough in [USAGE.md — Scenario 1](./USAGE.md#scenario-1--new-project-default-setup-claude--copilot)

---

## Architecture Diagrams

Detailed Mermaid diagrams covering every aspect of the pipeline:

📊 **[DEVLOOP-GRAPH.md](./DEVLOOP-GRAPH.md)**

| Diagram | Description |
|---------|-------------|
| 1. Full Pipeline | End-to-end flow from user request to APPROVED |
| 2. Command Reference | Every command grouped by category with aliases |
| 3. `devloop init` | All files created and provider/model propagation |
| 4. File Lifecycle | All 4 files per task — who writes, reads, and deletes each |
| 5. Git Baseline | How `.pre-commit` enables precise multi-commit diffs |
| 6. `devloop work` prompt | Exact structure sent to the worker provider |
| 7. `devloop review` prompt | Diff computation, compact spec assembly, main provider prompt |
| 8. Daemon & Auto-restart | Background loop, backoff, launchd/systemd registration |
| 9. Status State Machine | `pending → approved/needs_work/rejected` transitions |
| 10. Agent Collaboration | Orchestrator ↔ Architect ↔ Reviewer ↔ Worker roles |
| 11. `devloop clean` | File selection logic and dry-run path |

---

## Commands

### `devloop install [path]`
Copies the script to `/usr/local/bin/devloop` (or a custom path). Uses `sudo` if needed.

---

### `devloop init`
Sets up DevLoop in the current project. Run once per project (safe to re-run — existing files are merged/upserted).

**Creates:**
| File | Purpose |
|------|---------|
| `devloop.config.sh` | Your project stack, patterns, conventions |
| `CLAUDE.md` | Persistent instructions for Claude Code sessions |
| `.github/copilot-instructions.md` | Persistent instructions for Copilot |
| `.claude/agents/devloop-orchestrator.md` | Main agent — coordinates the loop |
| `.claude/agents/devloop-architect.md` | Subagent — designs specs |
| `.claude/agents/devloop-reviewer.md` | Subagent — reviews implementation |
| `.devloop/specs/` | Task specs and reviews |
| `.devloop/prompts/` | Extracted Copilot instruction blocks |

Running `devloop init` again is safe — existing files are merged: DevLoop-managed blocks are updated and missing config keys are appended, while custom content is preserved.

`devloop init` auto-populates stack/config values by analyzing the current project. Review and adjust as needed:
```bash
PROJECT_NAME="MyProject"
PROJECT_STACK="Python, FastAPI, PostgreSQL"
PROJECT_PATTERNS="SOLID, Repository Pattern, Clean Architecture"
PROJECT_CONVENTIONS="type hints everywhere, custom exceptions, no magic strings"
TEST_FRAMEWORK="pytest"
DEVLOOP_MAIN_PROVIDER="claude"    # claude | copilot
DEVLOOP_WORKER_PROVIDER="copilot" # claude | copilot | opencode | pi
CLAUDE_MODEL="sonnet"             # sonnet | opus
DEVLOOP_FAILOVER_ENABLED="true"   # auto-switch on rate limits
DEVLOOP_PROBE_INTERVAL="5"        # minutes between provider availability probes
```

---

### `devloop start [project-name]`  · alias: `s`
Launches the main provider session with remote control enabled.

- **Prevents Mac sleep** via `caffeinate -is` for the entire session
- Session name appears in Claude app / claude.ai/code for remote access

```bash
devloop start
devloop start "Avail OMS"   # custom session name
```

---

### `devloop daemon [project-name]`  · alias: `d`
Runs DevLoop in the **background** with auto-restart and sleep prevention.

```bash
devloop daemon              # start in background (close terminal safely)
devloop daemon status       # check if running + last 10 log lines
devloop daemon log          # tail live logs
devloop daemon stop         # stop the daemon
devloop daemon uninstall    # remove auto-start (launchd or systemd)
```

**What daemon does differently:**
- Runs in a background process — you can close the terminal
- **Auto-restarts** on crash with exponential backoff (5s → 60s max, 20 retries)
- **macOS**: Registers a launchd agent → starts on login automatically
- **Linux**: Registers a systemd user service → starts on login automatically

→ Walkthrough: [USAGE.md — Scenario 2](./USAGE.md#scenario-2--existing-project-mobile-first-remote-control-via-phone)

---

### `devloop architect "feature" [type] [files]`  · alias: `a`
The configured main provider designs a precise implementation spec.

```bash
devloop architect "add GET /orders endpoint with date range filter"
devloop architect "null ref in OrderService.GetActive()" bugfix "OrderService.cs"
devloop architect "extract IOrderRepository interface" refactor
```

Types: `feature` (default) | `bugfix` | `refactor` | `test`

**Produces:**
- Full spec in `.devloop/specs/TASK-YYYYMMDD-HHMMSS.md`
- Copilot Instructions Block printed to terminal and saved to `.devloop/prompts/`

---

### `devloop work [TASK-ID]`  · alias: `w`
Launches the configured worker provider with the **full task spec** pre-loaded.

```bash
devloop work                        # uses latest task
devloop work TASK-20260509-143022
```

- Records a **git baseline** so `devloop review` diffs exactly what changed
- Prepends live runtime context (stack, patterns, conventions, test framework)
- **Worker failover**: if the worker hits its limit, automatically cascades to the next in chain (copilot → opencode → pi)

#### Worker modes

| Mode | Behaviour |
|------|-----------|
| `cli` (default) | Runs the worker provider as a local CLI process |
| `github-agent` | Creates a GitHub Issue; Copilot coding agent opens a PR |

Set `DEVLOOP_WORKER_MODE` in `devloop.config.sh`.

---

### `devloop review [TASK-ID]`  · alias: `r`
The configured main provider reviews the implementation against the original spec using `git diff`.

```bash
devloop review
devloop review TASK-20260509-143022
```

**Verdicts:**
| Verdict | Meaning |
|---------|---------|
| `✅ APPROVED` | Implementation matches spec, tests present |
| `⚠️ NEEDS_WORK` | Fixable issues — fix instructions provided |
| `❌ REJECTED` | Wrong approach — consider redesigning spec |

### Review Verdict Parsing
- Canonical machine-readable line (preferred, deterministic): `Verdict: APPROVED|NEEDS_WORK|REJECTED`
- Reviewer output should put that canonical line as the **first non-empty line**.
- Parser tolerates fallback variants when canonical line is absent (examples: `### Verdict: NEEDS_WORK`, `**Verdict:** REJECTED`, lowercase/emoji variants like `Verdict: approved ✅`).
- If canonical `Verdict:` exists but value is invalid (example: `Verdict: HOLD`), result is `UNKNOWN` (no coercion).
- If parsing returns `UNKNOWN`, re-run review with a canonical first line:
  - `Verdict: APPROVED`
  - `Verdict: NEEDS_WORK`
  - `Verdict: REJECTED`

Review is saved to `.devloop/specs/TASK-ID-review.md`.

---

### `devloop fix [TASK-ID]`  · alias: `f`
Launches the configured worker provider with the reviewer's fix instructions.

```bash
devloop fix
devloop fix TASK-20260509-143022
```

Updates the git baseline after fixing, so the next `devloop review` diffs only the new changes.

---

### `devloop failover [subcmd]`
Manage automatic provider failover when rate limits hit.

```bash
devloop failover status                  # show current health + probe timing
devloop failover reset                   # clear all overrides, restore configured providers
devloop failover probe                   # test all providers right now
devloop failover main copilot            # force main to Copilot
devloop failover main clear              # restore configured main
devloop failover worker opencode         # force worker to OpenCode
devloop failover worker clear            # restore configured worker
```

**How auto-failover works:**
1. Every provider call captures output and checks for rate-limit patterns
2. On detection: saves health state, switches to next provider in chain, continues
3. On every subsequent command: probes the limited provider (at most every `DEVLOOP_PROBE_INTERVAL` minutes)
4. Restores the original provider the moment the probe succeeds — no fixed wait time

**Failover chains:**
- Main: `claude → copilot`
- Worker: `copilot → opencode → pi`

→ Walkthrough: [USAGE.md — Scenario 5](./USAGE.md#scenario-5--smart-provider-failover-automatic-limit-handling)

---

### `devloop agent-sync`  · aliases: `sync-agents`, `agentsync`
Fetches and caches the latest documentation for all configured providers (24h TTL), checks installed versions, and uses the main AI to analyse what's new.

```bash
devloop agent-sync
```

- Cached in `.devloop/agent-docs/` — read by Claude on every session
- Updates `CLAUDE.md` with provider-specific insights
- `devloop doctor` warns if docs are stale (>7 days)

---

### `devloop tasks`  · alias: `t`
Lists all task specs with status icons.

```bash
devloop tasks

# ✅ TASK-20260509-143022   add order filtering by date range   ✅ approved
# ⚠️  TASK-20260508-141530   paginate product listing            ⚠️ needs-work
# ⏳ TASK-20260508-110045   add auth middleware                  pending
```

---

### `devloop status [TASK-ID]`
Shows the full spec, latest review, and current provider health.

```bash
devloop status                          # latest task
devloop status TASK-20260509-143022
```

---

### `devloop open [TASK-ID]`  · alias: `o`
Opens the task spec in `$EDITOR`.

```bash
devloop open
devloop open TASK-20260509-143022
```

---

### `devloop block [TASK-ID]`  · alias: `b`
Prints the Copilot Instructions Block — useful for pasting into Copilot chat manually.

```bash
devloop block
devloop block TASK-20260509-143022
```

---

### `devloop clean [--days N] [--dry-run]`
Removes finalized specs (approved/rejected) older than N days. Pending and needs-work tasks are **always preserved**.

```bash
devloop clean                   # remove approved/rejected older than 30 days
devloop clean --days 7
devloop clean --dry-run         # preview — no changes made
```

---

### `devloop learn [TASK-ID]`
Extracts lessons from the latest review and appends them to `CLAUDE.md → ## Learned Patterns`. Claude reads these patterns in every future session — this is the self-improvement loop.

```bash
devloop learn
devloop learn TASK-20260509-143022
```

---

### `devloop check`
Checks for a newer DevLoop version against `DEVLOOP_VERSION_URL`.

```bash
# Set in devloop.config.sh:
DEVLOOP_VERSION_URL="https://raw.githubusercontent.com/you/devloop/main/VERSION"
devloop check
```

---

### `devloop hooks`
Installs Claude Code pipeline hooks into `.claude/settings.json`.

```bash
devloop hooks
```

| Hook event | Matcher | What it captures |
|------------|---------|-----------------|
| `PreToolUse` | Bash | 3-tier permission classification (BLOCK / ALLOW / ESCALATE) |
| `PostToolUse` | All | Audit log of every tool call → `.devloop/permissions.log` |
| `Stop` | — | Task summary when Claude finishes |
| `SubagentStop` | — | Which subagent completed + verdict keywords |
| `Notification` | — | All Claude notifications → `.devloop/notifications.log` |
| `SessionStart/End` | — | Session boundaries → `.devloop/sessions.log` |

**Smart permission tiers** (PreToolUse on Bash, applied in the interactive Claude session):

| Tier | Action | Examples |
|------|--------|---------|
| 🚫 BLOCK | Immediate deny | `rm -rf /`, `curl|bash`, `dd of=/dev/sda`, fork bombs |
| ✅ ALLOW | Auto-approve | `git *`, `cat/grep/find`, `pytest`, `npm test`, `make`, linters |
| ❓ ESCALATE | Ask user | Everything else — dialog → queue → auto-deny after timeout |

Worker providers (non-interactive pipe mode) are not affected by hooks. Instead, Claude worker calls use `--allowedTools` to scope allowed operations, and Copilot calls use `--allow-all-tools --allow-all-paths` which is required for non-interactive scripting.

---

### `devloop permit [subcmd]`
Inspect and manage the permission gate.

```bash
devloop permit status       # show current mode, pending requests, recent log
devloop permit watch        # live-poll pending requests (Linux headless)
devloop permit grant "CMD"  # manually approve a queued command
devloop permit deny "CMD"   # manually deny a queued command
devloop permit log          # show last 50 audit log entries
devloop permit mode smart   # smart (default) | auto | strict | off
```

**Permission modes:**
| Mode | Behaviour |
|------|-----------|
| `smart` | Block dangerous, allow known-safe, escalate unknown |
| `auto` | Allow everything (no interactive prompts — use carefully) |
| `strict` | Escalate everything except BLOCK list |
| `off` | Disable DevLoop permission hook entirely |

Set `DEVLOOP_PERMISSION_MODE` in `devloop.config.sh`. Set `DEVLOOP_PERMISSION_TIMEOUT` (default: 60s) for auto-deny timeout.

---

### `devloop logs [TYPE]`
Views DevLoop pipeline logs.

```bash
devloop logs                  # pipeline log
devloop logs notifications    # Claude notifications
devloop logs sessions         # session boundaries
```

---

### `devloop doctor`
Validates all dependencies and configuration.

```bash
devloop doctor
```

Checks: provider auth, git config, agent files, config file, version currency, stale agent docs.

---

### `devloop ci`
Generates `.github/workflows/devloop-review.yml` — a GitHub Actions workflow that triggers Claude to review PRs automatically.

Requires `ANTHROPIC_API_KEY` secret in the repository.

---

### `devloop tools [audit|suggest|add|sync]`
Manage MCP servers, cross-agent skills (Claude + Copilot), plugins, and Copilot path-specific instructions.

```bash
devloop tools audit    # global vs project tool inventory
devloop tools suggest  # stack-based recommendations
devloop tools add      # interactive install
devloop tools sync     # copy global tools to project level
```

```bash
# Non-interactive flags:
devloop tools add --mcp context7 npx -y @upstash/context7-mcp
devloop tools add --skill code-review "Thorough code review with security checks"
devloop tools add --instruction tests "**/*.test.ts,**/*.spec.ts"
devloop tools add --plugin playwright
```

---

### `devloop update`
Self-upgrades devloop from `DEVLOOP_SOURCE_URL`.

```bash
devloop update   # shows diff, backs up current binary, applies update
```

---

## Provider Routing & Auto-Failover

### Supported provider combinations

| Main | Worker | Use case |
|------|--------|----------|
| `claude` | `copilot` | Default — best balance |
| `claude` | `claude` | Uniform Claude, no Copilot needed |
| `copilot` | `copilot` | Uniform Copilot, no Claude needed |
| `copilot` | `claude` | Copilot orchestrates, Claude implements |
| `claude` | `opencode` | Lightweight worker for smaller tasks |
| `claude` | `pi` | Minimal footprint worker |

Set in `devloop.config.sh`:
```bash
DEVLOOP_MAIN_PROVIDER="claude"
DEVLOOP_WORKER_PROVIDER="copilot"
```

> **Note:** `opencode` and `pi` are worker-only — they have no remote-control support.

### Auto-failover chains

When a provider hits its rate limit, DevLoop automatically switches to the next:
```
Main:   claude → copilot
Worker: copilot → opencode → pi
```

Each provider is probed for availability every `DEVLOOP_PROBE_INTERVAL` minutes (default: 5). When it responds, it is restored immediately — no fixed waiting period.

→ Walkthrough: [USAGE.md — Scenario 5](./USAGE.md#scenario-5--smart-provider-failover-automatic-limit-handling)

---

## The Full Remote Loop

```bash
# On your Mac (once):
devloop daemon            # start, close terminal

# On your phone (Claude app → "DevLoop: MyProject"):
"add pagination to the orders list endpoint"

# Orchestrator responds automatically:
# 📐 Designing spec...  (Claude architect)
# 🤖 Implementing...    (Copilot worker)
# 🔍 Reviewing...       (Claude reviewer)
# ✅ Approved — routes.py, repository.py, test_orders.py changed
```

→ Full walkthroughs: **[USAGE.md](./USAGE.md)**

---

## File Structure

```
your-project/
├── devloop.config.sh                        ← edit this with your stack
├── CLAUDE.md                                ← Claude Code persistent context
├── copilot-setup-steps.yml                  ← Copilot agent env (github-agent mode)
├── .github/
│   ├── copilot-instructions.md              ← Copilot persistent context
│   ├── copilot/skills/                      ← Copilot project skills (repo-shared)
│   ├── instructions/                        ← Path-specific Copilot instructions
│   └── workflows/
│       └── devloop-review.yml               ← CI review workflow (devloop ci)
├── .copilot/
│   └── skills/                              ← Copilot local skills
├── .vscode/
│   └── mcp.json                             ← Copilot/VS Code MCP servers
├── .mcp.json                                ← Claude project MCP servers
├── .claude/
│   ├── settings.json                        ← Claude hooks config (7 events)
│   ├── hooks/
│   │   ├── devloop-permission.sh            ← PreToolUse: 3-tier bash classifier
│   │   ├── devloop-audit.sh                 ← PostToolUse: tool call audit logger
│   │   ├── devloop-stop.sh                  ← Stop: task summary capture
│   │   ├── devloop-subagent-stop.sh         ← SubagentStop: verdict detection
│   │   ├── devloop-notification.sh          ← Notification logger
│   │   └── devloop-session.sh               ← SessionStart/End logger
│   ├── skills/                              ← Claude skills
│   └── agents/
│       ├── devloop-orchestrator.md          ← main agent
│       ├── devloop-architect.md             ← subagent
│       └── devloop-reviewer.md              ← subagent
└── .devloop/
    ├── provider-health.sh                   ← auto-failover state (runtime, gitignore)
    ├── agent-docs/                          ← cached provider docs (devloop agent-sync)
    │   ├── claude-docs.md
    │   ├── copilot-docs.md
    │   └── provider-context.md
    ├── permission-queue/                    ← escalated permission requests (runtime)
    ├── permissions.log                      ← PostToolUse audit log (runtime)
    ├── daemon.pid / daemon.log              ← daemon state
    ├── pipeline.log                         ← hook-captured events
    ├── notifications.log / sessions.log     ← Claude logs
    ├── specs/
    │   ├── TASK-20260509-143022.md          ← full spec
    │   ├── TASK-20260509-143022.pre-commit  ← git baseline
    │   ├── TASK-20260509-143022-review.md   ← review
    │   └── ...
    └── prompts/
        ├── TASK-20260509-143022-copilot.txt ← extracted Copilot block
        └── ...
```

**Recommended `.gitignore` additions:**
```
.devloop/daemon.pid
.devloop/daemon.log
.devloop/launchd*.log
.devloop/provider-health.sh
.devloop/permission-queue/
.devloop/permissions.log
# keep: .devloop/specs/  .devloop/prompts/  .devloop/agent-docs/
```

---

## Sleep & Connectivity Issues

| Problem | Solution |
|---------|----------|
| Mac sleeps → session drops | `devloop daemon` uses `caffeinate -is` |
| Terminal closed → session dies | `devloop daemon` runs in background |
| Mac reboots → session gone | `devloop daemon` registers launchd agent |
| Linux reboots → session gone | `devloop daemon` registers systemd user service |
| Provider hits rate limit | Auto-failover to next in chain |
| Crash loop | Exponential backoff (5s→60s), stops after 20 restarts |
| Check what happened | `devloop daemon log` |
| Start fresh | `devloop daemon stop && devloop daemon` |
| Remove auto-start | `devloop daemon uninstall` |

---

## Tips

**Model cost control:**
```bash
CLAUDE_MODEL="sonnet"   # fast + cheap (default)
CLAUDE_MODEL="opus"     # more capable for complex architecture
```

**Multiple projects:**
Each project gets its own daemon. Run `devloop daemon` in each project directory.

**Refresh Copilot instructions after config changes:**
```bash
rm .github/copilot-instructions.md && devloop init
```

**Keep agent docs current:**
```bash
devloop agent-sync   # refresh provider docs and check for updates
```

**Keep specs in git:**
Add `.devloop/specs/` to version control — specs document every decision and review.

**VS Code integration:**
```json
{ "label": "DevLoop Review", "type": "shell", "command": "devloop review", "group": "build" }
```

**Preview before cleaning:**
```bash
devloop clean --days 14 --dry-run   # preview
devloop clean --days 14             # apply
```

**Understand the full data flow:**
See [DEVLOOP-GRAPH.md](./DEVLOOP-GRAPH.md) for 11 Mermaid diagrams.
