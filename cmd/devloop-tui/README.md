# `devloop-tui`

Bubble Tea + Lipgloss terminal UI for the DevLoop pipeline. Watches the
same `.devloop/` directory the bash engine reads and writes, so the TUI
and CLI run side-by-side without coordination.

> **End-user reference**: see the top-level [README — TUI section](../../README.md#tui--devloop-tui).
> **Usage walkthrough**: see [USAGE — Scenario 7](../../USAGE.md#scenario-7--drive-the-pipeline-from-the-tui-devloop-tui).
>
> This document is for **contributors** working on the TUI itself.

---

## Build + run

```bash
cd cmd/devloop-tui
go build -o devloop-tui .          # produces ./devloop-tui
./devloop-tui                       # dashboard
./devloop-tui chat                  # slash-command REPL
./devloop-tui status                # newest session detail
./devloop-tui onboard               # first-run wizard
go test ./...                       # full suite, ~1600 lines of tests
```

Requires **Go 1.22+** (toolchain pinned in `go.mod`). CI: `tui-ci.yml`
runs `go build` + `go test` + `go vet` on every PR touching this tree.

---

## Architecture at a glance

```
                          ┌────────────────────────┐
        Bubble Tea        │       AppModel         │   internal/app/app.go
        runtime ─────────►│  router + palette ovly │
                          └─────────┬──────────────┘
                                    │
                ┌───────────┬───────┴────────┬──────────────┐
                ▼           ▼                ▼              ▼
          ViewDashboard  ViewFocus       ViewChat       ViewOnboard
         (dashboard.go) (focus.go)      (chat.go)      (onboard.go)
                │           │                │              │
                ▼           ▼                ▼              ▼
            ┌────────────────────────────────────────────────┐
            │            internal/components/                 │
            │   filter · panel · palette · pipeline_grid ·    │
            │   task_picker                                   │
            └─────────┬───────────────────┬───────────────────┘
                      │                   │
                      ▼                   ▼
                 internal/theme/      internal/uimsg/
                 (colors + styles)    (cross-pkg tea.Msg)
                      │
                      ▼
                ┌─────────────────────────────────────────┐
                │  internal/{health, permit, stream}      │
                │   ⤷ thin pure-data readers of .devloop  │
                └─────────────────────────────────────────┘
```

### Package responsibilities

| Package | Purpose | Stability |
|---------|---------|-----------|
| `theme/` | Color tokens + style helpers. The ONLY place `lipgloss.Color("…")` literals are allowed. | Stable |
| `health/` | Parses `.devloop/provider-health.sh`; returns a `ProviderHealth{Main, Worker}` snapshot. | Stable |
| `permit/` | Parses `.devloop/permission-queue/<UUID>.json`. Tolerant of malformed files / races. | Stable |
| `uimsg/` | Cross-package `tea.Msg` types (`OpenFocus`, `CloseFocus`, `PaletteRun`). Leaf package — no cycles. | Stable |
| `stream/` | NDJSON tailer + session scanner. **DO NOT MODIFY** unless you're hardening the tailer. | Frozen |
| `components/` | Generic UI primitives reusable across views. | Mostly stable |
| `views/` | Top-level Bubble Tea models. Where most feature work lands. | Active |
| `app/` | Root router. Intercepts global keys (`space`), routes `uimsg.*` to view transitions, composites palette overlay. | Active |

---

## Hard reuse rules

These are enforced by review and exist to prevent the codebase from
fragmenting:

### 1. Subprocesses run through `chat.dispatchShell`

```go
// ✅ Good — uses the established pattern
return m.dispatchShell("review", "")
```

```go
// ❌ Bad — new subprocess pattern means new lifecycle bugs
out, _ := exec.Command("bash", "devloop.sh", "review").Output()
```

The only exceptions in the current codebase are the
*goroutine-backed read-only* loaders (`dashboard.dispatchDiffLoad`,
`focus.dispatchFocusDiff`, `onboard.runDoctor`) which produce data, not
side effects, and emit a single result message.

### 2. NDJSON events come from `stream.Tailer`

```go
// ✅ Good
tailer := &stream.Tailer{Path: filepath.Join(root, ".devloop", "events.ndjson")}
events, errs, _ := tailer.Run(ctx)
```

Ad-hoc `os.ReadFile` of `events.ndjson` is fine for **point-in-time**
queries (e.g. reconstructing a gate-timeout's offending command) but
not for live updates.

### 3. All colours via `theme.*`

```go
// ✅
lipgloss.NewStyle().Foreground(theme.Green)

// ❌
lipgloss.NewStyle().Foreground(lipgloss.Color("82"))
```

P1-1 migrated every existing literal. New literals should fail review.

### 4. Cross-view messages live in `internal/uimsg/`

`app` already imports `views`. Putting a cross-cutting message type in
`views` (or `app`) creates an import cycle. Always add new transition
messages to `uimsg`.

### 5. Modals are string composition, not z-buffering

The palette overlay in `app.View()` uses `overlayCompose` (line-wise
substitution). lipgloss has no z-buffer; trying to build one introduces
flicker. The approach we use: render base view, render overlay centred,
line-by-line replace base lines where overlay has content.

---

## Message flow examples

### Pressing `enter` on a task → Focus Mode

```
DashboardModel.Update(KeyMsg{"enter"})
   └─► cmds = append(cmds, func() tea.Msg {
           return uimsg.OpenFocus{SessionIdx: i, SessionID: id}
       })
            │
            ▼
AppModel.Update(uimsg.OpenFocus{…})
   └─► handleSwitch(SwitchViewMsg{
           Target:          ViewFocus,
           FocusSessionIdx: of.SessionIdx,
           FocusSessionID:  of.SessionID,
       })
            │
            ▼
buildFocus(root, opts, idx, id) → views.NewFocusWithOptions(…)
   └─► m.current = ViewFocus
   └─► m.activeView().Init()  // starts NDJSON tailer for this session
```

### Pressing `space` then `R` → review dispatch

```
AppModel.Update(KeyMsg{" "})            // global SPACE
   └─► palette.Open()
            │
            ▼
AppModel.Update(KeyMsg{"R"})            // shortcut, filter empty
   └─► palette.Close()
   └─► cmd returns uimsg.PaletteRun{Command: "review"}
            │
            ▼
AppModel.Update(uimsg.PaletteRun{"review"})
   └─► handleSwitch(SwitchViewMsg{Target: ViewChat})
   └─► activeView().Update(uimsg.PaletteRun{…})
            │
            ▼
ChatModel.Update(uimsg.PaletteRun{"review"})
   └─► chat.dispatchShell("review", "")  // bash devloop.sh review
   └─► output streams into scrollback
```

### Phase escalation → blue card + footer

```
devloop.sh cmd_resume          (PF-1: emit_event phase.escalate …)
   │
   ▼
events.ndjson
   │
   ▼ (fsnotify)
stream.Tailer  → focusStreamEventMsg
   │
   ▼
FocusModel.applyStreamEvent(ev)
   └─► m.reArchSessions[ev.Session] = true
            │
            ▼
View() → contextualFooterHint()
   └─► sees m.reArchSessions[id] == true
   └─► returns "⟳ re-architecting after retries exhausted…"
```

On the next `phase.start` for that session, the flag clears and the
footer reverts.

---

## Testing patterns

### Driving a model with messages

```go
func driveModel(t *testing.T, m DashboardModel, msg tea.Msg) DashboardModel {
    t.Helper()
    updated, _ := m.Update(msg)
    mm, ok := updated.(DashboardModel)
    if !ok { t.Fatalf("Update returned %T, want DashboardModel", updated) }
    return mm
}
```

Each view test helper looks the same (see `driveFocus`, `driveOnboard`).
The pattern lets you assert against `m`'s fields directly.

### ANSI-strip for visible-text assertions

```go
out := stripANSI(m.View())
if !strings.Contains(out, "main ✓") {
    t.Errorf("expected 'main ✓' in header, got %q", out)
}
```

`stripANSI` lives in `dashboard_test.go` and walks ESC `[`…letter sequences.

### NoSubprocess / NoStream test options

Every view that spawns goroutines or subprocesses takes an Options struct
with a flag to disable that side-effect:

| View | Flag |
|------|------|
| `DashboardOptions{NoStream: true}` | Skips the NDJSON tailer |
| `FocusOptions{NoStream: true}` | Skips the NDJSON tailer |
| `OnboardOptions{NoSubprocess: true}` | Short-circuits init/doctor with canned output |
| `ChatOptions{NoSubprocess: true}` | dispatchShell emits fake lines |

Tests use these to stay hermetic. CI is on Ubuntu with no devloop config;
without these flags the suite would hang on subprocesses.

---

## Adding a new view

1. Create `internal/views/<name>.go` exporting `<Name>Model` implementing
   `tea.Model`.
2. Add a `View<Name>` constant in `internal/app/app.go`.
3. Add a `build<Name>` constructor + a lazy case in `handleSwitch`.
4. If reachable via a global keystroke or cross-view event, add a
   message type to `internal/uimsg/`.
5. Tests: at minimum cover Init (zero state), one happy-path Update, and
   one view-level rendering assertion.

## Adding a new palette action

1. Add an entry to `components.DefaultActions` in
   `internal/components/palette.go`. Pick a single-letter `Key` that
   isn't taken (current set: A W R F L T P D H U E G X Q I K J Z).
2. If the action's `Command` is multi-word (e.g. `"daemon log"`), make
   sure `chat.buildArgv`'s default case splits it correctly — it does
   via `strings.Fields`. New first-word commands likely don't need a
   special case.
3. Update tests in `palette_test.go` if your action affects the action
   count or ordering.

---

## Files this TUI reads from disk

All read-only; the bash engine owns writes.

| Path | Read by |
|------|---------|
| `.devloop/events.ndjson` | `dashboard.go`, `focus.go` (live tailer) |
| `.devloop/sessions/<TASK-ID>/events.ndjson` | `focus.go` (per-session live) |
| `.devloop/sessions/<TASK-ID>/status` | `focus.go` (gate-timeout detection) |
| `.devloop/specs/<TASK-ID>.md` | `dashboard.go`, `focus.go` (SPEC panel) |
| `.devloop/specs/<TASK-ID>.pre-commit` | `dashboard.go`, `focus.go` (DIFF baseline) |
| `.devloop/permission-queue/<UUID>.json` | `permit/permit.go` |
| `.devloop/permission-queue/<UUID>.response` | `permit/permit.go` (exclusion check) |
| `.devloop/provider-health.sh` | `health/health.go` |
| `.devloop/daemon.pid` | `dashboard.go` (liveness via signal-0) |
| `.devloop/daemon.log` | `dashboard.go` (restart counter) |
| `.devloop/pipeline.log` `notifications.log` `sessions.log` | `focus.go` LOG tab cycling |

## Files this TUI writes (indirectly, via subprocesses)

The TUI itself never writes inside `.devloop/`. Subprocesses dispatched
through `chat.dispatchShell` invoke `devloop.sh`, which is the only
writer. The TUI's writes are limited to the chat scrollback buffer in
memory.

---

## Configuration env vars

| Env var | Default | Effect |
|---|---|---|
| `DEVLOOP_STUCK_THRESHOLD_MIN` | `10` | Minutes a running phase can produce no output before being flagged "quiet" |
| `DEVLOOP_EVENTS_DISABLED` | unset | Suppress NDJSON emission (debug only; consumed by the bash engine — the TUI just sees no events) |

There is intentionally no TUI-specific config file. All state is reflected
from `.devloop/`.

---

## Spec correction history

The original brief in `devloop-tui-redesign 3/` had several factual errors
that were corrected during implementation. The corrections are baked into
the code and noted in commit messages, but worth knowing:

| Brief said… | Reality (shipped) |
|---|---|
| `internal/theme/colors.go` is a new file | Migrated from existing raw literals in P1-1 |
| Permit queue: filename = command | UUID JSON; command in body |
| `permit mode auto` grants the queue | That flips the mode globally; use `permit grant --all` instead |
| Gate timeout in `worker.state` | No such file; status lives in `.devloop/sessions/<TASK-ID>/status` |
| Provider health vars: `DEVLOOP_*_OVERRIDE` | Real names: `HEALTH_MAIN_*` / `HEALTH_WORKER_*` |
| Detect escalation by scraping worker stdout | NDJSON `phase.escalate` event (new in v5.3) |
| TUI tails `.devloop/pipeline.log` | Authoritative file is `events.ndjson` |

If you're reading the original brief alongside the code and something
doesn't match, this table is why.
