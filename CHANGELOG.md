# Changelog

All notable changes to DevLoop are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [5.1.4] — 2026-05-17

### Fixed

- **Live View shows stale status after `devloop resume`**: when a session timed out
  (`timed-out-at-plan` / `timed-out-at-diff`) and was resumed, the `status` file in
  the session directory was never reset — so Live View kept showing the old status
  even while the resumed pipeline was running. Now `cmd_resume` immediately resets
  `status` to `"running"` and removes `finished_at` before re-launching the pipeline.

---

## [5.1.3] — 2026-05-17

### Fixed

- **`devloop update` truncation guard**: the previous sanity check only verified the
  downloaded file contained the word "devloop" — a partially downloaded file would pass
  and get installed, causing `unexpected EOF while looking for matching '"'` errors.
  Now validates three things before installing:
  1. File size must be > 50 KB (truncated downloads are rejected)
  2. `VERSION=` line must be present (confirms it's a devloop script)
  3. `bash -n` syntax check must pass (catches corrupted downloads)

---

## [5.1.2] — 2026-05-17

### Fixed

- **`devloop doctor` bash version check**: warns when running on macOS system bash (3.2.x)
  and suggests `brew install bash` to upgrade. macOS ships bash 3.2 for licensing reasons;
  bash 4+ is recommended but not required.

---

## [5.1.1] — 2026-05-17

### Fixed — pipeline stuck-state recovery

- **Approval gate timeout** no longer hard-rejects the pipeline. `_approval_gate` now
  returns exit code 3 (stalled) vs 1 (active rejection). Callers set
  `timed-out-at-plan` / `timed-out-at-diff` status and show a
  `devloop resume <id>` recovery hint instead of leaving the session stranded.
- **`devloop resume`** re-presents only the correct gate when resuming a
  timed-out or user-rejected session:
  - `timed-out-at-diff` / `rejected-at-diff` → re-shows diff gate, skips re-running the worker.
  - `timed-out-at-plan` / `rejected-at-plan` → re-shows plan gate, re-runs from plan approval.
  - `rejected-at-plan` and `rejected-at-diff` are now resumable (were previously treated as terminal).
  - `--approve-diff` flag force-approves the diff gate when resuming a `timed-out-at-diff` session.
- **`devloop continue <id>`** now works as an alias for `devloop resume <id>` — no longer
  misrouted to the natural-language router as a new task.
- **Incomplete spec validation** in `cmd_architect`: if the LLM omits the
  `## Copilot Instructions Block`, the architect retries up to 2 times before
  failing with an actionable error message.
- **Auto-re-architect in `devloop run`**: if `cmd_architect` exits non-zero (e.g. spec
  truncated), the pipeline automatically retries architect once before giving up.
- **Plan-gate warning**: `_extract_plan_summary` now appends a `⚠ WARNING` when
  `## Copilot Instructions Block` is missing from the spec, so the user can catch
  it before approving the plan and sending an incomplete spec to the worker.
- **`cmd_work` error improved**: missing Instructions Block now shows exact
  `devloop architect "<feature>"` and `devloop work <id>` commands for recovery.

---

## [5.1.0] — 2026-05-16

### Added — TUI dashboard, chat REPL, approval gates, resume

- **Go/Bubble Tea companion TUI** (`cmd/devloop-tui/`): `devloop` (no args)
  opens a live dashboard with session picker + pipeline detail; `devloop chat`
  opens a slash-command REPL (`/plan`, `/run`, `/diff`, `/rollback`, `/mode`);
  `devloop status` shows live single-session view. Opt-in — install with
  `make tui-install`. Bash one-shot commands keep working when the binary is
  absent.
- **Structured event stream** at `.devloop/events.ndjson` (NDJSON). Schema
  documented in `docs/events.md`. Per-session mirror at
  `.devloop/sessions/<TASK-ID>/events.ndjson`. Engine emits at every phase
  boundary; TUI consumes via fsnotify. `DEVLOOP_EVENTS_DISABLED=1` to silence.
- **Plan + diff approval gates** between pipeline stages. `devloop run` now
  pauses after architect (plan review) and after worker (diff review). Skip
  with `--auto` / `-y` or `DEVLOOP_AUTO=1`. Gate decisions also settle from
  a pre-written `approvals/<gate>.json` file — same contract works in TUI,
  gum, `/dev/tty`, and CI.
- **`devloop resume [TASK-ID]`** — pick up an interrupted pipeline from the
  last completed phase by replaying `events.ndjson`. `--list` shows
  resumable sessions; `--dry-run` prints the planned action without
  executing.
- **`devloop permissions`** — gum-driven editor for `.devloop/permissions.yaml`
  (allow/deny patterns extending the built-in permission hook).
- **gum-driven `devloop configure`** — interactive wizard for provider,
  models, permission mode, failover toggle. `--non-interactive` / `--yes`
  for headless reruns. Schema of `devloop.config.sh` unchanged.
- **Always-visible status header** in `devloop run` / `devloop resume`:
  `[arch ✓] [work ⠙] [review ·] [fix ·]  TASK-…  feature`. Re-renders at
  each stage boundary. No-op when stdout isn't a TTY or
  `DEVLOOP_STATUS_HEADER=off`.
- **Diff edit-on-reject** — rejecting at the diff gate can open the spec in
  `$EDITOR` and re-run the worker against the edited spec.

### Architecture

- Engine stays bash (`devloop.sh`); the TUI is a sibling Go binary, not a
  rewrite. Both speak the event-stream contract; everything degrades
  gracefully when optional pieces (Go binary, `gum`, TTY) are missing.

---

## [5.0.4] — 2026-05-11

### Fixed — permission hook noise + double macOS dialog

- **Auto-approve `devloop` pipeline commands**: `devloop status`, `devloop logs`, `devloop --help`,
  `devloop view`, `devloop check`, `devloop version`, `devloop sessions`, `devloop recent`
  no longer trigger the permission prompt — these are safe read-only devloop operations
- **Auto-approve for-loop file reads**: `for f in *.md; do head -5 "$f"; done` style loops
  (read-only over project files) are now approved without prompting
- **Auto-approve all-safe pipelines**: When every pipe segment is a known-safe command
  (cat, head, tail, grep, echo, sed, awk, jq, git status/log/diff, devloop status/logs/help),
  the whole pipeline is auto-approved
- **Fixed double-dialog bug**: macOS dialog (Path B) now only fires when the terminal
  interactive prompt (Path A) was NOT available or did not get a response — previously
  both could fire simultaneously for the same request

---

## [5.0.3] — 2026-05-11

### Fixed — tmux pane navigation (mouse + nested tmux)

- **Mouse enabled by default**: tmux sessions created by `devloop run` now run with `mouse on`,
  so you can click any pane to focus it without knowing tmux keybindings
- **Better navigation hints**: Status pane now shows `[click]` and `Ctrl-b ←` as alternatives
  to `Ctrl-b o`, plus a nested-tmux hint (`Ctrl-b Ctrl-b ←`)
- **Cleaner session startup**: Auto-view now creates the tmux session detached, enables mouse,
  sends the devloop command, then attaches — previously mouse could not be enabled before `exec`
- **If already in tmux**: `devloop run` now sets `mouse on` in the current tmux session so the
  status pane split is also clickable

---

## [5.0.0] — 2026-05-10

### Major Release — Global Management Layer

DevLoop v5.0 adds a global management layer (`~/.devloop/`) that spans all projects.
All features are backwards-compatible: project-local devloop still works without any global config.

#### Phase 1 — Global Config Layer
- `~/.devloop/config.sh` bootstrapped on first run (global defaults, project always overrides)
- `devloop configure --global` — edit global defaults in `$EDITOR`

#### Phase 2 — Project Registry
- `~/.devloop/projects.json` — registry updated on `devloop init` and `devloop run`
- `devloop projects` — list all registered projects with status
- `devloop projects switch <name>` — print `cd` command to jump to a project

#### Phase 3 — Human Inbox
- `devloop inbox` — view/resolve all pending NEEDS_WORK and REJECTED events
- `--all` — cross-project inbox view
- macOS `osascript` notifications on pipeline events
- `DEVLOOP_NOTIFY_WEBHOOK` for Slack/Discord webhook integration

#### Phase 4 — Pipeline Stats
- `devloop stats` — aggregated metrics: approval rate, fix rounds, phase durations, top fix reasons

#### Phase 5 — Lesson Federation
- `devloop learn --global` — promote extracted lessons to `~/.devloop/lessons.md`
- Architect prompts automatically inject relevant global lessons filtered by `PROJECT_STACK`

#### Phase 6 — Smart Update Propagation
- `devloop init --merge` — safe re-init that only adds missing config keys
- After `devloop update`, automatically merges new config keys to all registered projects
- `DEVLOOP_AUTO_MERGE=false` to opt out per-project

---

## [4.17.0] — 2026-05-10

### Added
- **`devloop init --merge`**: safe re-init that only adds missing config keys from the latest
  devloop version — does not overwrite existing values or re-run the wizard.
- **Update propagation**: after `devloop update` installs a new binary, automatically iterates
  all registered projects in `~/.devloop/projects.json` and merges new config keys into each
  project's `devloop.config.sh` (respects `DEVLOOP_AUTO_MERGE=false` to skip per-project).
- **Help text**: `devloop init --merge` documented.

---

## [4.16.0] — 2026-05-10

### Added
- **Lesson Federation** (`devloop learn --global`): promotes extracted lessons from a project
  review into the shared `~/.devloop/lessons.md` global store, tagged by stack.
- **Global lesson injection**: architect prompts automatically include relevant global lessons
  from `~/.devloop/lessons.md` filtered by `PROJECT_STACK` (and "All Stacks" entries).
- **Deduplication**: the AI is shown existing global lessons to avoid adding duplicates when
  promoting with `devloop learn --global`.
- **Help text**: `devloop learn --global` documented.

---

## [4.15.0] — 2026-05-10

### Added
- **`devloop stats`**: aggregated pipeline metrics across all recorded sessions for the current
  project: total runs, approval rate, NEEDS_WORK/REJECTED counts, avg fix rounds, avg phase
  durations (architect/worker/reviewer), and a recent-runs summary table.
- **Help text**: `devloop stats` documented.

---



### Added
- **Human inbox (`devloop inbox`)**: every REJECTED pipeline result or max-retries NEEDS_WORK
  event now writes a structured entry to `.devloop/inbox.json`.
- **`_inbox_write()`**: internal helper to append items to the project inbox; includes type,
  message, task ID, tool, and command fields.
- **`devloop inbox`**: view pending items (permission requests, NEEDS_WORK, blocked tasks).
- **`devloop inbox --all`**: view pending items across all registered projects.
- **`devloop inbox resolve <id>`**: mark an item as approved/denied/skipped.
- **`devloop inbox history`** / **`devloop inbox clear`**: view or remove resolved items.
- **macOS notifications**: `_inbox_write()` fires a native macOS notification (with sound)
  whenever a new item is added. Controlled by `DEVLOOP_NOTIFY_SOUND` config key.
- **Webhook support**: `_inbox_write()` posts a JSON payload to `DEVLOOP_NOTIFY_WEBHOOK`
  (Slack/Discord compatible) on every inbox event.
- **Help text**: full `devloop inbox` documentation added.

---



### Added
- **Project registry (`~/.devloop/projects.json`)**: `devloop init` and `devloop run` now
  automatically register the current project in a global registry. The registry tracks
  path, name, stack, providers, and last-run timestamp.
- **`devloop projects`**: list all registered projects with name, stack, providers, last-run
  age, and status (IDLE / DAEMON ▶ / MISSING).
- **`devloop projects switch <name>`**: prints the path to a registered project; use
  `eval $(devloop projects switch myapp)` to cd into it.
- **`_register_project()` / `_unregister_project()`**: internal helpers for registry management.
- **Help text**: `devloop projects` and `devloop projects switch` documented.

---

## [4.12.0] — 2026-05-10

### Added
- **Global config layer (`~/.devloop/config.sh`)**: DevLoop now bootstraps a global user config
  directory (`~/.devloop/`) on first run. Users can set provider, model, permission mode, and
  other defaults once globally, and all projects inherit them automatically.
- **Load order**: hardcoded defaults → global `~/.devloop/config.sh` → project `devloop.config.sh`.
  Project config always wins.
- **`_ensure_global_dirs()`**: silently creates `~/.devloop/` structure (config.sh template,
  projects.json registry, lessons.md, logs/) on every run if not already present.
- **`load_global_config()`**: sources `~/.devloop/config.sh` before project config; safe no-op
  if file absent.
- **`devloop configure --global`**: opens `~/.devloop/config.sh` in `$EDITOR` (or falls back to
  nano/vi). Shows current active (non-commented) values before opening.
- **`devloop doctor` global config section**: checks `~/.devloop/` exists, reports how many keys
  are customized, and shows registered project count.
- **Help text updated**: `devloop configure --global` documented in `devloop help`.
- **New global config keys**: `DEVLOOP_NOTIFY_WEBHOOK` (Slack/Discord webhook on pipeline events),
  `DEVLOOP_NOTIFY_SOUND` (macOS notification sound), `DEVLOOP_FAILOVER_ENABLED`,
  `DEVLOOP_PROBE_INTERVAL` — all documented and commented-out in the global config template.

---

## [4.11.4] — 2026-05-10

### Fixed
- **`_launch_copilot_session` was broken**: the previous implementation ran a non-interactive
  one-shot prompt (`-p`) to inject context, then immediately started a second interactive session
  without any of that context. Now uses `-i/--interactive` to start interactive mode with the
  orchestrator context injected as the opening message.
- **Copilot remote control was disabled**: Copilot CLI v1.0.44+ supports `--remote` for accessing
  sessions from GitHub web (github.com/copilot) and the GitHub mobile app. DevLoop now passes
  `--remote` and `--name "DevLoop: <project>"` to `_launch_copilot_session` so Copilot sessions
  appear in the GitHub remote session list, matching Claude's remote-control capability.
- **`--allow-all` used for Copilot interactive sessions**: replaces the deprecated
  `--allow-all-tools --allow-all-paths` combination in `_launch_copilot_session`.

### Updated
- Help text: Copilot as main provider now correctly described as supporting remote access via
  GitHub web and mobile (not "local only").
- `devloop start`, `devloop daemon`, and `devloop help` updated to show GitHub remote access
  instructions when Copilot is the main provider.
- Daemon mode no longer warns that Copilot has "no remote control available".

---

## [4.11.3] — 2026-05-09

### Fixed (found during todo-app test run)
- **`devloop failover/daemon/tools/hooks/start <subcommand>` was intercepted as NL**: removed
  these commands from the NL pre-detection list — they accept subcommands and must not be treated
  as prose starters. Only truly zero-arg utility commands remain in the list.
- **`devloop view` overview pane used `watch -n 2`**: `watch` is not installed by default on
  macOS. Replaced with a portable `while true; do ... sleep 2; done` bash loop.
- **`DEVLOOP_AUTO_VIEW=true` env var was silently overwritten by `load_config`**: default
  assignment used `VAR="false"` (always overwrite) instead of `: "${VAR:=false}"` (only set if
  unset). `DEVLOOP_AUTO_VIEW=true devloop run "..."` now works correctly.

---

## [4.11.0] — 2026-05-09

### Fixed
- **Session discovery cross-terminal**: `devloop view` now works even when run from a different
  directory/terminal than where `devloop run` was started. `_session_init` writes the absolute
  session path to `~/.devloop/last-session`; `cmd_view` uses this as a fallback when the
  project-root-based lookup returns no results.

### Improved
- **Auto-view opens immediately**: When `DEVLOOP_AUTO_VIEW=true` and tmux is available, `devloop run`
  now re-execs the entire pipeline inside a new tmux session **before** the architect phase starts,
  so the user sees all output from the very beginning inside a tmux pane. A live status pane is
  added on the right (30% width) after the session ID is known, showing phase states in real time.
  No second terminal is required.
- Removed the old post-architect background-subshell auto-view approach.

---

## [4.10.0] — 2026-05-09

### Added
- **Live session log streaming** — agent output is now tee'd to session phase log files in real-time
  while the pipeline runs. `run_provider_prompt` and `cmd_work` both write to
  `DEVLOOP_SESSION_PHASE_LOG` (set by `_session_phase_start`) when session logging is active.
  This means `devloop view` / `tail -f` show output as it arrives, not just at phase end.
- **`devloop replay <id> [--phase PHASE]`** — replay recorded phase logs from a completed session
  with optional phase filter (architect | worker | reviewer | fix-N | respec)
- **`DEVLOOP_AUTO_VIEW=true`** support — when set, `devloop run` automatically opens the tmux
  dashboard after the architect phase completes (requires tmux)
- **`DEVLOOP_SESSION_KEEP_DAYS=30`** config — sessions older than N days are auto-pruned at the
  start of each new run (0 = keep forever). Pruning runs in background so it never blocks.
- **Decision + Permission integration in tmux view** — the Fix/Decisions pane now also runs
  `devloop permit watch` alongside fix log tailing, surfacing any agent permission requests
  directly in the live dashboard so the user can approve/deny without leaving the view.
- `_session_prune()` helper for background old-session cleanup
- `unset DEVLOOP_SESSION_PHASE_LOG` in `_session_finish` to prevent log leakage between sessions

### Changed
- `_session_phase_start` now exports `DEVLOOP_SESSION_PHASE_LOG` env var pointing to the current
  phase log file (used by run_provider_prompt and cmd_work for live tee)
- tmux decisions pane command updated to combine fix-log tailing with permit watch

---

## [4.9.0] — 2026-05-09

### Added
- **Session logging infrastructure** — every `devloop run` now creates a structured
  session directory under `.devloop/sessions/<task-id>/` containing:
  - `feature.txt` — feature description
  - `status` — running | approved | needs-work | rejected
  - `started_at` / `finished_at` — ISO timestamps
  - `<phase>.log` — live-appended agent output per phase (architect/worker/reviewer/fix-N/respec)
  - `<phase>.state` — current phase status + timestamp (used by tmux view)
  - `decisions/pending/` + `decisions/approved/` — reserved for Phase 3 decision propagation
- **`devloop sessions`** — list all past pipeline runs with status, duration, feature description
  - Flags: `--last N` (limit), `--status approved|running|needs-work|rejected`
- **`devloop session <id>`** — detail view: phase timeline, log file sizes, live-tail or recent log lines
- **`devloop view [id]`** — tmux-based live dashboard with 4 panes:
  - 🏗 Architect | 🔨 Worker | 🔍 Reviewer | ⚡ Fix/Decisions
  - Auto-selects most recent session if no id given
  - Falls back to inline `tail -f` with install hint if tmux is not available
  - If already inside tmux: `switch-client` instead of `attach-session`
- Session logging hooks in `cmd_run`: phase start/end timestamps tracked automatically
- `DEVLOOP_SESSION_LOGGING=true` config variable (enable/disable)
- `DEVLOOP_AUTO_VIEW=false` config variable (reserved for v4.10 auto-open)
- Help text: new **SESSION VIEWER** section; `sessions`, `session`, `view` listed in commands

### Changed
- `cmd_run` pipeline completion message now includes `devloop session <id>` hint

---



### Added
- **3-phase fix escalation** in `devloop run` — replaces the hard "max retries" exit
  with a graduated recovery strategy:
  - **Phase 1** (rounds 1..N/2): standard fix — latest review fed to worker (unchanged)
  - **Phase 2** (rounds N/2+1..N): deep fix — all accumulated review history injected
    so the worker understands why previous fixes failed and takes a different approach
  - **Phase 3** (after N rounds): re-architect — the spec is redesigned using all failure
    context, then a fresh work + review cycle runs (up to 2 additional attempts)
- `DEVLOOP_FIX_STRATEGY` config variable (`escalate` default | `standard` = old behaviour)
- `--no-respec` flag on `devloop run` — skip Phase 3 (re-architect) for a single run
- `cmd_fix --history <text>` — optional flag to inject accumulated review history into the fix prompt
- `_run_respec_phase()` internal helper — handles Phase 3 re-architect flow
- Help text: new **FIX ESCALATION STRATEGY** section documents phases, config, and flags

### Changed
- `devloop run` usage line updated to include `--no-respec` flag
- Fix loop stage label now reflects current phase: "standard", "deep", or "re-architect"

---

## [4.7.0] — 2026-05-09

### Added
- **Provider-aware session launch** — `devloop start` and `devloop daemon` now
  respect `DEVLOOP_MAIN_PROVIDER` and launch the correct provider session:
  - **Claude** (default): unchanged — `claude --remote-control "DevLoop: <name>"`
    with orchestrator agent. Access from claude.ai/code or the Claude mobile app.
  - **Copilot**: launches `copilot` interactive mode locally. Orchestrator agent
    context is injected as initial prompt. Note: Copilot CLI has no remote-control
    equivalent; the session runs in the local terminal only.

### Changed
- `_launch_claude()` renamed to `_launch_session()` (dispatches by provider);
  `_launch_claude_session()` and `_launch_copilot_session()` are the per-provider
  implementations.
- `cmd_start` connect-from messaging is now conditional per provider:
  - Claude → mobile app + claude.ai/code links
  - Copilot → "terminal session only" notice with hint to use Claude for remote access
- `cmd_daemon` messaging likewise conditional; warns when Copilot is main provider
  (daemon restarts local session; no remote control available).
- Help text (`devloop help`, `devloop start --help`) updated to document
  per-provider session capabilities.

---

## [4.6.3] — 2026-05-09

### Added
- **Natural language mode** — `devloop` now understands plain English commands:
  - `devloop do <task>` — new first-class command (aliases: `ask`, `please`, `nl`).
    Joins all args as-is into a task description, no quoting required.
    Example: `devloop do check the latest progress and work on remaining tasks`
  - **Auto-detection** — when a "utility" command (`check`, `update`, `status`,
    `start`, `doctor`, etc.) is followed by plain-English words (not `--flags` or
    `TASK-` IDs), DevLoop automatically routes to the NL pipeline instead of the
    literal command. Fixes: `devloop check the latest progress...` no longer
    triggered the version checker.
  - Unknown multi-word commands also route to NL pipeline with a helpful tip.

---

## [4.6.2] — 2026-05-09

### Fixed
- `devloop check` / `devloop update`: version check and script download now use
  `gh api` / `gh release download` (authenticated) when `gh` CLI is available —
  fixes "Could not determine remote version" on **private repos** where unauthenticated
  `curl` gets a 404 from GitHub API. Falls back to curl for public repos.

---

## [4.6.1] — 2026-05-09

### Fixed
- `devloop init`: fixed `_args[@]: unbound variable` crash on Bash 3.2 (macOS default)
  when no extra arguments are passed — empty array expansion under `set -u` now
  uses `[[ ${#_args[@]} -gt 0 ]]` guard instead of bare `"${_args[@]}"`

---

## [4.6.0] — 2026-05-09

### Added
- **Interactive setup wizard** — `devloop init` now runs a 4-step interactive wizard on first initialization:
  1. **Main provider** — choose claude or copilot (detects what's installed)
  2. **Worker provider** — choose copilot, claude, opencode, or pi
  3. **Claude models** — separate model for main roles vs worker roles (sonnet / opus / haiku)
  4. **Permission mode** — smart / auto / strict / off
- Wizard detects installed providers and marks them `✔ installed` or `⚠ not found`.
- Selections are saved directly to `devloop.config.sh` — no manual editing required.
- **`devloop init --yes` / `-y`** — skip wizard, use auto-detected defaults (CI-friendly).
- **`devloop init --configure` / `-c`** — re-run wizard on an already-initialized project.
- **`devloop configure`** (aliases: `setup`, `wizard`) — standalone command to re-run the wizard anytime.
  After wizard completes, regenerates agent prompt files automatically.
- Updated SETUP section in `devloop help` with new wizard-aware instructions and correct GitHub raw URL.

### Changed
- `_write_default_config`: `CLAUDE_MAIN_MODEL` and `CLAUDE_WORKER_MODEL` are now initially commented-out hints in the template — the wizard writes them when chosen.

---

## [4.5.0] — 2026-05-09

### Added
- **`CLAUDE_MAIN_MODEL`** — separate model setting for architect/reviewer/orchestrator (main) roles. Overrides `CLAUDE_MODEL` when set.
- **`CLAUDE_WORKER_MODEL`** — separate model setting for worker/fix roles. Overrides `CLAUDE_MODEL` when set.
- Backward-compatible: `CLAUDE_MODEL` still works as a shared default for both roles.
- Example config: `CLAUDE_MAIN_MODEL="opus"` (quality reviews) + `CLAUDE_WORKER_MODEL="sonnet"` (fast implementation)
- **`devloop status`** now shows which Claude model each role uses.
- **`devloop help`** has a new **MODEL CONFIGURATION** section explaining model settings and the Copilot model limitation.
- **`devloop agent-sync`** context file now documents active models per role and Copilot model note.
- **`_refresh_project_for_version()`** now uses the correct per-role models when refreshing agent prompts.
- **Copilot model documentation** throughout: Copilot CLI has no `--model` flag; model is set at `github.com/settings/copilot`.

### Changed
- `devloop.config.sh` template now has `CLAUDE_MAIN_MODEL` and `CLAUDE_WORKER_MODEL` as documented (commented-out) overrides.

---

## [4.4.0] — 2026-05-10

### Added
- **GitHub-native version checking** — `devloop check` and `devloop update` now work out-of-the-box with no configuration. Uses the GitHub Releases API (`/releases/latest`) automatically; `DEVLOOP_VERSION_URL` / `DEVLOOP_SOURCE_URL` are still honoured as overrides.
- **`DEVLOOP_GITHUB_REPO`** built-in default (`shaifulshabuj/devloop`) — forks can override this single variable to point all version/update machinery at their own repo.
- **`_gh_latest_version()`** — queries GitHub releases API and extracts semver; uses `python3` JSON parsing with a `grep` fallback.
- **Version hint banner** — `devloop start` and `devloop run` now show a non-blocking update notice the next time they run after a new release is detected in the background.
- **`_refresh_project_for_version()`** — after `devloop update`, automatically refreshes Claude hooks, agent prompt files, the `CLAUDE.md` managed block, and merges any new default config keys into `devloop.config.sh`. Safe to re-run (idempotent).
- **Updated `devloop doctor` version check** — uses GitHub API by default; no longer skips with "DEVLOOP_VERSION_URL not set" message.
- **`cmd_help` improvements** — `check` and `update` descriptions now accurately state no config is required.

### Fixed
- Stray extra `}` in `cmd_check()` body (syntax error from prior refactor).
- `cmd_update` config template comments updated to reflect that URL overrides are optional, not required.

---

## [4.3.0] — 2026-05-09

### Added
- **`devloop run` (alias: `go`)** — full automated pipeline in one command: `architect → work → review → [fix → review]* → learn`. Replaces the need to manually chain 4–6 commands per task. Supports `--type`, `--files`, `--max-retries` (default 3), `--no-learn` flags.
- **`devloop queue` (alias: `q`)** — batch task management. Queue multiple tasks with `queue add`, inspect with `queue list`, run them all sequentially with `queue run` (supports `--stop-on-fail`), and `queue clear`. Failed tasks stay in queue for retry. Queue stored in `.devloop/queue.txt`.
- **Natural language routing** — unknown multi-word commands (e.g. `devloop add a dark mode toggle`) automatically route to `devloop run` with a tip to use the explicit form next time.
- **Improved unknown-command UX** — single-word unknown commands now show a helpful tip suggesting `devloop run` instead of dumping the full help text.

---

## [4.2.0] — 2026-05-09

### Added
- **Smart permission gate** (`devloop hooks`): Claude `PreToolUse` hook classifies every Bash command — BLOCK dangerous commands (`rm -rf /`, `curl|bash`, etc.), ALLOW known-safe commands (git, pytest, npm test, make, linters), ESCALATE unknowns (asks user via tty → osascript dialog → queue file → auto-deny)
- **`devloop permit` command**: inspect and manage the permission gate with `status`, `watch`, `grant`, `deny`, `log`, `mode` subcommands
- **PostToolUse audit log**: every tool call recorded to `.devloop/permissions.log`
- **Permission modes**: `smart` (default), `auto`, `strict`, `off` — set via `DEVLOOP_PERMISSION_MODE`
- **Permission escalation timeout**: `DEVLOOP_PERMISSION_TIMEOUT` (default: 60s) before auto-deny

### Fixed
- **Copilot non-interactive permission wall**: all `copilot` invocations now use `--allow-all-tools --allow-all-paths -p "<prompt>"` — fixes "Permission denied and could not request permission from user" that blocked workers and reviewers in pipe mode
- **Copilot `-p` flag syntax**: corrected from `echo ... | copilot -p` (broken) to `copilot -p "$prompt"` (correct — `-p` is a required argument, not a stdin flag)
- **Claude worker tool scope**: `cmd_work` and `cmd_fix` now pass `--allowedTools` to `claude -p` workers to restrict to file ops, git, and test runners
- **Claude reviewer tool scope**: `run_provider_prompt` uses read-only tool set for architect/reviewer roles
- **Auto-recovery messaging**: removed stale "re-test after 6h" — recovery is probe-based (`DEVLOOP_PROBE_INTERVAL` minutes, default 5)

### Documentation
- README: expanded `devloop hooks` (all 7 hooks + permission tier table), new `devloop permit` section, updated file structure with hook scripts and permission files, updated `.gitignore` recommendations
- USAGE.md: new Scenario 6 — Smart Permissions end-to-end walkthrough; updated Scenario 2 hooks step; expanded Quick Reference

---

## [4.1.0] — 2026-05-09

### Changed

- `devloop init` now auto-populates stack/config values from project analysis in the first run and reports the auto-config update count.
- README and USAGE docs updated for auto-analysis-first setup flow.
- VERSION bumped to `4.1.0`.

---

## [4.0.0] — 2026-05-09

### Changed

- `devloop init` now merges/upserts existing project files instead of skipping them:
  - `devloop.config.sh`: appends missing default keys without overwriting existing values.
  - `CLAUDE.md`: updates/inserts the DevLoop-managed block (`DEVLOOP:CLAUDE` markers) while preserving custom content.
  - `.github/copilot-instructions.md`: updates/inserts the DevLoop-managed block (`DEVLOOP:COPILOT` markers) while preserving custom content.
- `devloop init` now analyzes the current project to auto-populate placeholder config fields (`PROJECT_STACK`, `PROJECT_PATTERNS`, `PROJECT_CONVENTIONS`, `TEST_FRAMEWORK`).
- VERSION bumped to `4.0.0`.

---

## [3.1.0] — Tools, Skills & MCP Management

### Added

**`devloop tools` command family — project-level tooling management**

- `devloop tools audit` — full inventory: global vs project MCP servers, skills, plugins, hooks, and Copilot instructions. Shows gaps and sync status at a glance.
- `devloop tools suggest` — reads `PROJECT_STACK` from `devloop.config.sh` and recommends MCP servers, Claude plugins, skills, and Copilot path instructions tailored to the stack.
- `devloop tools add` — interactive numbered picker; installs selected tools. Also supports non-interactive flags: `--mcp`, `--skill`, `--instruction`, `--plugin`.
- `devloop tools sync` — prompts to copy global MCP servers (`~/.claude.json`) and skills (`~/.claude/skills/`) to project level per item.

**Dual MCP config writing (Claude + Copilot)**
- `_add_mcp_to_project()` writes MCP servers to **both** `.mcp.json` (Claude; `mcpServers` key) and `.vscode/mcp.json` (Copilot/VS Code; `servers` key with `type: stdio`) in one call, auto-translating schemas.

**Claude skill scaffolding**
- `_scaffold_skill()` creates `.claude/skills/<name>/SKILL.md` with a structured template.

**Copilot path-specific instructions**
- `_add_path_instruction()` creates `.github/instructions/<name>.instructions.md` with YAML frontmatter `applyTo` glob, which Copilot applies in addition to the repo-wide instructions.

**`cmd_doctor` tools section**
- Reports MCP server count (global / project), VS Code MCP count, skill count, and path instruction count. Links to `devloop tools audit` and `devloop tools suggest`.

**Colors**
- Added `BLUE` and `MAGENTA` ANSI variables for tool-type badges in suggest/add output.

### Changed
- `devloop init` next-steps now includes step 4: "Run `devloop tools suggest` for stack-specific tool recommendations."
- VERSION bumped to `3.1.0`.

---

## [3.0.0] — 2026-05-08

### Added

**Self-improvement: `devloop learn` command**
- Extracts lessons from review cycles and appends them to `CLAUDE.md` under `## Learned Patterns`
- Claude reads these patterns in future sessions, making the pipeline progressively smarter
- CLAUDE.md template updated with `## Learned Patterns` section placeholder

**Version awareness: `devloop check` command + auto hint**
- `devloop check` — checks manifest URL for newer version and prints update instructions
- `devloop start` runs a silent background version check; shows a hint on the next start if an update is available
- New config: `DEVLOOP_VERSION_URL` pointing to a plain-text semver manifest file

**Claude Code hooks: `devloop hooks` command**
- Generates `.claude/settings.json` registering all 4 pipeline hook events
- Writes 4 executable hook scripts to `.claude/hooks/`:
  - `devloop-stop.sh` — logs task summary on `Stop` event
  - `devloop-subagent-stop.sh` — records subagent completion and verdict keywords
  - `devloop-notification.sh` — saves Claude notifications to `.devloop/notifications.log`
  - `devloop-session.sh` — records session start/end to `.devloop/sessions.log`
- Orchestrator agent updated with mobile push notification guidance

**Pipeline log viewer: `devloop logs` command**
- Views pipeline, notification, and session logs collected by hooks
- Usage: `devloop logs [pipeline|notifications|sessions]`

**Health check: `devloop doctor` command**
- Validates all DevLoop dependencies: `claude` auth, `copilot` auth, `gh` auth, git config, agent files, config validity, version currency
- Prints ✔/✖ for each check with actionable fix hints

**GitHub Actions integration: `devloop ci` command**
- Generates `.github/workflows/devloop-review.yml` for CI-triggered PR review
- Uses `anthropics/claude-code-action` — requires `ANTHROPIC_API_KEY` secret in repo

**Copilot coding agent: `github-agent` worker mode**
- New `DEVLOOP_WORKER_MODE` config: `cli` (default) or `github-agent`
- In `github-agent` mode, `devloop work` creates a GitHub Issue with the spec, waits for Copilot's cloud agent to open a PR
- `devloop init` generates `copilot-setup-steps.yml` when `DEVLOOP_WORKER_MODE=github-agent`
- New config: `DEVLOOP_VERSION_URL` for update checking

### Changed

- `devloop.config.sh` template updated with `DEVLOOP_WORKER_MODE` and `DEVLOOP_VERSION_URL` defaults
- `CLAUDE.md` template updated with cleaner system section and `## Learned Patterns` placeholder
- `cmd_help` updated with all new commands and worker mode documentation
- `README.md` updated with all new commands, worker modes, and expanded file structure
- `devloop init` next-steps guidance updated to include `devloop hooks`

---

## [2.1.0] — 2026-05-07

### Added

**Architecture & data flow diagrams**
- Added [`DEVLOOP-GRAPH.md`](./DEVLOOP-GRAPH.md) — 11 detailed Mermaid diagrams covering the full pipeline, every command, file lifecycle, git baseline mechanism, `devloop work` and `devloop review` prompt structure, daemon auto-restart loop, status state machine, agent collaboration map, and `devloop clean` selection logic

**Linux systemd support (FIX #15)**
- `devloop daemon` now registers a `~/.config/systemd/user/devloop-<project>.service` unit on Linux
- Service starts automatically on user login (`WantedBy=default.target`) and restarts on crash (`Restart=on-failure`)
- `devloop daemon uninstall` removes the unit on both macOS and Linux
- Internal helpers `_write_systemd` and `_remove_systemd` added alongside existing `_write_launchd` / `_remove_launchd`

**`devloop open` command · alias `o` (FIX #12)**
- Opens the task spec file in `$EDITOR` (falls back to `$VISUAL`, then `vi`)
- Works with latest task or a named `TASK-ID`

**`devloop block` command · alias `b` (FIX #12)**
- Prints the Copilot Instructions Block extracted from a spec
- Useful for manually pasting into Copilot chat without running the full pipeline
- Reads from the pre-extracted `.devloop/prompts/TASK-ID-copilot.txt` when available

**`devloop clean` command (FIX #13)**
- Removes finalized (approved/rejected) specs older than N days (default: 30)
- `--days N` flag to customize the age threshold
- `--dry-run` flag to preview removals without making changes
- Pending and needs-work tasks are always preserved
- Cleans all related files per task: spec `.md`, review `.md`, `.pre-commit` baseline, `-copilot.txt` prompt

**`devloop update` command (FIX #14)**
- Self-upgrades the devloop binary from `DEVLOOP_SOURCE_URL`
- Shows a diff before applying so you can review what changed
- Backs up current binary to `devloop.sh.bak`
- Prints clear setup instructions when `DEVLOOP_SOURCE_URL` is not configured

**Git baseline for precise review diffs (FIX #1)**
- `devloop work` now records the current `HEAD` hash to `.devloop/specs/TASK-ID.pre-commit` before launching Copilot
- `devloop review` uses this baseline to `git diff base..HEAD` — sees exactly what Copilot changed across one or more commits
- `devloop fix` updates the baseline after Copilot's fix commit so the next review only diffs the new changes
- Falls back to uncommitted `git diff` if no baseline file exists

**Full spec delivered to Copilot (FIX #10)**
- `devloop work` now sends the complete spec file (all sections) instead of only the condensed Instructions Block
- Copilot now receives: Files to Touch, Implementation Steps, Edge Cases, Test Scenarios, and the Instructions Block

**Runtime context prepended to Copilot prompt (FIX #11)**
- `devloop work` prepends live project context from `devloop.config.sh` (stack, patterns, conventions, test framework, commit format) at the top of every Copilot prompt
- Context is printed to the terminal as `Runtime context → Stack: ... | Tests: ...` so it is visible in devloop output
- Ensures Copilot always has up-to-date conventions even on re-runs after config changes

**Rich `.github/copilot-instructions.md` template (FIX #9 + FIX #11)**
- `devloop init` now writes a detailed Copilot instructions file with live stack values, commit format, and a pre-flight checklist
- Includes: stack, patterns, conventions, test framework, commit message format (`feat(TASK-ID): ...`), and implementation checklist

**Spec completeness validation (FIX #7)**
- `devloop work` refuses to launch Copilot if the spec is missing the `## Copilot Instructions Block` section
- Prints a clear error with the regeneration command

**Seconds-precision task IDs (FIX #3)**
- Task IDs now use `TASK-YYYYMMDD-HHMMSS` format (6-digit time) instead of `TASK-YYYYMMDD-HHMM`
- Eliminates collisions when two specs are created in the same minute

**Dynamic agent model from config (FIX #5)**
- `devloop-architect.md` and `devloop-reviewer.md` are generated with the `CLAUDE_MODEL` value from `devloop.config.sh`
- Changing `CLAUDE_MODEL` and re-running `devloop init` regenerates both agent files with the new model
- Agent front matter (model field) uses an unquoted heredoc for variable expansion while the body uses a quoted heredoc to preserve literal `$` signs

**TodoWrite in orchestrator agent (FIX #8)**
- The `devloop-orchestrator` agent now lists `TodoWrite` in its tools
- Orchestrator tracks task progress with per-step todo items: Architect spec → Copilot implement → Review → Done

### Fixed

**`devloop daemon` subcommand argument parsing (FIX #4)**
- `stop`, `status`, `log`, and `uninstall` now work without specifying a project name: `devloop daemon stop`
- Previously required `devloop daemon <project-name> stop`
- Bare subcommands use the project name from `devloop.config.sh`

**Fenced code block extraction with language tags (FIX #2)**
- Copilot Instructions Block extraction and fix instruction extraction now match ```` ``` ```` with or without a language identifier (e.g. ```` ```python ````)
- Previously only matched bare ```` ``` ```` lines, causing extraction to silently return empty on language-tagged blocks

**`devloop clean` "preserved" message when count = 0 (FIX #13)**
- When no specs are old enough to clean but some are skipped (pending/needs-work), now prints:
  `"No finalized specs removed, N pending/needs-work preserved"`
- Previously only printed the generic "none found" message, hiding the fact that tasks were preserved

**bash 3.2 heredoc compatibility in `cmd_review`**
- Replaced `review_prompt="$(cat <<HEREDOC...HEREDOC)"` with a `mktemp` + `printf` approach
- The old pattern caused `"bad substitution: no closing ')'"` on macOS bash 3.2 when the git diff contained backtick characters (common in markdown code blocks in agent `.md` files)

**`cmd_review` output capture under `set -euo pipefail`**
- Replaced `echo ... | claude -p | tee "$review_file"` with `echo ... | claude -p > "$review_file" && cat "$review_file"`
- The `tee` pipeline's exit code was unreliable under `pipefail`, causing the review file to never be written

### Changed

- `devloop init` skips existing files instead of overwriting — safe to re-run after config changes
- `devloop architect` writes the extracted Copilot block to `.devloop/prompts/TASK-ID-copilot.txt` for use by `devloop block`
- `devloop tasks` output updated to show seconds in task IDs
- Orchestrator agent workflow updated with `TodoWrite` tracking steps and clearer phase indicators

---

## [2.0.0] — 2026-05-01

### Added
- Three-agent pipeline: orchestrator + architect + reviewer
- `devloop init` — project setup with agent definitions, CLAUDE.md, config file
- `devloop start` — Claude Code with remote control and `caffeinate -is`
- `devloop daemon` — background mode with auto-restart and launchd registration (macOS)
- `devloop architect` — Claude designs implementation spec for Copilot
- `devloop work` — Copilot implements with `/plan` mode
- `devloop review` — Claude reviews `git diff` against spec
- `devloop fix` — Copilot applies Claude's fix instructions
- `devloop tasks` — list all specs with status
- `devloop status` — show spec + review for a task
- Embedded agent definitions written by `devloop init`
- Exponential backoff daemon restarts (5s → 60s, 20 retries max)
- Per-project launchd `.plist` auto-registered on daemon start

### Changed
- Single-file distribution — everything in `devloop.sh`

---

## [1.0.0] — 2026-04-15

### Added
- Initial release: single `devloop.sh` script
- Basic architect → work → review loop
- `devloop init`, `devloop start`, `devloop architect`, `devloop work`, `devloop review`, `devloop fix`
- `devloop.config.sh` for project stack configuration
