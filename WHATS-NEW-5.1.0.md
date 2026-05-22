# What's New — DevLoop 5.0.4 → 5.1.0

> Release date: **2026-05-16**
> Scope: this document covers everything that landed between **5.0.4** (2026-05-11)
> and **5.1.0** (2026-05-16). There are no intermediate versions — 5.1.0 is one
> coordinated release. Hot-fixes that followed (5.1.1 – 5.1.5) are listed at the
> bottom for completeness.

5.1.0 is the **interactive-control release**. The bash engine still does the
work, but you now get a real TUI dashboard, an event stream you can subscribe
to, two human-in-the-loop approval gates, and the ability to **resume** a
pipeline that timed-out or got interrupted.

---

## 1. Feature summary (at a glance)

| # | Feature | Type | Try it with |
|---|---------|------|-------------|
| 1 | Go/Bubble Tea companion **TUI** (dashboard, chat REPL, live status) | Added | `make tui-install` then `devloop` |
| 2 | Structured **event stream** (`.devloop/events.ndjson`) | Added | `tail -f .devloop/events.ndjson` |
| 3 | **Plan + diff approval gates** in `devloop run` | Added | `devloop run "feature"` (interactive) |
| 4 | **`devloop resume`** for interrupted/timed-out sessions | Added | `devloop resume --list` |
| 5 | **`devloop permissions`** — gum editor for `permissions.yaml` | Added | `devloop permissions` |
| 6 | **gum-driven `devloop configure`** wizard | Improved | `devloop configure` |
| 7 | Always-visible **status header** during `run`/`resume` | Added | `devloop run "feature"` |
| 8 | **Edit-on-reject** at the diff gate | Added | reject diff → choose "edit spec" |
| 9 | Graceful degradation when TUI/gum/TTY missing | Architecture | n/a (automatic) |

---

## 2. Detailed features & usage

### 2.1 Go/Bubble Tea companion TUI

**What it is.** A sibling Go binary (`cmd/devloop-tui/`) that gives DevLoop a
proper terminal UI without rewriting the engine. The bash engine stays the
source of truth; the TUI is a viewer + controller that talks to it through the
event stream.

**Three entry points:**

| Command | What you get |
|---------|--------------|
| `devloop` *(no args)* | Live dashboard: session picker on the left, pipeline detail on the right. Updates via `fsnotify`. |
| `devloop chat` | Slash-command REPL: `/plan`, `/run`, `/diff`, `/rollback`, `/mode`. |
| `devloop status` | Live single-session view (auto-picks the latest session). |

**Install (opt-in):**

```bash
cd /Volumes/SATECHI_WD_BLACK_2/dev/devloop
make tui-install        # builds and installs to ~/.devloop/bin/devloop-tui
```

Other targets in `Makefile`:

```bash
make tui          # build only (no install)
make tui-dev      # build + run with live reload
make tui-test     # run TUI tests
make tui-clean    # remove build artefacts
```

**Verifying it's wired up:**

```bash
ls ~/.devloop/bin/devloop-tui   # binary should exist
devloop                          # should open the dashboard
```

**Fallback behaviour.** If the binary isn't built, every bash one-shot
(`devloop run`, `devloop status`, `devloop sessions`, …) keeps working
exactly as before. `devloop chat` is the only command that *requires* the
binary; it prints a friendly install hint if missing
(see `devloop.sh:4517`).

**Force the text view even when the TUI is installed:**

```bash
DEVLOOP_STATUS_VIEW=text devloop status
```

---

### 2.2 Structured event stream — `.devloop/events.ndjson`

**What it is.** Every phase boundary in the pipeline (architect-start,
architect-done, gate-pending, gate-approved, worker-start, reviewer-done,
fix-round-N, …) now emits one **NDJSON** line to two places:

1. `.devloop/events.ndjson` — project-wide stream (single source of truth for
   the TUI and any external monitor).
2. `.devloop/sessions/<TASK-ID>/events.ndjson` — per-session mirror.

Schema is documented in [`docs/events.md`](./events.md).

**Try it.**

```bash
# Terminal A
tail -f .devloop/events.ndjson | jq .

# Terminal B
devloop run "add a /healthz endpoint" --auto
```

You'll see a stream of JSON events like:

```json
{"ts":"2026-05-16T10:11:02Z","session":"TASK-…","phase":"architect","state":"done"}
{"ts":"2026-05-16T10:11:02Z","session":"TASK-…","gate":"plan","state":"pending"}
```

