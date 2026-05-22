# First Project — Worked Example

Let's walk through a real feature request end-to-end so you can see what
each phase produces and where to look when something is off.

The project: a small Go HTTP service with an `/orders` endpoint. We'll add
a `?from=&to=` date-range filter.

## Setup

```bash
cd ~/code/orders-api
devloop init --yes      # accept auto-detected defaults
devloop doctor          # verify
devloop start &         # background session, drive from claude.ai/code
```

Defaults landed:
- Main = `claude`, worker = `copilot`
- Permission mode = `smart`
- Fix strategy = `escalate`, max rounds = 5

## Run the feature

```bash
devloop run "add ?from=&to= filter to GET /orders, ISO 8601 dates, 400 on invalid"
```

## Phase 1 — Architect

A spec lands at `.devloop/specs/TASK-20260522-104812.md`:

```markdown
# Spec: Date-range filter for /orders

## Goal
Add `from` and `to` query parameters to `GET /orders` so callers can fetch
orders placed between two dates.

## Acceptance
- `from` and `to` accept ISO 8601 dates (RFC 3339).
- Either parameter may be omitted (open-ended range).
- Invalid format → HTTP 400 with `{"error":"invalid_date_format","field":"from|to"}`.
- `from > to` → HTTP 400 with `{"error":"invalid_range"}`.
- Existing callers (no params) continue to receive all orders.
...
```

The architect persona reads `CLAUDE.md`, the stack hints, and any past
lessons before writing this. Open the spec yourself with:

```bash
devloop open                # opens latest spec in $EDITOR
devloop status              # full spec + review summary
```

## Phase 2 — Worker

The worker provider receives the spec, makes the code changes, and commits.
You'll see something like:

```text
[worker] copilot: implementing TASK-20260522-104812...
[worker] modified handlers/orders.go (+34 -2)
[worker] added handlers/orders_test.go (+58)
[worker] commit: "feat: date-range filter on /orders (TASK-20260522-104812)"
```

If `DEVLOOP_WORKER_MODE=github-agent`, the worker creates a GitHub Issue
instead and the Copilot coding agent opens a PR.

## Phase 3 — Reviewer

The main provider runs `git diff <pre-commit>..HEAD` against the spec
and produces one of three verdicts:

| Verdict | Meaning | Pipeline |
|---|---|---|
| `APPROVED` ✅ | Spec satisfied, code quality acceptable | Pipeline ends |
| `NEEDS_WORK` ⚠️ | Spec partially satisfied or quality issues | Loop to fix |
| `REJECTED` ❌ | Wrong approach, restart with new spec | Re-architect |

The review is saved next to the spec at
`.devloop/specs/TASK-20260522-104812.review.md`.

## Phase 4 — Fix loop (if needed)

If the verdict is `NEEDS_WORK`, the worker runs again with the review
attached. DevLoop tracks fix rounds and escalates as they accumulate:

```text
Round 1-2  (≤ N/2):    standard fix       — latest review only
Round 3-4  (> N/2):    deep fix           — ALL prior reviews injected
Round 5+ (after N):    re-architect       — spec rewritten with failure context
```

You can disable the re-architect phase for a single run:

```bash
devloop run "..." --no-respec
```

## Phase 5 — Learn

```bash
devloop learn            # appends lessons to CLAUDE.md
devloop learn --global   # also adds to ~/.devloop/lessons.md
```

A typical lesson entry:

```markdown
## Date validation in Go HTTP handlers
- Reject `from > to` with a single 400, not two.
- Use `time.Parse(time.RFC3339, ...)` rather than custom regex.
- Add a table-driven test for boundary cases.
```

Next time the architect designs anything matching your stack, this lesson
is in its context.

---

## What if something goes wrong?

| Symptom | Look at | Fix |
|---|---|---|
| Pipeline stalls with no output | `devloop logs pipeline` and the per-phase log in `.devloop/sessions/<TASK-ID>/` | Often a permission prompt — `devloop permit watch` |
| Worker can't authenticate | `devloop doctor` | Re-auth the provider CLI |
| Rate-limit hit | `devloop failover status` | Auto-failover already triggered; check the chain |
| Tests fail after fix | `devloop session <TASK-ID>` | Add a `learn` entry; sometimes the architect's test plan was incomplete |
| Want to start over | `devloop run "..."` always starts a fresh task — old sessions stay around for replay |

## What's next

- [Pipeline concepts :material-arrow-right:](../concepts/pipeline.md){ .md-button .md-button--primary }
- [Provider & failover model :material-arrow-right:](../concepts/providers.md){ .md-button }
- [Smart Permissions :material-arrow-right:](../concepts/permissions.md){ .md-button }
