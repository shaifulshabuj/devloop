# The Pipeline

`devloop run "feature"` is the headline command. It walks five phases.
Every other command is either a tool to inspect those phases or a knob
to tune them.

## Phase diagram

```mermaid
flowchart TD
  Start([devloop run "feature"]) --> A[Architect<br/>main provider]
  A -->|spec.md| W[Worker<br/>worker provider]
  W -->|git commit| R[Reviewer<br/>main provider]
  R -->|APPROVED| L[Learn]
  R -->|NEEDS_WORK| FixCheck{Round &lt; N/2?}
  FixCheck -->|yes| F1[Standard fix]
  FixCheck -->|no| FixCheck2{Round &lt; N?}
  FixCheck2 -->|yes| F2[Deep fix<br/>all history injected]
  FixCheck2 -->|no| Re[Re-architect<br/>fresh spec + retry]
  F1 --> R
  F2 --> R
  Re --> W
  L --> End([approved ✅])
  R -->|REJECTED| End2([rejected ❌])
```

## Phase 1 — Architect

The **main provider** plays the architect role. It reads:

- Your natural-language feature request
- `CLAUDE.md` (project conventions)
- `~/.devloop/lessons.md` entries matching this stack
- Optional `--files` hints (specific paths to focus on)
- The current git diff and HEAD (so it knows what's in-flight)

It writes a spec to `.devloop/specs/TASK-<timestamp>.md` with a Goal,
Acceptance criteria, suggested file changes, and a Test Plan. Open it
with `devloop open` or `devloop status`.

## Phase 2 — Worker

The **worker provider** receives the spec and implements it. The flow
depends on `DEVLOOP_WORKER_MODE`:

| Mode | What happens |
|---|---|
| `cli` (default) | Runs the worker provider CLI locally with the spec as input. The provider commits directly. |
| `github-agent` | Opens a GitHub Issue describing the spec. The Copilot coding agent picks it up and opens a PR. DevLoop polls for the PR. |

The worker's exit code matters: if it fails to commit, the pipeline
records the failure and skips review.

## Phase 3 — Reviewer

The **main provider** reviews `git diff <pre-commit>..HEAD` against the
spec. The `pre-commit` hash is captured at the start of the worker phase
so the diff is exactly what the worker produced.

Three possible verdicts:

| Verdict | Meaning | Next |
|---|---|---|
| `APPROVED` | Spec satisfied, quality OK | Learn → done |
| `NEEDS_WORK` | Spec partially satisfied | Fix loop |
| `REJECTED` | Wrong approach entirely | Pipeline exits; you decide whether to re-run |

The review lands at `.devloop/specs/<TASK-ID>.review.md` and is logged in
the session events stream.

## Phase 4 — Fix (when verdict is NEEDS_WORK)

See [Fix Escalation](fix-escalation.md) for the full strategy. Briefly:

- Rounds 1 to `N/2` — **standard fix**: only the latest review is sent
  to the worker.
- Rounds `N/2 + 1` to `N` — **deep fix**: all prior reviews are
  concatenated and injected so the worker can see why earlier attempts
  failed.
- After `N` rounds — **re-architect**: the spec is regenerated with
  failure context, then a fresh worker + reviewer cycle (2 attempts).

Tunables:

- `DEVLOOP_MAX_FIX_ROUNDS` (default `5`)
- `DEVLOOP_FIX_STRATEGY=escalate` (default) or `standard`
- `--no-respec` on `devloop run` to skip Phase 3 for one run

## Phase 5 — Learn

When the pipeline lands on `APPROVED`, the engine optionally extracts
lessons from the review and appends them to:

- `CLAUDE.md` — project-local lessons
- `~/.devloop/lessons.md` — global, stack-matched, injected into future
  architect prompts

Trigger manually:

```bash
devloop learn               # project only
devloop learn --global      # also global
devloop learn --no-learn    # opt out per-run via run flag
```

## Idempotency & resumability

Every phase boundary writes an event to `.devloop/events.ndjson` and the
per-session `events.ndjson`. If the pipeline is interrupted (Ctrl-C,
SIGHUP, reboot), `devloop resume` reads those events to pick up at the
last completed phase:

```bash
devloop resume                # most recent task
devloop resume --list         # show resumable sessions
devloop resume TASK-20260522-104812
```

## Inspect a run

| Command | Output |
|---|---|
| `devloop tasks` | All specs with current status |
| `devloop sessions --last 10` | Recent runs with timing and verdict |
| `devloop session <TASK-ID>` | Phase timeline + log sizes |
| `devloop status [TASK-ID]` | Full spec + latest review (live TUI) |
| `devloop replay <TASK-ID>` | Replay recorded phase logs |
| `devloop stats` | Approval rate, avg phase time, fix rounds |