**Silence it** (e.g. in CI you don't care about):

```bash
DEVLOOP_EVENTS_DISABLED=1 devloop run "…"
```

**Resume relies on this stream** — see §2.4.

---

### 2.3 Plan + diff approval gates

**What it is.** `devloop run` now pauses **twice** for human approval:

1. **Plan gate** — after the architect produces a spec, before the worker runs.
2. **Diff gate** — after the worker writes code, before the reviewer scores it.

At each gate, the gate decision can come from any of:

| Source | Use case |
|--------|----------|
| TUI button (`devloop` dashboard) | Normal interactive flow |
| `gum confirm` prompt | Terminal users without TUI |
| `/dev/tty` Y/N read | Headless terminals |
| Pre-written `.devloop/sessions/<id>/approvals/<gate>.json` | CI, scripted approvals, TUI integration |
| `DEVLOOP_AUTO=1` env or `--auto`/`-y` flag | Skip both gates (old behaviour) |

**Examples:**

```bash
# Normal interactive run (pauses at both gates)
devloop run "add user export endpoint"

# Skip both gates — non-interactive / CI
devloop run "add user export endpoint" --auto
# or
DEVLOOP_AUTO=1 devloop run "add user export endpoint"

# Settle a gate from a script (programmatic approval)
mkdir -p .devloop/sessions/$ID/approvals
echo '{"decision":"approve"}' > .devloop/sessions/$ID/approvals/plan.json
```

**Status header during gates.** The header (§2.7) shows which gate is
pending, so you always know what you're approving.

**Edit-on-reject** at the diff gate is covered in §2.8.

---

### 2.4 `devloop resume` — recover interrupted pipelines

**What it is.** If a pipeline was killed, timed out at a gate, or you closed
the terminal, you can pick it back up from the last completed phase by
replaying `events.ndjson`.

**Usage:**

```bash
# Resume the newest unfinished session
devloop resume

# Resume a specific session
devloop resume TASK-2026-05-16-001

# List everything resumable
devloop resume --list

# Show what would happen, without doing it
devloop resume --dry-run

# Force-approve the diff gate while resuming a timed-out-at-diff session
devloop resume TASK-… --approve-diff
```

**Resumable statuses:**

```
running, needs-work, timed-out-at-plan, timed-out-at-diff,
rejected-at-plan, rejected-at-diff, (absent)
```

Skipped (terminal): `approved`, `rejected` (reviewer-rejected, retries exhausted).

`devloop continue <id>` is an alias for `devloop resume <id>`.

---

### 2.5 `devloop permissions` — gum editor for `permissions.yaml`

**What it is.** A gum-driven editor for `.devloop/permissions.yaml`, which
holds `allow:` and `deny:` patterns that extend the built-in permission hook
(the thing that gates Bash/Edit calls coming from Claude/Copilot).

**Try it:**

```bash
devloop permissions
```

You'll get an interactive menu — *view current rules*, *add allow*,
*add deny*, *remove*, *open in $EDITOR*.

**File location:**

```
<project-root>/.devloop/permissions.yaml
```

**Minimal example:**

```yaml
deny:
  - "Bash(rm -rf *)"
  - "Edit(/etc/*)"

allow:
  - "Bash(npm test*)"
  - "Edit(src/**)"
```

Without `gum` installed, the command tells you to install it
(`brew install gum`).

---

### 2.6 gum-driven `devloop configure`

**What it is.** The configuration wizard was rewritten on top of `gum`:
provider selection, model picker, permission mode, failover toggle — all
keyboard-driven menus.

**Try it:**

```bash
devloop configure                  # interactive
devloop configure --yes            # accept defaults, no prompts
devloop configure --non-interactive  # same as --yes; intended for CI/Ansible
```

The schema of `devloop.config.sh` is **unchanged** — your existing config
keeps working. The wizard just produces the same file via a nicer UI.

---

### 2.7 Always-visible status header

**What it is.** During `devloop run` and `devloop resume`, a single live line
sits at the top of the output and re-renders at every stage boundary:

```
[arch ✓] [work ⠙] [review ·] [fix ·]   TASK-2026-05-16-001   add /healthz
```

Glyphs: `✓` done, `⠙` running (spinner), `·` pending, `✗` failed,
`⏸` paused at gate.

**Control:**

| Env var | Effect |
|---------|--------|
| `DEVLOOP_STATUS_HEADER=off` | suppress entirely |
| `DEVLOOP_STATUS_HEADER_FORCE=1` | bypass TTY check (useful in tests / `tee`) |

Default behaviour: **on** when stdout is a TTY, **off** otherwise.

---

### 2.8 Diff edit-on-reject

**What it is.** When you reject at the diff gate, you used to lose the work
and start over. Now rejection offers an extra option:

```
Diff rejected. What now?
  > Edit the spec in $EDITOR and re-run the worker
    Discard and end session
```

Choosing the first option opens the spec in `$EDITOR` (defaults to `vi`),
saves it, and re-runs *only the worker* against the edited spec. The
architect's output is preserved.

**Try it:**

```bash
EDITOR=code-wait devloop run "add /healthz endpoint"
# … at the diff gate, choose "reject"
# … then choose "edit spec" — VS Code opens, edit, save, close
# worker re-runs automatically
```

---

### 2.9 Architecture — graceful degradation

Not a user-facing feature, but worth knowing:

- **Engine = bash** (`devloop.sh`). Nothing was rewritten in Go.
- **TUI = sibling Go binary.** Optional. Speaks the event-stream contract.
- **Everything degrades** when an optional piece (Go binary, `gum`, `tmux`,
  TTY) is missing — falls back to plain text + `read`-based prompts.

You can adopt the new pieces incrementally — install `gum`, then the TUI,
then start using gates in CI, etc.

---

## 3. Quick-start checklist

Run these in order to exercise every new feature:

```bash
# 1. Make sure you're on 5.1.0+
devloop --version

# 2. Optional but recommended
brew install gum tmux
make tui-install

# 3. Configure (new gum wizard)
devloop configure

# 4. Edit permissions interactively
devloop permissions

# 5. Open the new TUI dashboard
devloop &

# 6. In another terminal, watch the event stream
tail -f .devloop/events.ndjson | jq .

# 7. Run a feature — you'll hit both approval gates
devloop run "add a /healthz endpoint returning 200 OK"

# 8. List resumable sessions
devloop resume --list

# 9. Resume (or dry-run resume) the most recent one
devloop resume --dry-run
devloop resume
```

---

## 4. Environment variables added/changed in 5.1.0

| Variable | Purpose |
|---|---|
| `DEVLOOP_AUTO=1` | Skip both approval gates (alias of `--auto` / `-y`). |
| `DEVLOOP_EVENTS_DISABLED=1` | Disable NDJSON event emission. |
| `DEVLOOP_STATUS_HEADER=off` | Disable the always-visible status header. |
| `DEVLOOP_STATUS_HEADER_FORCE=1` | Force header even when stdout isn't a TTY. |
| `DEVLOOP_STATUS_VIEW=text` | Make `devloop status` use the bash text view even if the TUI is installed. |
| `DEVLOOP_REVIEW_EXCLUDE` | *(v5.1.6)* Space-separated git pathspecs to exclude from the review diff. Default drops `out dist build .next .turbo coverage node_modules *.min.js *.bundle.js *.map`. Set to `none` to disable. |
| `DEVLOOP_REVIEW_MAX_BYTES` | *(v5.1.6)* Byte cap for the diff sent to the reviewer (default `150000`). Oversized diffs are truncated with a marker line. `0` disables the cap. |

---

## 5. Post-5.1.0 fixes you might want (5.1.1 – 5.1.5)

These all directly improve the 5.1.0 features above. If you're using 5.1.0
in earnest, `devloop update` to **5.1.5** is recommended:

- **5.1.1** — gates no longer hard-reject on timeout; rejected sessions are
  resumable; `devloop continue` aliased to `resume`; auto-retry on truncated
  architect spec.
- **5.1.2** — `devloop doctor` now warns about macOS system bash 3.2.
- **5.1.3** — `devloop update` validates downloads (size > 50 KB, syntax-checks,
  VERSION line) before installing.
- **5.1.4** — `devloop resume` resets `status` to `running` so Live View no
  longer shows the stale `timed-out-at-*` status.
- **5.1.5** — fixes a `((: 0\n0:` arithmetic crash in the reviewer/fix loop
  caused by `pipefail` + `grep | wc -l | … || echo 0`.
- **5.1.6** — `cmd_review` now (a) excludes build/dep dirs from the diff via
  git pathspecs, (b) caps the prompt at 150 KB (truncates with a marker), and
  (c) detects provider error replies ("Prompt is too long", rate-limit,
  context-length) and surfaces them as a distinct error instead of the
  generic "Unknown verdict" retry loop. New env: `DEVLOOP_REVIEW_EXCLUDE`,
  `DEVLOOP_REVIEW_MAX_BYTES`.

---

## 6. References

- Engine source: `devloop.sh`
- TUI source: `cmd/devloop-tui/`
- Event schema: [`docs/events.md`](./events.md)
- Full history: [`CHANGELOG.md`](../CHANGELOG.md)
- Top-level guides: [`README.md`](../README.md), [`USAGE.md`](../USAGE.md)
