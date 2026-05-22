# Commands

All `devloop` subcommands, grouped by purpose. `devloop help` prints the
same content at the terminal.

## Project setup

### `devloop install [path]`

Install `devloop.sh` to a target path. Defaults to `/usr/local/bin/devloop`.

```bash
devloop install                # /usr/local/bin/devloop (requires sudo)
devloop install ~/bin/devloop  # custom path
```

### `devloop init [--yes|-y] [--configure|-c] [--merge]`

Set up DevLoop in the current project. Auto-detects stack from project
files and writes `devloop.config.sh`.

| Flag | Effect |
|---|---|
| `--yes`, `-y` | Skip the interactive wizard, use detected defaults |
| `--configure`, `-c` | Re-run the wizard on an existing project |
| `--merge` | Add missing config keys from a newer DevLoop version without overwriting |

### `devloop configure` { #configure }

Re-run the interactive setup wizard. Updates `devloop.config.sh` and
regenerates agent prompt files. Aliases: `setup`, `wizard`.

```bash
devloop configure                # project-local config
devloop configure --global       # ~/.devloop/config.sh (applies to all projects)
```

### `devloop doctor`

Validate dependencies and configuration. Run after `init` and any time
something looks off.

### `devloop hooks`

Install Claude pipeline hooks: `.claude/settings.json` plus the
`PreToolUse` permission hook and `PostToolUse` audit hook.

---

## Running the pipeline

### `devloop run "feature"` { #run }

Full automated pipeline: architect → work → review → fix loop → learn.
Alias: `go`.

| Flag | Default | Description |
|---|---|---|
| `--type TYPE` | auto-detected | Override task type (`feature`, `bug`, `refactor`, `docs`) |
| `--files hints` | — | Comma-separated file path hints for the architect |
| `--max-retries N` | `DEVLOOP_MAX_FIX_ROUNDS` | Override max fix rounds for this run |
| `--no-learn` | off | Skip the learn phase on approval |
| `--no-respec` | off | Skip the re-architect phase after all fix rounds exhausted |

```bash
devloop run "add date-range filter to /orders"
devloop run "fix null deref in OrderService" --type bug
devloop run "refactor auth" --files auth/,middleware/ --max-retries 3
```

### `devloop do "task"` { #do }

Plain-English task entry point — no quoting required for unambiguous
phrases. Aliases: `ask`, `please`, `nl`.

```bash
devloop do check the latest progress and work on remaining tasks
```

### `devloop resume [TASK-ID]`

Resume an interrupted pipeline from the last completed phase.

| Flag | Effect |
|---|---|
| `--list` | List resumable sessions |
| `--dry-run` | Print what would be resumed without executing |

### `devloop queue {add|list|run|clear}`

Batch mode. Alias: `q`.

```bash
devloop queue add "add /healthz endpoint"
devloop queue add "add Prometheus metrics" --type feature
devloop queue list
devloop queue run --stop-on-fail
devloop queue clear
```

---

## Step-by-step pipeline commands

For when you want to run phases individually.

| Command | Alias | Purpose |
|---|---|---|
| `devloop architect "feature" [type] [files]` | `a` | Main provider designs a spec |
| `devloop work [TASK-ID]` | `w` | Launch worker to implement the spec |
| `devloop review [TASK-ID]` | `r` | Main provider reviews git diff |
| `devloop fix [TASK-ID]` | `f` | Launch worker with review fix instructions |

---

## Session management

### `devloop start [project-name]` { #start }

Launch the provider session + orchestrator agent. Prevents Mac sleep via
`caffeinate`. Alias: `s`.

- Claude main → remote-control session (claude.ai/code + mobile)
- Copilot main → remote session (github.com/copilot + mobile)

### `devloop daemon [project-name]`

Run in background with auto-restart + sleep prevention. Registers
launchd (macOS) or systemd (Linux) on first run. Alias: `d`.

| Subcommand | Effect |
|---|---|
| `devloop daemon stop` | Stop the daemon |
| `devloop daemon status` | Show daemon state and restart count |
| `devloop daemon log` | Tail the daemon log |
| `devloop daemon uninstall` | Remove the launchd/systemd unit |

### `devloop sessions [--last N] [--status STATUS]`

