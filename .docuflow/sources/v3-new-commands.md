# DevLoop v3.0.0 — New Commands & Features

This document describes all features and commands added in DevLoop v3.0.0.

---

## Provider Routing

DevLoop supports two AI providers — **Claude** (via `claude` CLI) and **Copilot** (via `gh copilot`) — and each role (main vs worker) can be assigned independently.

### Configuration (`devloop.config.sh`)

```bash
# Provider for orchestrator, architect, reviewer roles
DEVLOOP_MAIN_PROVIDER="claude"     # or "copilot"

# Provider for work, fix roles
DEVLOOP_WORKER_PROVIDER="copilot"  # or "claude"

# Worker execution mode
DEVLOOP_WORKER_MODE="cli"          # or "github-agent"

# Claude model (applies when main or worker uses claude)
CLAUDE_MODEL="sonnet"              # or "opus"
```

### Supported Combinations

| Mode | Main | Worker | Description |
|------|------|--------|-------------|
| 1 (all Copilot) | copilot | copilot | Copilot handles everything |
| 2 (default) | claude | copilot | Claude orchestrates, Copilot implements |
| 3 (all Claude) | claude | claude | Claude handles everything |
| 4 (reversed) | copilot | claude | Copilot orchestrates, Claude implements |

---

## Worker Modes

### `cli` (default)

Worker runs via the local CLI tool. Copilot uses `gh copilot suggest --target shell`; Claude uses `claude -p`.

```bash
DEVLOOP_WORKER_MODE="cli"
```

### `github-agent`

Worker creates a GitHub Issue containing the spec, and the Copilot cloud coding agent picks it up, opens a PR, and DevLoop polls until the PR appears.

```bash
DEVLOOP_WORKER_MODE="github-agent"
```

Requirements: `gh` CLI authenticated, Copilot coding agent enabled on the repository. DevLoop automatically creates `copilot-setup-steps.yml` during `devloop init` in this mode.

The issue body includes the full spec. The PR is checked every 30 seconds (up to 20 minutes). When the PR appears, DevLoop auto-triggers `devloop review`.

---

## `devloop hooks`

Installs Claude Code pipeline hooks into `.claude/settings.json` and writes four executable hook scripts to `.claude/hooks/`.

```bash
devloop hooks
```

### Hook scripts created

| Script | Event | Purpose |
|--------|-------|---------|
| `devloop-stop.sh` | `Stop` | Logs task summary to `.devloop/pipeline.log` |
| `devloop-subagent-stop.sh` | `SubagentStop` | Records subagent completions and verdicts |
| `devloop-notification.sh` | `Notification` | Saves Claude notifications to `.devloop/notifications.log` |
| `devloop-session.sh` | `PreToolUse(Bash)` | Records session start/end to `.devloop/sessions.log` |

Hook scripts are registered in `.claude/settings.json` under the `hooks` section. They run automatically during Claude Code sessions.

---

## `devloop logs`

View DevLoop log files from the terminal.

```bash
devloop logs                  # view pipeline log (default)
devloop logs pipeline         # view .devloop/pipeline.log
devloop logs notifications    # view .devloop/notifications.log
devloop logs sessions         # view .devloop/sessions.log
```

Uses `less` with color support. Falls back to `cat` if `less` is unavailable.

---

## `devloop learn [TASK-ID]`

Extracts lessons from the latest review for a task and appends them to `CLAUDE.md` under a `## Learned Patterns` section.

```bash
devloop learn                 # learns from latest task
devloop learn TASK-20260506-143022
```

The review file is parsed for key insights: what worked, what failed, patterns to avoid, architectural decisions. These are prepended to CLAUDE.md so Claude reads them in every future session. This makes the pipeline progressively smarter over time.

---

## `devloop check`

Checks for a newer version of DevLoop by fetching from `DEVLOOP_VERSION_URL`.

```bash
devloop check
```

Requires `DEVLOOP_VERSION_URL` set in `devloop.config.sh` pointing to a plain-text semver file:
```bash
DEVLOOP_VERSION_URL="https://raw.githubusercontent.com/you/devloop/main/VERSION"
```

`devloop start` runs a silent background version check on launch. If a newer version is found, a hint is shown on the next `devloop start`.

---

## `devloop doctor`

Validates all DevLoop dependencies and project configuration. Reports pass/fail for each check with fix hints.

```bash
devloop doctor
```

Checks:
- `claude` CLI installed
- `copilot` CLI installed (`gh extension`)
- `gh` CLI installed
- `git` installed
- Inside a git repo
- `devloop.config.sh` present
- `CLAUDE.md` present
- `.github/copilot-instructions.md` present
- Agent files present (orchestrator, architect, reviewer)
- Claude hooks installed (`.claude/settings.json` with `devloop-stop` hook)
- Tools summary: MCP count, skills count, path instructions count
- Version up to date (if `DEVLOOP_VERSION_URL` configured)

Prints summary: `Passed: N   Failed: N`.

---

## `devloop ci`

Generates `.github/workflows/devloop-review.yml` — a GitHub Actions workflow that triggers Claude to automatically review PRs.

```bash
devloop ci
```

The generated workflow runs `devloop review` on every pull request using the `anthropics/claude-code-action` integration. Requires `ANTHROPIC_API_KEY` secret in the GitHub repository.

---

## Daemon Improvements (v3.0.0)

`devloop daemon` now registers as a system service:

- **macOS**: registers a `launchd` plist at `~/Library/LaunchAgents/com.devloop.<project>.plist` for auto-start on login
- **Linux**: registers a `systemd` user service at `~/.config/systemd/user/devloop-<project>.service`

```bash
devloop daemon start      # start + register system service
devloop daemon stop       # stop
devloop daemon status     # check PID and process status
devloop daemon log        # view daemon restart log
devloop daemon uninstall  # remove system service registration
```

Auto-restart: if Claude exits, the daemon restarts it after a configurable delay (default: 5 seconds).

---

## Sleep Prevention

`devloop start` and `devloop daemon` both invoke `caffeinate -is` (macOS) to prevent the Mac from sleeping during a DevLoop session. The caffeinate process is killed when the session ends. On Linux, `caffeinate` is not available — a warning is shown.
