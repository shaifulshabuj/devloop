# Focus Mode

Press `enter` on a task in the [Dashboard](dashboard.md) to enter
Focus Mode — a single-task, full-screen view.

## Layout

```text
┌─ TASK-20260522-104812 ────────────────────────── main ✓ · worker ✓ ─┐
│                                                                     │
│  Phase track: ✓ architect → ✓ worker → ▶ reviewer                  │
│                                                                     │
│  [1] LOG   [2] SPEC   [3] DIFF   [4] PERMIT (2)                    │
│                                                                     │
│  …live log stream…                                                  │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## Phase track

Rendered with the same `pipeline_grid` component the dashboard uses, so
the visualisation is consistent. Each phase is one of:

- `✓` completed (green)
- `▶` in progress (blue, animated)
- `·` pending (grey)
- `✗` failed (red)
- `⟳` re-architecting (blue) — appears on a `phase.escalate` event

## Tabs

| Key | Tab | Contents |
|---|---|---|
| `1` | **LOG** | Live phase log + event stream for this session |
| `2` | **SPEC** | `.devloop/specs/<TASK-ID>.md` |
| `3` | **DIFF** | `git diff <pre-commit>..HEAD` for this session |
| `4` | **PERMIT (N)** | Pending permission requests — only visible when N > 0 |

`tab` cycles forward; `shift-tab` cycles back.

## LOG sub-source cycling

Inside the LOG tab, `,` and `.` switch between:

- The **per-session** event stream (`.devloop/sessions/<TASK-ID>/events.ndjson`)
- The **global** event stream (`.devloop/events.ndjson`, filtered to this task)
- The **raw phase log** for the currently active phase (e.g. `worker.log`)

The header shows which sub-source is active.

## Task navigation

`←` and `→` (or `h` / `l` vim-style) move to the previous / next task in
the dashboard's filtered list, with wrap-around. Useful for comparing
two in-flight runs without bouncing back to the dashboard.

## PERMIT tab

When `.devloop/permission-queue/` has any pending UUIDs, a `PERMIT (N)`
tab appears with the queue's contents. Each entry shows:

- The command being requested
- The originating task ID
- A grant / deny prompt

The tab disappears when the queue empties.

## Keys

| Key | Action |
|---|---|
| `1` / `2` / `3` / `4` | Jump to LOG / SPEC / DIFF / PERMIT tab |
| `tab` / `shift-tab` | Cycle tabs |
| `, / .` | Cycle LOG sub-source |
| `←` / `→` (or `h` / `l`) | Previous / next task |
| `esc` | Back to dashboard |
| `:` | Open the [Command Palette](palette.md) |
| `q` | Quit |
| `?` | Show key help |
