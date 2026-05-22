# Quickstart

This is the shortest path from a clean project to your first approved
feature. You'll spend about 5 minutes.

## 1. Initialize the project

```bash
cd your-project/
devloop init
```

The wizard asks you a few questions: which providers to use as main and
worker, default model, permission mode. It also **auto-detects** your stack
from `go.mod`, `package.json`, `Cargo.toml`, `pyproject.toml`, or
`requirements.txt` and writes that into `devloop.config.sh`.

What gets created:

```text
your-project/
├── devloop.config.sh        ← per-project settings (commit this)
├── .devloop/                ← runtime state (gitignored by default)
│   ├── specs/               ← architect-generated specs
│   ├── sessions/            ← per-run logs
│   ├── events.ndjson        ← live event stream
│   └── permissions.yaml     ← allow/deny lists
└── .claude/                 ← hook + agent config (if Claude is main)
```

!!! tip "Re-run the wizard anytime"
    `devloop configure` re-opens the wizard. `devloop init --merge` only
    adds missing config keys from a newer version — it never overwrites your values.

## 2. Verify the wiring

```bash
devloop doctor
```

You want all green checks. If anything is red, fix it before continuing —
the pipeline will not recover from a missing provider CLI mid-run.

## 3. Start the session

```bash
devloop start
```

What `start` does depends on your main provider:

- **Claude** → launches a **remote-control** session. Open
  [claude.ai/code](https://claude.ai/code) or the Claude mobile app and
  you'll see `DevLoop: your-project` in the session list.
- **Copilot** → launches a **remote** session via the Copilot CLI. Drive
  it from [github.com/copilot](https://github.com/copilot) or the GitHub
  mobile app.

The session also runs `caffeinate` so your Mac doesn't sleep mid-pipeline.

!!! info "Background daemon"
    Want it to survive logout and auto-restart? Use `devloop daemon`
    instead of `devloop start`. It registers a launchd (macOS) or systemd
    (Linux) unit so DevLoop comes back after a reboot.

## 4. Send a feature request

From your phone, your laptop, anywhere:

```text
add date-range filter to GET /orders, validate ISO 8601, return 400 on bad input
```

The pipeline kicks off automatically:

1. **Architect** produces a spec → `.devloop/specs/TASK-<timestamp>.md`
2. **Worker** implements the spec → commits to the current branch
3. **Reviewer** runs `git diff` against the spec → `APPROVED` or `NEEDS_WORK`
4. On `NEEDS_WORK`, **Fix** runs and the cycle repeats up to
   `DEVLOOP_MAX_FIX_ROUNDS` (default 5) before escalating

Watch it live:

```bash
devloop                  # launch the dashboard TUI (no args)
devloop view             # tmux split: architect | worker | reviewer | fix+permissions
devloop logs pipeline    # plain log tail
```

## 5. Learn from the result

When the pipeline finishes (approved or rejected), capture what was learned:

```bash
devloop learn            # extract lessons from this review → CLAUDE.md
devloop learn --global   # promote to ~/.devloop/lessons.md (stack-matched)
```

Global lessons get injected into future architect prompts for projects with
the same stack. Each run makes the next one a little smarter.

---

## Common follow-ups

| Goal | Command |
|---|---|
| Queue several features and run them sequentially | `devloop queue add "..."`, then `devloop queue run` |
| Resume an interrupted pipeline | `devloop resume` (or `--list` first) |
| See all past sessions | `devloop sessions --last 20` |
| Show metrics: approval rate, avg phase time | `devloop stats` |
| Switch providers mid-project | `devloop configure` |
| Force a manual failover | `devloop failover worker opencode` |

## What's next

- [First Project — a full worked example :material-arrow-right:](first-project.md){ .md-button .md-button--primary }
- [Pipeline concepts :material-arrow-right:](../concepts/pipeline.md){ .md-button }
- [Full command reference :material-arrow-right:](../reference/commands.md){ .md-button }
