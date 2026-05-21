#!/usr/bin/env bash
# Bulk-create the 45 issues for the TUI Redesign v5.3 effort.
#
# Idempotent re-runs: skips creating an issue if the exact title already exists.
# Closes preflight issues whose work is already shipped (commit 221127a).
#
# Usage:  bash scripts/tui-v5.3-create-issues.sh
# Requires: gh auth with `project` scope (gh auth refresh -s project)

set -euo pipefail

OWNER="shaifulshabuj"
REPO="$OWNER/devloop"
PROJECT_TITLE="TUI Redesign v5.3"
PREFLIGHT_COMMIT="221127a"

# ── Cache existing issue titles for idempotency ───────────────────────────────
TMP_TITLES="$(mktemp /tmp/tui-titles.XXXX)"
trap 'rm -f "$TMP_TITLES"' EXIT
gh issue list --state all --limit 500 --json title --jq '.[].title' > "$TMP_TITLES"

# mk - create one issue and optionally close it.
# Args: TITLE | MILESTONE | LABELS_CSV | BODY_FILE | close=true|false
mk() {
  local title="$1" milestone="$2" labels="$3" body_file="$4" close="${5:-false}"
  if grep -Fxq "$title" "$TMP_TITLES"; then
    echo "skip (exists): $title"
    return 0
  fi
  local url
  url="$(gh issue create \
    --title "$title" \
    --body-file "$body_file" \
    --milestone "$milestone" \
    --project "$PROJECT_TITLE" \
    --label "$labels" 2>&1 | tail -1)"
  echo "created: $url"
  if [[ "$close" == "true" ]]; then
    gh issue close "$url" -c "Implemented in commit ${PREFLIGHT_COMMIT} (preflight batch)." >/dev/null
    echo "  closed: implemented in $PREFLIGHT_COMMIT"
  fi
}

BODY_DIR="$(mktemp -d /tmp/tui-bodies.XXXX)"
write_body() { local f="$BODY_DIR/$1"; shift; printf '%s\n' "$*" > "$f"; echo "$f"; }

# Common labels: tui-redesign umbrella is on every issue.
UM="tui-redesign"

# ════════════════════════════════════════════════════════════════════════════════
# Preflight (milestone: tui-v5.3 / preflight) — already implemented, close after
# ════════════════════════════════════════════════════════════════════════════════
MS_PF="tui-v5.3 / preflight"

