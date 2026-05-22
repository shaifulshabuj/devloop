# TUI

`devloop-tui` is a Go (Bubble Tea + Lipgloss) terminal UI that sits next
to the bash engine. It watches `.devloop/` and renders the pipeline live —
the engine still owns all writes.

CLI behaviour is unchanged. The TUI is opt-in.

## Install

```bash
git clone https://github.com/shaifulshabuj/devloop.git
cd devloop
make tui-install        # builds and installs to ~/bin/devloop-tui
```

Requires Go 1.21+. Once installed, just run:

```bash
devloop                 # launches the dashboard (no args)
devloop dashboard       # same, explicit
```

## Three views

| View | Page | Purpose |
|---|---|---|
| [Dashboard](dashboard.md) | Multi-task overview | Pick a task; see provider health + permits at a glance |
| [Focus Mode](focus.md) | Single-task deep dive | LOG / SPEC / DIFF / PERMIT tabs; phase track |
| [Command Palette](palette.md) | Cmd-K style action launcher | 18 default actions; press `:` |

## What the TUI reads

The TUI is **read-only** with respect to engine state. It consumes:

| Path | Source of truth |
|---|---|
| `.devloop/events.ndjson` | Live event stream (dashboard, focus) |
| `.devloop/sessions/<TASK-ID>/events.ndjson` | Per-session events |
| `.devloop/sessions/<TASK-ID>/status` | Gate-timeout detection |
| `.devloop/specs/<TASK-ID>.md` | SPEC panel content |
| `.devloop/specs/<TASK-ID>.pre-commit` | DIFF panel baseline hash |
| `.devloop/permission-queue/<UUID>.json` | PERMIT tab + dashboard chip |
| `.devloop/provider-health.sh` | Provider top bar |
| `.devloop/daemon.pid`, `daemon.log` | Daemon liveness + restart count |

Anything the TUI writes (palette command results, permit decisions) goes
through the existing bash CLI — no duplicate code paths.

## Disable the auto-launch

By default, running `devloop` with no arguments opens the dashboard. To
get the old help screen instead, set:

```bash
DEVLOOP_DEFAULT_VIEW=help
```

in `devloop.config.sh`. The CLI keeps working exactly as before — only
the no-arg behaviour changes.

## Stuck-task detection

The dashboard flags tasks whose running phase has produced no output
for longer than `DEVLOOP_STUCK_THRESHOLD_MIN` minutes (default `10`) with
a "quiet" line under the task. This is the most common signal that a
permission escalation is sitting in the queue or that a provider hung.

```bash
DEVLOOP_STUCK_THRESHOLD_MIN=5      # more aggressive
DEVLOOP_STUCK_THRESHOLD_MIN=0      # disable
```