List past pipeline runs with status, duration, and feature description.
`STATUS`: `approved`, `running`, `needs-work`, `rejected`.

### `devloop session <task-id>`

Show phase timeline, log file sizes, and tail the main log for a session.

### `devloop replay <task-id> [--phase PHASE]`

Replay recorded phase logs. `PHASE`: `architect`, `worker`, `reviewer`,
`fix-N`, `respec`.

### `devloop view [task-id]`

Live tmux dashboard: Architect | Worker | Reviewer | Fix/Decisions+Permissions.
Falls back to inline log tail if `tmux` not installed.

### `devloop tasks`

List all task specs with status. Alias: `t`.

### `devloop status [TASK-ID]`

Live single-session view (TUI; text fallback when piped). Shows full
spec and latest review.

### `devloop stats`

Aggregated metrics: approval rate, average phase times, average fix rounds.

### `devloop open [TASK-ID]`

Open the spec in `$EDITOR` (defaults to `vi`). Alias: `o`.

### `devloop block [TASK-ID]`

Print the Copilot Instructions Block for a task. Alias: `b`.

### `devloop clean [--days N] [--dry-run]`

Remove finalized (approved/rejected) specs older than `N` days
(default `30`).

---

## TUI

### `devloop` (no args)

Launch the live dashboard (TUI). Same as `devloop dashboard`.

Disable auto-launch by setting `DEVLOOP_DEFAULT_VIEW=help` in `devloop.config.sh`.

### `devloop dashboard`

Explicit form. Build the TUI with `make tui-install` if it's not on `$PATH`.

### `devloop chat`

Slash-command REPL (TUI). Type `/run`, `/queue add`, `/sessions`, etc.

---

## Providers & failover

### `devloop failover {status|reset|probe|main|worker}`

Manage automatic provider failover. See [Providers & Failover](../concepts/providers.md).

```bash
devloop failover status
devloop failover reset
devloop failover probe
devloop failover main copilot
devloop failover worker opencode
devloop failover worker clear
```

### `devloop agent-sync`

Refresh cached provider docs (24h TTL) and analyse what's new. Updates
`CLAUDE.md` with insights. Aliases: `sync-agents`, `agentsync`.

---

## Permissions

### `devloop permissions`

Open `.devloop/permissions.yaml` in `$EDITOR`.

### `devloop permit {status|watch|grant|deny|log|mode}`

Manage the permission queue. See [Permissions](../concepts/permissions.md).

```bash
devloop permit status
devloop permit watch
devloop permit grant
devloop permit deny <id>
devloop permit log
devloop permit mode {off|auto|smart|strict}
```

---

## Inbox

### `devloop inbox`

View pending human decisions: permissions, NEEDS_WORK reviews, blocked
tasks.

| Flag / sub | Effect |
|---|---|
| `--all` | Across all registered projects |
| `resolve <id> [approved\|denied\|skipped]` | Resolve a specific item |
| `history` | View resolved items |
| `clear` | Remove resolved items |

### `devloop projects`

List all registered DevLoop projects with provider, last-run time, status.

```bash
devloop projects                       # list
devloop projects switch <name>         # print path (eval to cd)
```

---

## Learning

### `devloop learn [TASK-ID]`

Extract lessons from the latest review and append to `CLAUDE.md`.

```bash
devloop learn                # latest task
devloop learn TASK-X         # specific task
devloop learn --global       # also promote to ~/.devloop/lessons.md
```

---

## Tools

### `devloop tools {add|suggest|audit|sync}`

Manage project tool wiring (linters, test runners, etc.) used by the
architect when reasoning about your stack.

```bash
devloop tools suggest        # discover stack-specific tools
devloop tools add make-lint
devloop tools audit
devloop tools sync
```

---

## Maintenance

### `devloop check`

Check for the latest DevLoop version on GitHub. Works out-of-the-box.

### `devloop update`

Self-upgrade `devloop.sh` from GitHub and refresh project configs.

### `devloop logs [TYPE]`

Show logs. `TYPE`: `pipeline` (default), `notification`, `session`.

### `devloop ci`

Generate a GitHub Actions workflow that runs `devloop review` on PRs.

### `devloop --version`

Print the installed DevLoop version.