b="$(write_body pf1.md \
"## What
Emit a structured \`phase.escalate\` NDJSON event from \`cmd_resume\` whenever the fix loop hits max retries and escalates to a re-architect (respec) phase.

## Why
The TUI re-architect detection (Phase 4 C3) must consume an event, not scrape worker stdout. The redesign brief originally proposed string-matching \"max retries exhausted\" — fragile and breaks on log-string renames.

## Acceptance criteria
- [x] Both escalation branches in cmd_resume call \`emit_event phase.escalate from=fix to=respec retries=\$max_retries reason=max-retries-exhausted\`
- [x] Event appears in \`.devloop/events.ndjson\` (project-wide) and per-session
- [x] Event is suppressed when \`DEVLOOP_EVENTS_DISABLED=1\` (existing flag)
- [x] CHANGELOG.md updated

## Files touched
- devloop.sh (two emission points)
- CHANGELOG.md")"
mk "[preflight] PF-1 emit phase.escalate NDJSON event on max-retry escalation" \
   "$MS_PF" "$UM,component/orchestrator,type/feature,priority/critical,size/s" "$b" true

b="$(write_body pf2.md \
"## What
Make the TUI dashboard tail \`.devloop/events.ndjson\` (the authoritative project-wide event stream) instead of the legacy \`.devloop/pipeline.log\`.

## Why
\`run.go\` and \`chat.go\` already use \`events.ndjson\`. Dashboard was the only stale consumer — phase events weren't visible in its live log pane.

## Acceptance criteria
- [x] \`internal/views/dashboard.go\` tails events.ndjson
- [x] \`go test ./cmd/devloop-tui/...\` still passes

## Files touched
- cmd/devloop-tui/internal/views/dashboard.go")"
mk "[preflight] PF-2 standardize TUI stream source on events.ndjson" \
   "$MS_PF" "$UM,component/tui,type/bug,priority/critical,size/xs" "$b" true

b="$(write_body pf3.md \
"## What
Add \`devloop permit grant --all\` and \`devloop permit deny --all\` subcommands.

## Why
The redesign brief originally suggested using \`permit mode auto\` for bulk grant — that changes the gate mode permanently, a footgun. A real bulk-resolve subcommand makes the TUI PERMIT-tab \"grant all\" UX safe.

## Acceptance criteria
- [x] \`permit grant --all\` writes \`allow\` to every unresolved \`.devloop/permission-queue/<UUID>.response\`
- [x] \`permit deny --all\` writes \`deny\` to every unresolved response
- [x] Reports counts of granted/denied + skipped (already resolved)
- [x] Usage line updated

## Files touched
- devloop.sh (cmd_permit grant/deny branches)" )"
mk "[preflight] PF-3 add 'permit grant --all' and 'permit deny --all'" \
   "$MS_PF" "$UM,component/cli,type/feature,priority/high,size/s" "$b" true

b="$(write_body pf4.md \
"## What
Add a \`--json\` flag to \`devloop daemon status\` emitting structured JSON.

## Why
TUI top bar needs a machine-readable daemon snapshot (pid, running, restart_count, max_reached, last_restart, log_path). The current freeform output requires regex parsing.

## Acceptance criteria
- [x] \`devloop daemon status --json\` prints a single JSON object on stdout
- [x] Fields: \`pid\` (string), \`running\` (bool), \`restart_count\` (int), \`max_reached\` (bool), \`last_restart\` (string), \`log_path\` (string)
- [x] Works with or without \`jq\` installed (hand-rolled fallback)

## Files touched
- devloop.sh (cmd_daemon)")"
mk "[preflight] PF-4 add 'daemon status --json' mode" \
   "$MS_PF" "$UM,component/cli,type/feature,priority/high,size/s" "$b" true

b="$(write_body pf5.md \
"## What
Add a \`--json\` flag to \`devloop doctor\` emitting structured check rows.

## Why
Phase 3 onboarding wizard consumes this for the two-column status table. Also fixes a pre-existing early-exit bug when \`~/.devloop/config.sh\` contains only comments.

## Acceptance criteria
- [x] \`devloop doctor --json\` ends with a JSON object \`{pass, fail, checks: [{check, status, message}]}\`
- [x] Status one of \`pass\` / \`fail\`
- [x] Works with or without jq
- [x] Doctor no longer exits early on near-empty global config

## Files touched
- devloop.sh (cmd_doctor + _chk)")"
mk "[preflight] PF-5 add 'doctor --json' + fix early-exit on empty global config" \
   "$MS_PF" "$UM,component/cli,type/feature,priority/high,size/s" "$b" true

b="$(write_body pf6.md \
"## What
Document the session status vocabulary and the NDJSON event kinds inline in devloop.sh.

## Why
Phase 4 footer text branches on these statuses; without an authoritative list in the source, implementers had to grep multiple files.

## Acceptance criteria
- [x] Header comment block before \`emit_event\` lists all 8 status values and all 8 event kinds (incl. phase.escalate)

## Files touched
- devloop.sh (header comment)")"
mk "[preflight] PF-6 document .devloop/sessions/<TASK-ID>/status vocabulary" \
   "$MS_PF" "$UM,type/docs,priority/high,size/xs" "$b" true

b="$(write_body pf7.md \
"## What
Add a minimal GitHub Actions workflow that builds and tests \`cmd/devloop-tui\` and runs shellcheck on \`devloop.sh\`, triggered by PRs touching those paths.

## Why
The repo had zero CI. With ~45 PRs incoming for the TUI redesign, compile gating is essential to prevent cascading red branches.

## Acceptance criteria
- [x] \`.github/workflows/tui-ci.yml\` exists
- [x] Triggers on PR + push to main when paths match
- [x] Runs \`go build\`, \`go test\`, \`go vet\` on \`cmd/devloop-tui/...\`
- [x] Runs \`shellcheck -S warning devloop.sh\` (continue-on-error)
- [x] Timeout ≤ 5 min

## Files touched
- .github/workflows/tui-ci.yml")"
mk "[preflight] PF-7 add tui-ci.yml workflow" \
   "$MS_PF" "$UM,type/infrastructure,priority/critical,size/xs" "$b" true

b="$(write_body pf8.md \
"## What
Add \`.github/ISSUE_TEMPLATE/{feature,bug,chore}.yml\` and \`.github/pull_request_template.md\`.

## Why
Standardizes the issue/PR body across the ~45-issue effort. PR template enforces acceptance-criteria checkboxes and go build/test attestation.

## Acceptance criteria
- [x] Three issue templates added (feature, bug, chore)
- [x] PR template includes Acceptance, Verification, Spec corrections, Notes sections

## Files touched
- .github/ISSUE_TEMPLATE/*.yml
- .github/pull_request_template.md")"
mk "[preflight] PF-8 add issue + PR templates" \
   "$MS_PF" "$UM,type/infrastructure,priority/medium,size/xs" "$b" true

b="$(write_body pf9.md \
"## What
Add \`.github/CODEOWNERS\` assigning \`cmd/devloop-tui/**\`, \`devloop.sh\`, and \`.github/workflows/**\` to the project owner.

## Acceptance criteria
- [x] CODEOWNERS file exists
- [x] Three path patterns covered

## Files touched
- .github/CODEOWNERS")"
mk "[preflight] PF-9 add CODEOWNERS" \
   "$MS_PF" "$UM,type/infrastructure,priority/medium,size/xs" "$b" true

b="$(write_body pf10.md \
"## What
Remove the stale \`.claude/worktrees/docs-philosophy\` worktree and document the worktree convention for TUI redesign phases.

## Why
That worktree contains one unique commit (\`59ae215 chore: remove devloop self-control from CLAUDE.md\`) and a modified \`.claude/settings.json\`. Must verify the commit is merged or merge it before removing — currently DEFERRED pending user decision.

## Acceptance criteria
- [ ] Decide: merge commit \`59ae215\` into main, OR confirm it can be dropped
- [ ] \`git worktree remove .claude/worktrees/docs-philosophy\`
- [ ] CLAUDE.md (project) documents worktree convention: \`.claude/worktrees/tui-phase-{0..4}\`

## Notes
This issue is **deferred** until the user confirms what to do with the unique commit.")"
mk "[preflight] PF-10 remove stale docs-philosophy worktree + document convention" \
   "$MS_PF" "$UM,type/chore,priority/medium,size/xs" "$b" false

b="$(write_body pf11.md \
"## What
Create GitHub Project \"TUI Redesign v5.3\", 5 milestones, and the new labels (tui-redesign, tui-phase/{0..4}, needs-spec-correction, size/xs, type/{bug,refactor,test,chore}).

## Acceptance criteria
- [x] Project \"TUI Redesign v5.3\" exists (project #8)
- [x] Milestones \"tui-v5.3 / preflight\" through \"phase-4\" exist (milestones #5–#9)
- [x] New labels created
- [x] All 45 issues created via scripts/tui-v5.3-create-issues.sh")"
mk "[preflight] PF-11 create GH Project + milestones + labels" \
   "$MS_PF" "$UM,type/infrastructure,priority/critical,size/xs" "$b" true

# ════════════════════════════════════════════════════════════════════════════════
# Phase 1 — Dashboard (milestone: tui-v5.3 / phase-1 dashboard) — 11 issues
# ════════════════════════════════════════════════════════════════════════════════
MS_P1="tui-v5.3 / phase-1 dashboard"

b="$(write_body p1-1.md \
"## What
Move \`cmd/devloop-tui/colors.go\` (currently package \`theme\` in the wrong directory — present locally as an untracked starter file) to \`cmd/devloop-tui/internal/theme/colors.go\`. Update every importer.

## Why
The starter file shipped with the redesign brief declared \`package theme\` while sitting next to \`main.go\`'s \`package main\` — would break \`go build\` if committed. All other Phase 1+ work depends on \`theme.*\` tokens.

## Acceptance criteria
- [ ] \`internal/theme/colors.go\` exists with all tokens (Bg, Surface, Surface2, Border, Text, Dim, Green, Yellow, Red, Blue, Purple) + helpers (StatusColor, StatusIcon, SpinnerFrames, StylePhaseBox{Done,Running,Pending}, StyleLogo, StyleLogLine, etc.)
- [ ] Every \`lipgloss.Color(\"...\")\` literal outside the theme package is replaced with \`theme.X\` reference
- [ ] \`go build ./cmd/devloop-tui/...\` and \`go test ./cmd/devloop-tui/...\` pass

## Notes for implementer
The starter content lives at \`devloop-tui-redesign 3/starter/cmd/devloop-tui/internal/theme/colors.go\`. Existing raw \`lipgloss.Color\` usage: \`task_picker.go\` (\"205\", \"252\"), \`pipeline_grid.go\` (\"240\", \"220\", \"82\", \"196\", \"39\"), \`run.go\` (\"196\", \"240\").

## Dependencies
PF-7 (CI) must be green so the migration PR is verified.")"
mk "[phase-1] P1-1 move colors.go into internal/theme; update all imports" \
   "$MS_P1" "$UM,tui-phase/1,component/tui,type/refactor,priority/critical,size/s" "$b" false

b="$(write_body p1-2.md \
"## What
Add a \`ProviderHealth\` struct and \`loadProviderHealth(root)\` helper that parses \`.devloop/provider-health.sh\`.

## Acceptance criteria
- [ ] Parses \`HEALTH_MAIN_LIMITED_SINCE\`, \`HEALTH_MAIN_OVERRIDE\`, \`HEALTH_MAIN_LAST_PROBE\`, \`HEALTH_WORKER_LIMITED_SINCE\`, \`HEALTH_WORKER_OVERRIDE\`, \`HEALTH_WORKER_LAST_PROBE\` (Unix-seconds timestamps)
- [ ] Tolerates missing file (returns zero-value struct, no error)
- [ ] Tolerates malformed lines (ignores)
- [ ] Unit test covers: missing file, valid file, file with garbage

## Notes for implementer
The brief wrongly says vars are \`DEVLOOP_*_OVERRIDE\` — confirmed wrong, real names start with \`HEALTH_*\`.

## Dependencies
P1-1 (uses theme).")"
mk "[phase-1] P1-2 add ProviderHealth struct + loadProviderHealth(root)" \
   "$MS_P1" "$UM,tui-phase/1,component/tui,type/feature,priority/critical,size/s,ai-ready" "$b" false

b="$(write_body p1-3.md \
"## What
Render a provider top bar in the dashboard header: \`claude ✓ · copilot ✓ · daemon ✓\` (red ✗ when unhealthy, yellow ⚠ when override active).

## Acceptance criteria
- [ ] Top bar visible above the split pane on all dashboard renders
- [ ] Each provider shows a coloured glyph (\`theme.StatusColor\` mapping)
- [ ] Re-reads \`provider-health.sh\` on a 5s tick (or on user-triggered refresh)
- [ ] Width-responsive (wraps cleanly at narrow widths)

## Dependencies
P1-2 (loader).")"
mk "[phase-1] P1-3 render provider top bar in dashboard header" \
   "$MS_P1" "$UM,tui-phase/1,component/tui,type/feature,priority/critical,size/s,ai-ready" "$b" false

b="$(write_body p1-4.md \
"## What
Add daemon liveness and recent-restart count to the top bar. Use PF-4 \`daemon status --json\` if available; fall back to reading \`.devloop/daemon.pid\` and grepping \`.devloop/daemon.log\` for \`Restarting in\`.

## Acceptance criteria
- [ ] Shows \`daemon ✓\` when running with 0 recent restarts
- [ ] Shows \`daemon ✓ ×N\` (yellow) when restart count > 0
- [ ] Shows \`daemon ✗\` (red) when not running

## Dependencies
P1-3, PF-4.")"
mk "[phase-1] P1-4 daemon liveness + restart count in top bar" \
   "$MS_P1" "$UM,tui-phase/1,component/tui,type/feature,priority/high,size/xs,ai-ready" "$b" false

b="$(write_body p1-5.md \
"## What
Extract the existing textinput + bubbles/list fuzzy filter from \`task_picker.go\` into a reusable component at \`internal/components/filter.go\`.

## Why
Both the dashboard task list and the Phase 2 command palette need fuzzy filtering. The pattern already exists; extracting prevents duplication.

## Acceptance criteria
- [ ] New file \`internal/components/filter.go\` exporting a \`Filter\` struct with \`Update\`, \`View\`, \`Match(items)\` API
- [ ] \`task_picker.go\` uses the extracted component (behaviour unchanged)
- [ ] Existing task_picker_test.go still passes
- [ ] New filter_test.go covers fuzzy-match correctness

## Dependencies
P1-1.")"
mk "[phase-1] P1-5 extract fuzzy-filter helper from task_picker into components/filter.go" \
   "$MS_P1" "$UM,tui-phase/1,component/tui,type/refactor,priority/critical,size/s" "$b" false

b="$(write_body p1-6.md \
"## What
Wire the dashboard \`/\` key to activate the extracted fuzzy filter on the task list.

## Acceptance criteria
- [ ] Pressing \`/\` shows the filter input at the bottom of the task list
- [ ] Typing filters the task list in real time
- [ ] \`esc\` clears the filter and exits filter mode
- [ ] Filter state survives view re-renders

## Dependencies
P1-5.")"
mk "[phase-1] P1-6 wire dashboard '/' to fuzzy filter task list" \
   "$MS_P1" "$UM,tui-phase/1,component/tui,type/feature,priority/critical,size/xs,ai-ready" "$b" false

b="$(write_body p1-7.md \
"## What
Build a generic collapsible \`Panel\` component at \`internal/components/panel.go\` with a header + viewport body.

## Acceptance criteria
- [ ] \`Panel\` exposes \`Toggle()\`, \`SetContent(string)\`, \`Update(tea.Msg)\`, \`View(width int) string\`
- [ ] Collapsed state: shows only header (\"▶ SPEC  expand\")
- [ ] Expanded state: shows header (\"▼ SPEC\") + viewport with scrollable content
- [ ] Uses bubbles/viewport internally
- [ ] panel_test.go covers toggle, content updates, width changes

## Dependencies
P1-1.")"
mk "[phase-1] P1-7 build collapsible Panel component" \
   "$MS_P1" "$UM,tui-phase/1,component/tui,type/feature,priority/critical,size/s,ai-ready" "$b" false

b="$(write_body p1-8.md \
"## What
SPEC panel in dashboard: loads \`.devloop/specs/<TASK-ID>.md\` for the active task; toggles on \`s\`.

## Acceptance criteria
- [ ] Pressing \`s\` toggles the SPEC panel (uses the P1-7 Panel component)
- [ ] Content reloads when the active task changes
- [ ] Missing spec file shows a friendly placeholder (\"no spec yet\")
- [ ] Viewport scrolls with arrow keys when expanded

## Dependencies
P1-7.")"
mk "[phase-1] P1-8 SPEC panel: load .devloop/specs/<TASK-ID>.md on 's' toggle" \
   "$MS_P1" "$UM,tui-phase/1,component/tui,type/feature,priority/high,size/s,ai-ready" "$b" false

b="$(write_body p1-9.md \
"## What
DIFF panel in dashboard: reads \`.devloop/specs/<TASK-ID>.pre-commit\` for the baseline hash, runs \`git diff <hash>..HEAD\` in a goroutine, colourises +/- lines, toggles on \`d\`.

## Acceptance criteria
- [ ] Pressing \`d\` toggles the DIFF panel
- [ ] Diff runs in a goroutine (UI stays responsive)
- [ ] +/- lines coloured green/red via theme tokens
- [ ] Diff refreshes when the active task changes
- [ ] Missing baseline hash → \"no baseline recorded\"

## Dependencies
P1-7.")"
mk "[phase-1] P1-9 DIFF panel: read .pre-commit baseline + colourise" \
   "$MS_P1" "$UM,tui-phase/1,component/tui,type/feature,priority/high,size/m" "$b" false

b="$(write_body p1-10.md \
"## What
Define \`openFocusMsg{idx int}\` and emit it from dashboard's task list when \`enter\` is pressed on a highlighted task. Receiver (Focus Mode) wired in Phase 2.

## Acceptance criteria
- [ ] Message type defined in \`internal/app/messages.go\` (or equivalent)
- [ ] Dashboard's key handler emits it on enter
- [ ] Until Phase 2 P2-5 lands, router ignores it gracefully

## Dependencies
P1-6.")"
mk "[phase-1] P1-10 emit openFocusMsg on enter (Phase 2 wires receiver)" \
   "$MS_P1" "$UM,tui-phase/1,component/tui,type/feature,priority/high,size/xs,ai-ready" "$b" false

b="$(write_body p1-11.md \
"## What
Refresh the dashboard footer key strip to reflect new keybinds (\`/ filter · s spec · d diff · enter focus · space actions · q quit\`) and add tests for filter / panels / top bar.

## Acceptance criteria
- [ ] Footer text matches the actual key bindings
- [ ] dashboard_test.go covers: filter activation, panel toggle, top bar render with valid provider-health.sh
- [ ] All existing tests still pass

## Dependencies
P1-3, P1-6, P1-8, P1-9, P1-10.")"
mk "[phase-1] P1-11 refresh footer keybinds + add dashboard tests" \
   "$MS_P1" "$UM,tui-phase/1,component/tui,type/test,priority/high,size/s,ai-ready" "$b" false

# ════════════════════════════════════════════════════════════════════════════════
# Phase 2 — Focus + Palette (milestone: tui-v5.3 / phase-2 focus+palette) — 10
# ════════════════════════════════════════════════════════════════════════════════
MS_P2="tui-v5.3 / phase-2 focus+palette"

b="$(write_body p2-1.md \
"## What
Scaffold \`FocusModel\` at \`internal/views/focus.go\`: title bar, phase track, tab area, footer; register \`ViewFocus\` in the router.

## Acceptance criteria
- [ ] \`FocusModel\` implements \`tea.Model\` (Init/Update/View)
- [ ] Holds \`[]stream.Session\` + active index, width, height
- [ ] Renders skeleton: \"task title · TASK-ID · started Nm ago\" + placeholder phase track + tab placeholder + footer with kbds
- [ ] Registered in \`AppModel.views[ViewFocus]\` and routable

## Dependencies
P1-* complete (uses theme + stream.Session).")"
mk "[phase-2] P2-1 scaffold FocusModel + register ViewFocus in router" \
   "$MS_P2" "$UM,tui-phase/2,component/tui,type/feature,priority/critical,size/m" "$b" false

b="$(write_body p2-2.md \
"## What
Render the phase track in Focus Mode reusing \`internal/components/pipeline_grid.go\`.

## Acceptance criteria
- [ ] Phase cards visible: architect → worker → reviewer → fix (→ respec when present)
- [ ] Each card shows status colour + icon + elapsed time
- [ ] Running phase shows spinner driven by 100ms tick

## Dependencies
P2-1.")"
mk "[phase-2] P2-2 phase track rendering in Focus Mode" \
   "$MS_P2" "$UM,tui-phase/2,component/tui,type/feature,priority/critical,size/s,ai-ready" "$b" false

b="$(write_body p2-3.md \
"## What
LOG / SPEC / DIFF tab switcher in Focus Mode, sharing one \`bubbles/viewport\`. Keys \`1\`/\`2\`/\`3\` and \`tab\` cycles.

## Acceptance criteria
- [ ] Active tab highlighted with theme.Blue underline
- [ ] LOG tab streams via stream.Tailer (reusing existing tailer)
- [ ] SPEC tab loads .devloop/specs/<TASK-ID>.md
- [ ] DIFF tab runs git diff like P1-9 (factor a shared helper if needed)

## Dependencies
P2-1.")"
mk "[phase-2] P2-3 LOG/SPEC/DIFF tab switcher with shared viewport" \
   "$MS_P2" "$UM,tui-phase/2,component/tui,type/feature,priority/critical,size/s,ai-ready" "$b" false

b="$(write_body p2-4.md \
"## What
\`←/→/h/l\` task navigation in Focus Mode (wrap-around); spinner-tick wiring driven from root model.

## Acceptance criteria
- [ ] Pressing ← or h selects previous task, → or l selects next; wraps at edges
- [ ] On task change: re-load SPEC/DIFF/LOG content, reset viewport scroll
- [ ] Spinner ticks 10× per second on running phases

## Dependencies
P2-1.")"
mk "[phase-2] P2-4 ←/→/h/l navigation + spinner-tick wiring" \
   "$MS_P2" "$UM,tui-phase/2,component/tui,type/feature,priority/high,size/s,ai-ready" "$b" false

b="$(write_body p2-5.md \
"## What
Wire \`openFocusMsg\` and \`closeFocusMsg\` in \`internal/app/app.go\`'s router. \`esc\` in Focus returns to Dashboard.

## Acceptance criteria
- [ ] \`AppModel.Update\` catches openFocusMsg → switches to ViewFocus with the chosen index
- [ ] AppModel.Update catches closeFocusMsg → switches back to ViewDashboard
- [ ] \`esc\` keybinding in Focus emits closeFocusMsg

## Dependencies
P1-10, P2-1.")"
mk "[phase-2] P2-5 wire openFocusMsg/closeFocusMsg in app.go router" \
   "$MS_P2" "$UM,tui-phase/2,component/tui,type/feature,priority/critical,size/s" "$b" false

b="$(write_body p2-6.md \
"## What
Scaffold \`PaletteModel\` at \`internal/components/palette.go\` with \`DefaultActions\`: architect/work/review/fix/learn/tasks/providers/diff/hooks/update.

## Acceptance criteria
- [ ] \`PaletteAction{Key, Label, Desc, Cmd}\` struct
- [ ] \`PaletteModel\` uses the P1-5 Filter component
- [ ] Renders centred 40-char-wide list with action list + key chip on the left
- [ ] palette_test.go covers fuzzy filter + selection

## Dependencies
P1-1, P1-5.")"
mk "[phase-2] P2-6 scaffold PaletteModel with DefaultActions" \
   "$MS_P2" "$UM,tui-phase/2,component/tui,type/feature,priority/critical,size/m,ai-ready" "$b" false

b="$(write_body p2-7.md \
"## What
Render the palette as an overlay in \`AppModel.View()\` via \`lipgloss.Place\` composition over the active sub-view.

## Acceptance criteria
- [ ] When \`paletteOpen=true\`, palette renders centred on top of the active view
- [ ] Underlying view content is dimmed (background colour shift)
- [ ] No cursor positioning bugs
- [ ] Width/height responsive

## Dependencies
P2-6.")"
mk "[phase-2] P2-7 render palette overlay via lipgloss.Place composition" \
   "$MS_P2" "$UM,tui-phase/2,component/tui,type/feature,priority/critical,size/s,ai-ready" "$b" false

b="$(write_body p2-8.md \
"## What
Global \`space\` toggles palette open; \`esc\` closes; on \`enter\` (or single-key match) the selected action dispatches via existing \`chat.dispatchShell\`.

## Acceptance criteria
- [ ] Global key handler in \`AppModel.Update\` toggles paletteOpen
- [ ] Disabled when any textinput is focused (e.g., in filter)
- [ ] Action dispatch uses chat.dispatchShell — no new subprocess pattern
- [ ] Errors from dispatched commands surface in the chat scrollback / log

## Dependencies
P2-6, P2-7.

## Notes for implementer
\`chat.dispatchShell\` is in \`internal/views/chat.go\`. Lift it to a shared exec helper if needed but do not duplicate it.")"
mk "[phase-2] P2-8 wire SPACE to toggle palette; dispatch via chat.dispatchShell" \
   "$MS_P2" "$UM,tui-phase/2,component/tui,type/feature,priority/critical,size/s" "$b" false

b="$(write_body p2-9.md \
"## What
When the palette filter input is empty, pressing a single letter A/W/R/F/L/T/P/D/H/U runs the matching action immediately (no enter required).

## Acceptance criteria
- [ ] Single-key shortcuts honoured only when filter query is empty
- [ ] Letter is consumed (not echoed into filter)
- [ ] Matches \`DefaultActions[i].Key\` case-insensitively

## Dependencies
P2-8.")"
mk "[phase-2] P2-9 single-letter palette shortcuts when query empty" \
   "$MS_P2" "$UM,tui-phase/2,component/tui,type/feature,priority/high,size/xs,ai-ready" "$b" false

b="$(write_body p2-10.md \
"## What
Snapshot/golden tests for Focus Mode layout and Palette overlay rendering.

## Acceptance criteria
- [ ] focus_test.go renders FocusModel with a fixture session, asserts string-equal to a checked-in golden
- [ ] palette_test.go renders palette overlay, asserts dimensions and content
- [ ] Updating goldens is documented in test file comment

## Dependencies
P2-1..P2-9.")"
mk "[phase-2] P2-10 snapshot tests for Focus + Palette" \
   "$MS_P2" "$UM,tui-phase/2,component/tui,type/test,priority/medium,size/s,ai-ready" "$b" false

# ════════════════════════════════════════════════════════════════════════════════
# Phase 3 — Onboarding (milestone: tui-v5.3 / phase-3 onboarding) — 6 issues
# ════════════════════════════════════════════════════════════════════════════════
MS_P3="tui-v5.3 / phase-3 onboarding"

b="$(write_body p3-1.md \
"## What
Scaffold \`OnboardModel\` at \`internal/views/onboard.go\` with three logical phases: \`init\` → \`doctor\` → \`done\`. Title bar at top, progress in body, CTA in footer.

## Acceptance criteria
- [ ] OnboardModel implements tea.Model
- [ ] Holds current phase + per-phase state
- [ ] Renders skeleton without subprocesses (subprocesses wired in P3-2/P3-3)

## Dependencies
P1-1, P2-5.")"
mk "[phase-3] P3-1 scaffold OnboardModel (init/doctor/done states)" \
   "$MS_P3" "$UM,tui-phase/3,component/tui,type/feature,priority/critical,size/m" "$b" false

b="$(write_body p3-2.md \
"## What
Stream \`devloop init\` output via \`chat.dispatchShell\`. Parse \`✔ Created:\` and \`✔ Updated:\` lines into a structured list rendered as the wizard progresses.

## Acceptance criteria
- [ ] init subprocess streamed line-by-line
- [ ] Parsed lines render as structured list (green ✓ + path)
- [ ] Unrecognised lines rendered dim
- [ ] On non-zero exit: stays on init phase + shows error

## Dependencies
P3-1.")"
mk "[phase-3] P3-2 stream devloop init output, parse and render structured list" \
   "$MS_P3" "$UM,tui-phase/3,component/tui,type/feature,priority/critical,size/s,ai-ready" "$b" false

b="$(write_body p3-3.md \
"## What
Stream \`devloop doctor --json\` (PF-5) and render the \`checks\` array as a two-column status table.

## Acceptance criteria
- [ ] Parses the JSON object (last line of doctor output) into rows
- [ ] Each row: check name (left) + status icon (right, green/red/yellow)
- [ ] Failed checks show the hint message inline
- [ ] If \`--json\` is unsupported, falls back to regex parsing of glyph lines

## Dependencies
P3-1, PF-5.")"
mk "[phase-3] P3-3 stream doctor --json and render two-column status table" \
   "$MS_P3" "$UM,tui-phase/3,component/tui,type/feature,priority/critical,size/s,ai-ready" "$b" false

b="$(write_body p3-4.md \
"## What
Add \`onboard\` subcommand to \`cmd/devloop-tui/main.go\` and auto-trigger when \`devloop.config.sh\` is not found in the working directory.

## Acceptance criteria
- [ ] \`devloop-tui onboard\` launches OnboardModel
- [ ] When no config detected, default startup launches OnboardModel instead of Dashboard
- [ ] Once onboarding completes (enter on READY box), routes to Dashboard

## Dependencies
P3-1.")"
mk "[phase-3] P3-4 add 'onboard' subcommand + auto-trigger on missing config" \
   "$MS_P3" "$UM,tui-phase/3,component/tui,type/feature,priority/critical,size/s,ai-ready" "$b" false

b="$(write_body p3-5.md \
"## What
READY box at the end of doctor phase with green border and \"Ready. Run \`devloop start\` or press [enter] to open dashboard\". Surface errors for failed init/doctor steps.

## Acceptance criteria
- [ ] READY box renders only after doctor returns 0 failed checks
- [ ] Pressing enter transitions to dashboard
- [ ] Failed init/doctor displays retry / docs CTA instead

## Dependencies
P3-1..P3-4.")"
mk "[phase-3] P3-5 READY box + enter→dashboard + error rendering" \
   "$MS_P3" "$UM,tui-phase/3,component/tui,type/feature,priority/high,size/s,ai-ready" "$b" false

b="$(write_body p3-6.md \
"## What
Tests covering init-line parsing, doctor row parsing, and auto-trigger behaviour.

## Acceptance criteria
- [ ] onboard_test.go: feeds canned init stdout, asserts parsed list
- [ ] feeds canned doctor --json output, asserts rendered rows
- [ ] simulates missing config, asserts OnboardModel selected

## Dependencies
P3-1..P3-5.")"
mk "[phase-3] P3-6 tests for init parsing / doctor parsing / auto-trigger" \
   "$MS_P3" "$UM,tui-phase/3,component/tui,type/test,priority/medium,size/s,ai-ready" "$b" false

# ════════════════════════════════════════════════════════════════════════════════
# Phase 4 — Permit + Daemon + Resume (milestone: tui-v5.3 / phase-4 ...) — 17
# ════════════════════════════════════════════════════════════════════════════════
MS_P4="tui-v5.3 / phase-4 permit+daemon+resume"

# A. Permit queue (8 issues)
b="$(write_body p4-a1.md \
"## What
Helper \`readPermitQueue(root) ([]PermitItem, error)\` parsing \`.devloop/permission-queue/<UUID>.json\` files.

## Acceptance criteria
- [ ] PermitItem fields: \`ID, Command, Tool, RequestedAt\`
- [ ] Tolerates malformed JSON (skips item)
- [ ] Tolerates missing file (returns empty slice)
- [ ] Excludes items that already have a matching .response file
- [ ] readpermit_test.go covers happy path + 3 failure modes

## Notes for implementer
The redesign brief wrongly says \"filename is the command\" — confirmed wrong. Filename is a UUID; command lives in the JSON body's \`command\` field.

## Dependencies
PF-6.")"
mk "[phase-4 / permit] P4-A1 readPermitQueue parser (UUID JSON)" \
   "$MS_P4" "$UM,tui-phase/4,component/tui,type/feature,priority/critical,size/s,ai-ready" "$b" false

b="$(write_body p4-a2.md \
"## What
Top bar shows \`⚑ N pending\` in yellow when the permit queue has items; hidden when empty. Refresh on the 100ms tick.

## Acceptance criteria
- [ ] Count refreshes ≤ 200ms after a queue file appears
- [ ] Hidden state when count == 0 (no clutter)
- [ ] Survives races: file disappearing between scan and count

## Dependencies
P4-A1, P1-3.")"
mk "[phase-4 / permit] P4-A2 top bar '⚑ N pending' indicator" \
   "$MS_P4" "$UM,tui-phase/4,component/tui,type/feature,priority/critical,size/s,ai-ready" "$b" false

b="$(write_body p4-a3.md \
"## What
A 4th PERMIT tab in Focus Mode, visible only when count > 0. Lists queued items with command (truncated to 60 chars), relative time, and short ID.

## Acceptance criteria
- [ ] Tab key 4 switches to PERMIT
- [ ] Hidden entirely when count == 0
- [ ] ↑/↓ moves cursor between items
- [ ] Footer changes to \`g grant · x deny · esc back\` when PERMIT tab active

## Dependencies
P4-A1, P2-3.")"
mk "[phase-4 / permit] P4-A3 PERMIT tab in Focus Mode (conditional on count>0)" \
   "$MS_P4" "$UM,tui-phase/4,component/tui,type/feature,priority/critical,size/m,ai-ready" "$b" false

b="$(write_body p4-a4.md \
"## What
\`g\` grants selected, \`x\` denies selected by dispatching \`devloop permit grant <ID>\` / \`devloop permit deny <ID>\` via chat.dispatchShell. Refreshes the queue after.

## Acceptance criteria
- [ ] g writes allow to the matching .response (verified via subsequent readPermitQueue)
- [ ] x writes deny
- [ ] List re-reads after each action; cursor stays at sensible position
- [ ] Error from subprocess surfaces inline

## Dependencies
P4-A3.")"
mk "[phase-4 / permit] P4-A4 'g' grant / 'x' deny via dispatchShell + refresh" \
   "$MS_P4" "$UM,tui-phase/4,component/tui,type/feature,priority/critical,size/s,ai-ready" "$b" false

b="$(write_body p4-a5.md \
"## What
Detect gate timeout by reading \`.devloop/sessions/<TASK-ID>/status\`. If content starts with \`timed-out-at-\`, reconstruct the offending command from the last \`approval.request\` event in the per-session \`events.ndjson\`.

## Acceptance criteria
- [ ] Status reader returns one of: running, needs-work, timed-out-at-plan, timed-out-at-diff, rejected-at-plan, rejected-at-diff, approved, rejected, or unknown
- [ ] Command reconstruction reads the last approval.request event's \`summary\` or \`detail_path\`
- [ ] Returns \`(status, cmd, ok)\` tuple

## Notes for implementer
Brief wrongly named the file \`worker.state\` — does not exist. Correct path: \`.devloop/sessions/<TASK-ID>/status\`.

## Dependencies
PF-6.")"
mk "[phase-4 / permit] P4-A5 detect gate-timeout (status file + approval.request lookup)" \
   "$MS_P4" "$UM,tui-phase/4,component/tui,type/feature,priority/critical,size/m,needs-spec-correction" "$b" false

b="$(write_body p4-a6.md \
"## What
Focus Mode contextual footer for gate-timeout state: \`⚠ approval timed out: \"<cmd>\" · tab 4 permit · esc back\`.

## Acceptance criteria
- [ ] Footer replaces normal kbd strip when any phase shows gate-timeout
- [ ] Truncated command rendered in cyan, action hint in dim
- [ ] Tab 4 explicitly named so user knows how to act

## Dependencies
P4-A5.")"
mk "[phase-4 / permit] P4-A6 contextual footer for gate-timeout" \
   "$MS_P4" "$UM,tui-phase/4,component/tui,type/feature,priority/high,size/s,ai-ready" "$b" false

b="$(write_body p4-a7.md \
"## What
Palette actions \`G permit grant\`, \`X permit deny\`, \`Q permit status\`. When invoked without an argument, open an inline textinput for the ID or command pattern.

## Acceptance criteria
- [ ] Three palette entries registered
- [ ] G/X prompt → dispatch permit grant/deny <ID>
- [ ] Q prints permit status output into chat scrollback

## Dependencies
P2-6, P4-A1.")"
mk "[phase-4 / permit] P4-A7 palette G/X/Q with inline textinput prompt" \
   "$MS_P4" "$UM,tui-phase/4,component/tui,type/feature,priority/high,size/s,ai-ready" "$b" false

b="$(write_body p4-a8.md \
"## What
Tests for the permit queue parser (malformed/missing files), gate-timeout detection, and grant/deny dispatch wiring.

## Acceptance criteria
- [ ] Fuzz-style test feeds malformed JSON, asserts no panic + correct skip behaviour
- [ ] Gate-timeout test simulates status file + events.ndjson, asserts command reconstruction

## Dependencies
P4-A1..P4-A7.")"
mk "[phase-4 / permit] P4-A8 tests for parser / timeout / dispatch" \
   "$MS_P4" "$UM,tui-phase/4,component/tui,type/test,priority/medium,size/s,ai-ready" "$b" false

# B. Daemon control (3)
b="$(write_body p4-b1.md \
"## What
Palette actions \`I daemon start\`, \`K daemon stop\`, \`J daemon log\`.

## Acceptance criteria
- [ ] Three palette entries registered
- [ ] I dispatches \`devloop daemon\`
- [ ] K dispatches \`devloop daemon stop\`
- [ ] J switches to a Daemon-log streaming pane (P4-B2)

## Dependencies
P2-6.")"
mk "[phase-4 / daemon] P4-B1 palette I/K/J actions for daemon start/stop/log" \
   "$MS_P4" "$UM,tui-phase/4,component/tui,type/feature,priority/critical,size/s,ai-ready" "$b" false

b="$(write_body p4-b2.md \
"## What
Daemon-log streaming pane (reuses chat.dispatchShell + bubbles/viewport). Cancellation via \`esc\` only — \`ctrl+c\` remains the global quit binding.

## Acceptance criteria
- [ ] \`devloop daemon log\` streamed into a labelled viewport
- [ ] esc invokes the rc.cancel() pattern (mirror chat.go's dispatch teardown)
- [ ] No goroutine leak after closing pane (verifiable via runtime.NumGoroutine delta in a test)

## Notes for implementer
Brief originally said \"ctrl+c or esc\" — corrected to esc only because ctrl+c is the global quit.

## Dependencies
P4-B1.")"
mk "[phase-4 / daemon] P4-B2 daemon-log streaming pane (esc cancels)" \
   "$MS_P4" "$UM,tui-phase/4,component/tui,type/feature,priority/critical,size/m,needs-spec-correction" "$b" false

b="$(write_body p4-b3.md \
"## What
Top bar restart counter using PF-4 \`daemon status --json\`. Falls back to scanning \`.devloop/daemon.log\` for occurrences of \`Restarting in\` in the last 50 lines.

## Acceptance criteria
- [ ] When restart_count == 0, top bar shows \`daemon ✓\` green
- [ ] When restart_count > 0, shows \`daemon ✓ ×N\` yellow
- [ ] When max_reached, shows red border / colour shift
- [ ] Documented as \"recent restarts\" (not lifetime) when using log fallback

## Dependencies
P4-B1, PF-4.")"
mk "[phase-4 / daemon] P4-B3 top bar restart counter" \
   "$MS_P4" "$UM,tui-phase/4,component/tui,type/feature,priority/high,size/s,ai-ready" "$b" false

# C. Resume / Quiet / Escalation (5)
b="$(write_body p4-c1.md \
"## What
Helpers \`stuckThreshold()\` and \`isPhaseQuiet(ps)\`. Threshold from env \`DEVLOOP_STUCK_THRESHOLD_MIN\` (default 10). **Wording is \"quiet\" everywhere — never \"stuck\"** for the no-output case.

## Acceptance criteria
- [ ] Default 10 min; env var overrides
- [ ] isPhaseQuiet returns true only when phase is running AND time-since-update > threshold
- [ ] phase_status_test.go covers env override and edge cases

## Dependencies
None.")"
mk "[phase-4 / resume] P4-C1 stuckThreshold() + isPhaseQuiet() helpers (wording: 'quiet')" \
   "$MS_P4" "$UM,tui-phase/4,component/tui,type/feature,priority/critical,size/s,ai-ready" "$b" false

b="$(write_body p4-c2.md \
"## What
Add three phase card styles in \`internal/theme\`: \`StylePhaseBoxQuiet\` (yellow border, dark bg), \`StylePhaseBoxStuck\` (red, for gate-timeout), \`StylePhaseBoxReArch\` (blue, for re-architecting after escalation).

## Acceptance criteria
- [ ] Three new exported styles
- [ ] Used by P4-C3 (re-arch) and P4-C4 (quiet)

## Dependencies
P1-1.")"
mk "[phase-4 / resume] P4-C2 phase card styles: Quiet (yellow) / Stuck (red) / ReArch (blue)" \
   "$MS_P4" "$UM,tui-phase/4,component/tui,type/feature,priority/critical,size/xs,ai-ready" "$b" false

b="$(write_body p4-c3.md \
"## What
Subscribe to \`phase.escalate\` events from the stream.Tailer. When seen, render the active phase card with StylePhaseBoxReArch and footer \`⟳ re-architecting after retries exhausted · waiting…\`. Return to normal when the next \`phase.start architect\` (or respec) event arrives.

## Acceptance criteria
- [ ] Subscription added in FocusModel (or shared state)
- [ ] Card transitions: yellow (quiet) → blue (escalate) → normal (next phase.start)
- [ ] No stdout scraping; entirely event-driven

## Dependencies
PF-1, P2-3.

## Notes for implementer
Brief originally said scrape worker stdout for \"max retries exhausted\" — corrected to consume the PF-1 NDJSON event.")"
mk "[phase-4 / resume] P4-C3 re-architect detection via phase.escalate (no stdout scraping)" \
   "$MS_P4" "$UM,tui-phase/4,component/tui,type/feature,priority/critical,size/m,needs-spec-correction" "$b" false

b="$(write_body p4-c4.md \
"## What
Dashboard task list shows a secondary dim line under the task feature when a phase is quiet or gate-timed-out: \`└ worker quiet 14m ⚠\` or \`└ worker timed out ⊘\`.

## Acceptance criteria
- [ ] Secondary line only when one of the conditions holds
- [ ] Quiet uses yellow; gate-timeout uses red
- [ ] Task-picker delegate row height adapts (or wraps)

## Dependencies
P4-C1, P4-A5.")"
mk "[phase-4 / resume] P4-C4 dashboard task list secondary 'quiet'/'timed out' line" \
   "$MS_P4" "$UM,tui-phase/4,component/tui,type/feature,priority/high,size/s,ai-ready" "$b" false

b="$(write_body p4-c5.md \
"## What
Palette action \`Z resume\` dispatches \`devloop resume\`. On non-zero exit, surface a clear error in the chat scrollback / log. **No fallback to \`devloop work\`** — fail clearly.

## Acceptance criteria
- [ ] Z palette entry registered
- [ ] On dispatch error: red ⚠ line in chat with stderr included
- [ ] No silent substitution

## Dependencies
P2-6.")"
mk "[phase-4 / resume] P4-C5 palette 'Z resume' (no fallback to work)" \
   "$MS_P4" "$UM,tui-phase/4,component/tui,type/feature,priority/high,size/s,ai-ready" "$b" false

# D. Cheap additions (2)
b="$(write_body p4-d1.md \
"## What
Palette action \`E run\` with an inline textinput prompt for the feature string before dispatching \`devloop run \"<feature>\"\`.

## Acceptance criteria
- [ ] E palette entry registered
- [ ] Selecting it opens a textinput (\"What's the feature?\")
- [ ] Empty input cancels gracefully

## Dependencies
P2-6.")"
mk "[phase-4 / d] P4-D1 palette 'E run' with feature-string prompt" \
   "$MS_P4" "$UM,tui-phase/4,component/tui,type/feature,priority/medium,size/s,ai-ready" "$b" false

b="$(write_body p4-d2.md \
"## What
In Focus Mode's LOG tab, cycle between pipeline / notifications / sessions logs using \`,\` (previous) and \`.\` (next). Label active log type in the tab name (e.g., \"LOG (notifications)\").

## Acceptance criteria
- [ ] Three sources cycle in order
- [ ] Missing file shows \"(no log yet)\"
- [ ] State persists per Focus task

## Dependencies
P2-3.")"
mk "[phase-4 / d] P4-D2 log type cycling in Focus LOG tab (pipeline/notifications/sessions)" \
   "$MS_P4" "$UM,tui-phase/4,component/tui,type/feature,priority/medium,size/s,ai-ready" "$b" false

echo "── DONE ────────────────────────────────────────────────"
rm -rf "$BODY_DIR"
