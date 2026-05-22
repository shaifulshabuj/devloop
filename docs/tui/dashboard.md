# Dashboard

The dashboard is the default view. It shows every active task plus a
top bar with provider health and permit queue at a glance.

## Layout

```text
┌────────────────────────────────────────────────────────────────────┐
│ main ✓  ·  worker ✓  ·  daemon ✓ ×0   ⚑ 0 pending                 │  ← top bar
├──────────────────────────┬─────────────────────────────────────────┤
│  Tasks                   │                                         │
│  / filter…               │  SPEC                                   │
│  ▸ TASK-20260522-104812  │  # Spec: Date-range filter…             │
│      ▶ worker  4m12s     │                                         │
│      (quiet for 2m)      │                                         │
│  ▸ TASK-20260522-103022  │                                         │
│      ✓ approved   1m08s  │                                         │
│  ▸ TASK-20260522-092500  │  DIFF                                   │
│      ✗ rejected          │  +34 -2  handlers/orders.go             │
│                          │  …                                      │
└──────────────────────────┴─────────────────────────────────────────┘
```

## Top bar

A single line summarises external state.

| Element | Meaning |
|---|---|
| `main ✓` | Main provider healthy |
| `main ✗→copilot` | Main failed over to a named fallback |
| `worker ✓` | Worker provider healthy |
| `daemon ✓ ×N` (yellow) | Daemon restarted N times recently |
| `daemon ⊘ ×N max` (red) | Auto-restart budget exhausted |
| `⚑ N pending` (yellow) | N permission escalations in the queue |

Hidden when everything is green and the queue is empty.

## Task list

One line per task: ID, current phase, elapsed time. A secondary "quiet"
line appears underneath any task whose phase has produced no output for
more than `DEVLOOP_STUCK_THRESHOLD_MIN` minutes — usually a hint that a
permit is sitting in the queue.

## Filter

Press `/` to enter fuzzy filter mode. The list narrows as you type.
`esc` clears.

## Side panels

| Key | Effect |
|---|---|
| `s` | Toggle the **SPEC** panel — shows `.devloop/specs/<TASK-ID>.md` for the highlighted task |
| `d` | Toggle the **DIFF** panel — asynchronous `git diff <baseline>..HEAD` against the recorded `pre-commit` hash; falls back to `git diff HEAD` when no baseline is recorded |

Both panels reload as you navigate the task list. DIFF loads in a
background goroutine so the UI stays responsive on large diffs.

## Keys

| Key | Action |
|---|---|
| `↑ / ↓` (or `j / k`) | Move selection |
| `enter` | Open [Focus Mode](focus.md) on the selected task |
| `space` | Same as `enter` |
| `:` | Open the [Command Palette](palette.md) |
| `/` | Fuzzy filter |
| `s` | Toggle SPEC panel |
| `d` | Toggle DIFF panel |
| `r` | Refresh / re-read state |
| `q` | Quit |
| `?` | Show key help |
