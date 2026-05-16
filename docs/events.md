# DevLoop event stream

The bash engine (`devloop.sh`) emits one structured event per pipeline boundary
as a single line of NDJSON. This file is the contract between the engine and
any consumer (the future `devloop-tui` binary, monitoring scripts, dashboards).

## Sinks

Every event is appended to two files:

| File | Scope | Purpose |
|---|---|---|
| `.devloop/events.ndjson` | project-wide | All sessions, newest at bottom. Single source of truth for TUI dashboards. |
| `.devloop/sessions/<TASK-ID>/events.ndjson` | per-session | Only events for one session. Useful for replay and `devloop resume`. |

Both files are append-only. Writers use unbuffered `printf >> ...` so a
concurrent tailer (`tail -F`, `fsnotify`) sees every line atomically.

Set `DEVLOOP_EVENTS_DISABLED=1` to silence emission (engine continues normally;
this is a debugging escape hatch, not a recommended runtime setting).

## Envelope

Every event line is a JSON object with at least these fields:

```json
{ "ts": "2026-05-16T14:32:11Z", "session": "TASK-20260516-143155", "kind": "phase.start", "...": "..." }
```

| Field | Type | Notes |
|---|---|---|
| `ts` | string | ISO-8601 UTC, second precision |
| `session` | string | TASK-ID; empty string for events emitted before session init |
| `kind` | string | dotted name from the table below |

Additional fields depend on `kind`.

## Event kinds (Phase 1)

### `session.start`

Emitted by `_session_init` after the session directory exists.

```json
{ "ts": "...", "session": "TASK-...", "kind": "session.start", "feature": "add dark mode toggle" }
```

### `session.end`

Emitted by `_session_finish` once status is final.

```json
{ "ts": "...", "session": "TASK-...", "kind": "session.end", "status": "approved" }
```

`status` ∈ `approved | rejected | needs-work | rejected-at-plan | rejected-at-diff`.

### `phase.start`

Emitted by `_session_phase_start`.

```json
{ "ts": "...", "session": "TASK-...", "kind": "phase.start", "phase": "worker" }
```

`phase` ∈ `architect | worker | reviewer | fix-N` (fix-N where N is the round
number, e.g., `fix-1`).

### `phase.end`

Emitted by `_session_phase_end`. Includes `duration_ms` when the start
timestamp could be recovered.

```json
{ "ts": "...", "session": "TASK-...", "kind": "phase.end", "phase": "worker", "status": "done", "duration_ms": "4231" }
```

`status` ∈ `done | failed | skipped | approved | needs-work | rejected`.

> **Quirk — architect phase**: the architect runs *before* the session ID is
> known, so it has no `phase.start`. Consumers should treat
> `session.start.ts ≤ phase.end[phase=architect].ts` as the architect's window.

### `approval.request`

Emitted by `_approval_gate` before blocking on a decision.

```json
{
  "ts": "...",
  "session": "TASK-...",
  "kind": "approval.request",
  "gate": "plan",
  "summary": "Add dark mode toggle to settings page\nFiles: src/Settings.tsx, src/theme.ts",
  "detail_path": ".devloop/specs/TASK-....md",
  "detail_size": "3942",
  "decision_file": ".devloop/sessions/TASK-.../approvals/plan.json"
}
```

`gate` ∈ `plan | diff | fix` (only `plan` and `diff` are wired in Phase 1).

`decision_file` is the path a consumer can pre-write (or watch) to settle the
gate without an interactive prompt.

### `approval.decision`

Emitted by `_approval_resolve` once a decision is reached.

```json
{ "ts": "...", "session": "TASK-...", "kind": "approval.decision", "gate": "plan", "decision": "approve", "source": "gum" }
```

`decision` ∈ `approve | reject | edit`.

`source` ∈ `auto | pre-written | gum | gum-cancel | tty | tty-bad | timeout | no-tty`.

## Decision files

For every `approval.request`, the resolver writes the final decision to
`.devloop/sessions/<TASK-ID>/approvals/<gate>.json`:

```json
{ "ts": "2026-05-16T14:35:02Z", "gate": "plan", "decision": "approve", "source": "gum" }
```

To settle a gate non-interactively (CI, scripted, pre-decided by an external
UI), write this file **before** the gate runs:

```bash
mkdir -p .devloop/sessions/$ID/approvals
echo '{"decision":"approve"}' > .devloop/sessions/$ID/approvals/plan.json
```

The resolver picks it up via the `pre-written` source.

## Ordering guarantees

Within a single session, the engine emits events in this order:

```
session.start
  phase.end{phase=architect}            ← architect ran before session existed
  approval.request{gate=plan}
  approval.decision{gate=plan}
  phase.start{phase=worker}
  phase.end{phase=worker}
  approval.request{gate=diff}
  approval.decision{gate=diff}
  phase.start{phase=reviewer}
  phase.end{phase=reviewer}
  [phase.start{phase=fix-N} / phase.end{phase=fix-N}]*   ← repeated on NEEDS_WORK
session.end
```

Events from different sessions may interleave in `.devloop/events.ndjson` —
consumers must group by `session`.

## Bypass switches

| Variable | Effect |
|---|---|
| `DEVLOOP_AUTO=1` | Auto-approve all gates this run (also via `devloop run --auto` / `-y`) |
| `DEVLOOP_PLAN_GATE=off` | Skip plan gate entirely (no request, no decision) |
| `DEVLOOP_DIFF_GATE=off` | Skip diff gate entirely |
| `DEVLOOP_APPROVAL_TIMEOUT=N` | TTY prompt timeout in seconds (default 120) |
| `DEVLOOP_EVENTS_DISABLED=1` | Disable event emission entirely |

## Future kinds (Phase 2+, not yet emitted)

| Kind | Purpose |
|---|---|
| `phase.log` | Streaming log line for live tail in the TUI |
| `permission.request` / `permission.decision` | Wraps the existing PreToolUse hook |
| `inbox.append` | REJECTED / max-retries fan-out (already partially modelled) |

Consumers should ignore unknown kinds for forward-compat.
