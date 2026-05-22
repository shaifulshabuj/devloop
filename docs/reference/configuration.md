# Configuration

All knobs live in `devloop.config.sh` (project-local) or
`~/.devloop/config.sh` (global default). Project values always override
global values.

`devloop init` creates the project file with sensible defaults. Edit by
hand or re-run `devloop configure`.

## Providers

| Variable | Default | Description |
|---|---|---|
| `DEVLOOP_MAIN_PROVIDER` | `claude` | Provider for architect, reviewer, orchestrator |
| `DEVLOOP_WORKER_PROVIDER` | `copilot` | Provider for worker/fix |
| `DEVLOOP_WORKER_MODE` | `cli` | `cli` or `github-agent` |
| `DEVLOOP_FAILOVER_ENABLED` | `true` | Auto-fail over on rate limits |
| `DEVLOOP_PROBE_INTERVAL` | `5` | Minutes between failover probes |
| `DEVLOOP_SOURCE_URL` | unset | Self-update source for `devloop update` |

## Models (Claude only)

| Variable | Default | Description |
|---|---|---|
| `CLAUDE_MODEL` | `sonnet` | Base model for all Claude roles |
| `CLAUDE_MAIN_MODEL` | (= `CLAUDE_MODEL`) | Architect / reviewer / orchestrator |
| `CLAUDE_WORKER_MODEL` | (= `CLAUDE_MODEL`) | Worker / fix |

Values: `sonnet` (balanced), `opus` (most capable), `haiku` (fast/cheap).

Copilot's model is set at [github.com/settings/copilot](https://github.com/settings/copilot).

## Pipeline behaviour

| Variable | Default | Description |
|---|---|---|
| `DEVLOOP_MAX_FIX_ROUNDS` | `5` | Max fix rounds before re-architect (or exit) |
| `DEVLOOP_FIX_STRATEGY` | `escalate` | `escalate` or `standard` |
| `DEVLOOP_AUTO_LEARN` | `true` | Run `learn` automatically on approval |

## Permissions

| Variable | Default | Description |
|---|---|---|
| `DEVLOOP_PERMISSION_MODE` | `smart` | `off`, `auto`, `smart`, `strict` |
| `DEVLOOP_PERMISSION_TIMEOUT` | `60` | Seconds before unanswered escalations auto-deny |

See [Permissions](../concepts/permissions.md) for the full classification
table.

## Sessions & logs

| Variable | Default | Description |
|---|---|---|
| `DEVLOOP_SESSION_LOGGING` | `true` | Write per-phase logs under `.devloop/sessions/<TASK-ID>/` |
| `DEVLOOP_AUTO_VIEW` | `false` | Auto-open `devloop view` on `devloop run` |
| `DEVLOOP_SESSION_KEEP_DAYS` | `30` | Auto-prune sessions older than N days (0 = keep all) |
| `DEVLOOP_STATUS_HEADER` | `on` | Print pipeline status header in `run`/`resume` |
| `DEVLOOP_EVENTS_DISABLED` | unset | Set to `1` to silence event emission (debug only) |

## TUI

| Variable | Default | Description |
|---|---|---|
| `DEVLOOP_DEFAULT_VIEW` | `dashboard` | Set to `help` to disable the TUI when running `devloop` with no args |
| `DEVLOOP_STUCK_THRESHOLD_MIN` | `10` | Minutes of no output before the dashboard flags a task as quiet |

## Stack (auto-detected)

`devloop init` auto-detects and writes these from your project files. You
generally don't need to edit them — re-running `devloop init --merge` will
refresh detection.

```bash
DEVLOOP_STACK_LANG="go"
DEVLOOP_STACK_FRAMEWORK="chi"
DEVLOOP_STACK_TEST_CMD="go test ./..."
DEVLOOP_STACK_LINT_CMD="golangci-lint run"
DEVLOOP_STACK_BUILD_CMD="go build ./..."
```

These hints flow into the architect's prompt as **Stack Context** so the
spec uses your project's conventions.

## Global vs project precedence

```text
~/.devloop/config.sh        ← global defaults
       ↓ (overridden by)
./devloop.config.sh         ← per-project
       ↓ (overridden by)
inline env vars             ← e.g. CLAUDE_MAIN_MODEL=opus devloop run "..."
```

Inline overrides win. Use this to experiment with a setting for one run
without persisting it.

## Example: minimal `devloop.config.sh`

```bash
# Required
DEVLOOP_MAIN_PROVIDER=claude
DEVLOOP_WORKER_PROVIDER=copilot

# Optional but recommended
DEVLOOP_SOURCE_URL="https://raw.githubusercontent.com/shaifulshabuj/devloop/main/devloop.sh"
CLAUDE_MAIN_MODEL=opus
CLAUDE_WORKER_MODEL=sonnet
DEVLOOP_PERMISSION_MODE=smart
DEVLOOP_MAX_FIX_ROUNDS=5
```
