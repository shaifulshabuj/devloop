# Sessions Layout

Every `devloop run` writes a session directory under `.devloop/sessions/`.
Sessions are append-only and safe to read concurrently from a TUI or
external monitor.

## Directory structure

```text
.devloop/
├── events.ndjson                          ← project-wide event stream
├── permissions.yaml                       ← allow/deny rules
├── permission-queue/<UUID>.json           ← pending permission escalations
├── permissions.log                        ← audit log
├── provider-health.sh                     ← failover state (sourced as bash)
├── daemon.pid, daemon.log                 ← daemon liveness
├── agent-docs/                            ← cached provider docs (24h TTL)
├── specs/
│   ├── <TASK-ID>.md                       ← architect spec
│   ├── <TASK-ID>.review.md                ← reviewer verdict
│   └── <TASK-ID>.pre-commit               ← git hash captured before worker
└── sessions/
    └── <TASK-ID>/
        ├── status                          ← single-line status (running / done / failed)
        ├── events.ndjson                   ← per-session event stream
        ├── architect.log                   ← phase log
        ├── worker.log
        ├── reviewer.log
        ├── fix-1.log, fix-2.log, …
        ├── respec.log                      ← if re-architect ran
        └── approvals/
            ├── plan.json
            └── diff.json
```

## TASK-ID format

```text
TASK-YYYYMMDD-HHMMSS
```

UTC, second precision. The CLI prints the assigned ID at the start of
every `devloop run`. Use it with `devloop session`, `devloop replay`,
`devloop resume`.

## Reading sessions safely

The bash engine writes; the TUI and other consumers only read. To follow
a session live:

```bash
tail -F .devloop/sessions/<TASK-ID>/events.ndjson | jq -c .
```

Events are emitted with unbuffered `printf >> ...`, so a tailer sees each
JSON line atomically. See [Events Stream](events.md) for the kind catalog.

## Status file

`.devloop/sessions/<TASK-ID>/status` contains a single short string:

| Value | Meaning |
|---|---|
| `running` | Pipeline is active |
| `done` | Pipeline completed (look at the final `session.end` event for `approved`/`rejected`/`needs-work`) |
| `failed` | Pipeline aborted due to error |

The TUI uses this for stuck-task detection alongside the
`DEVLOOP_STUCK_THRESHOLD_MIN` heuristic.

## Approvals

Each pre-flight gate ("approve this plan?", "approve this diff?") writes
a JSON decision into `approvals/`:

```json
{
  "ts": "2026-05-22T10:48:34Z",
  "gate": "plan",
  "decision": "approve",
  "source": "tty"
}
```

You can settle a gate non-interactively by writing the file before the
gate runs:

```bash
mkdir -p .devloop/sessions/$TASK_ID/approvals
echo '{"decision":"approve"}' > .devloop/sessions/$TASK_ID/approvals/plan.json
```

See [Events Stream — approval.request](events.md#approvalrequest) for the
gate kinds.

## Retention

```bash
DEVLOOP_SESSION_KEEP_DAYS=30      # default — sessions older than this are auto-pruned
DEVLOOP_SESSION_KEEP_DAYS=0       # disable pruning (keep all)
```

`devloop clean` removes finalized (approved/rejected) specs older than
`--days N` (default `30`).
