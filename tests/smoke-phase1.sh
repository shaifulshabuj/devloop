#!/usr/bin/env bash
# Phase 1 smoke test — exercises emit_event, _approval_gate, _approval_resolve,
# _extract_plan_summary, _extract_diff_summary, _build_diff_feedback_template,
# _diff_feedback_has_content against a temp project.
# Does NOT invoke any LLM provider — stubs the pipeline commands.

set -uo pipefail

SCRIPT="${1:-/Volumes/SATECHI_WD_BLACK_2/dev/devloop/devloop.sh}"
[[ -f "$SCRIPT" ]] || { echo "FAIL: devloop.sh not found at $SCRIPT"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1
git init -q

# Minimal env so helpers can resolve paths
export DEVLOOP_DIR=".devloop"
export SPECS_PATH="$TMP/.devloop/specs"
mkdir -p "$SPECS_PATH" .devloop/sessions

# Stub find_project_root and _session_dir
find_project_root() { echo "$TMP"; }
_session_dir() { echo "$TMP/.devloop/sessions/${1:-}"; }

# Stub UI helpers used by the approval gate output
CYAN=''; GREEN=''; YELLOW=''; RED=''; BLUE=''; MAGENTA=''; GRAY=''; BOLD=''; RESET=''
info()    { echo "[info] $*"; }
success() { echo "[ok]   $*"; }
warn()    { echo "[warn] $*"; }
error()   { echo "[err]  $*" >&2; }
step()    { echo "[step] $*"; }
divider() { echo "----"; }

# Load just the slice of devloop.sh that has the helpers we want.
# emit_event lives 84..129; approval/extraction/diff helpers 4008..4271.
# _approval_read_decision is at ~4028; diff-gate helpers end at ~4271.
# _compute_resume_from lives 8009..8066 (Phase 4C).
# Slice on exact function boundaries so the source is balanced.
TMPSRC="$(mktemp)"
sed -n '84,129p; 4008,4271p; 8009,8066p' "$SCRIPT" > "$TMPSRC"
# shellcheck disable=SC1090
source "$TMPSRC"
rm -f "$TMPSRC"

pass=0; fail=0
assert() {
  local desc="$1"; local cond="$2"
  if eval "$cond"; then echo "PASS  $desc"; pass=$((pass+1))
  else echo "FAIL  $desc  (cond: $cond)"; fail=$((fail+1)); fi
}

# ── Test 1: emit_event writes both sinks ────────────────────────────────────
TASK="TASK-20260516-100000"
mkdir -p ".devloop/sessions/$TASK"
DEVLOOP_CURRENT_SESSION_ID="$TASK" emit_event "test.kind" foo=bar count=42
assert "project sink has the event"   "[[ -f .devloop/events.ndjson ]] && grep -q '\"kind\":\"test.kind\"' .devloop/events.ndjson"
assert "session sink has the event"   "[[ -f .devloop/sessions/$TASK/events.ndjson ]] && grep -q '\"kind\":\"test.kind\"' .devloop/sessions/$TASK/events.ndjson"
assert "fields preserved"             "grep -q '\"foo\":\"bar\"' .devloop/events.ndjson && grep -q '\"count\":\"42\"' .devloop/events.ndjson"
assert "ts is ISO-8601 UTC"           "grep -qE '\"ts\":\"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\"' .devloop/events.ndjson"

# ── Test 2: DEVLOOP_AUTO bypass ─────────────────────────────────────────────
> .devloop/events.ndjson
mkdir -p ".devloop/sessions/$TASK/approvals"
DEVLOOP_AUTO=1 DEVLOOP_CURRENT_SESSION_ID="$TASK" _approval_gate "plan" "test summary"
rc=$?
assert "AUTO returns 0"               "[[ $rc -eq 0 ]]"
assert "AUTO emits approval.request"  "grep -q '\"kind\":\"approval.request\"' .devloop/events.ndjson"
assert "AUTO emits approval.decision" "grep -q '\"kind\":\"approval.decision\"' .devloop/events.ndjson && grep -q '\"decision\":\"approve\"' .devloop/events.ndjson && grep -q '\"source\":\"auto\"' .devloop/events.ndjson"
assert "AUTO writes decision file"    "[[ -f .devloop/sessions/$TASK/approvals/plan.json ]]"

# ── Test 3: pre-written decision file ───────────────────────────────────────
> .devloop/events.ndjson
echo '{"decision":"reject"}' > ".devloop/sessions/$TASK/approvals/plan.json"
DEVLOOP_CURRENT_SESSION_ID="$TASK" _approval_gate "plan" "test summary"
rc=$?
assert "pre-written reject returns 1" "[[ $rc -eq 1 ]]"
assert "decision source=pre-written"  "grep -q '\"source\":\"pre-written\"' .devloop/events.ndjson"
assert "decision=reject"              "grep -q '\"decision\":\"reject\"' .devloop/events.ndjson"

# ── Test 4: pre-written edit ────────────────────────────────────────────────
> .devloop/events.ndjson
echo '{"decision":"edit"}' > ".devloop/sessions/$TASK/approvals/plan.json"
DEVLOOP_CURRENT_SESSION_ID="$TASK" _approval_gate "plan" "test summary"
rc=$?
assert "pre-written edit returns 2"   "[[ $rc -eq 2 ]]"

# ── Test 5: no surface → reject ─────────────────────────────────────────────
rm -f ".devloop/sessions/$TASK/approvals/plan.json"
> .devloop/events.ndjson
# Force the no-surface branch: no AUTO, no gum, redirect /dev/tty to /dev/null
DEVLOOP_CURRENT_SESSION_ID="$TASK" PATH="/usr/bin:/bin" _approval_gate "plan" "test" </dev/null >/dev/null 2>&1
rc=$?
# Either tty branch (timeout reject) or no-tty branch — both should return 1
assert "no-input → returns 1 (reject)" "[[ $rc -eq 1 ]]"

# ── Test 5b: _approval_read_decision helper ─────────────────────────────────
echo '{"ts":"2026-01-01T00:00:00Z","gate":"plan","decision":"edit","source":"tui"}' \
  > ".devloop/sessions/$TASK/approvals/plan.json"
read_out="$(_approval_read_decision ".devloop/sessions/$TASK/approvals/plan.json")"
assert "_approval_read_decision returns edit" "[[ \"$read_out\" == 'edit' ]]"

# Missing file → empty output
read_out_missing="$(_approval_read_decision ".devloop/sessions/$TASK/approvals/nosuchfile.json")"
assert "_approval_read_decision missing file → empty" "[[ -z \"$read_out_missing\" ]]"

# ── Test 5c: DEVLOOP_APPROVAL_WAIT polling path ──────────────────────────────
rm -f ".devloop/sessions/$TASK/approvals/plan.json"
> .devloop/events.ndjson
# Drop the decision file after a short delay in the background
( sleep 0.5 && echo '{"decision":"approve"}' > ".devloop/sessions/$TASK/approvals/plan.json" ) &
dropper_pid=$!
DEVLOOP_APPROVAL_WAIT=4 DEVLOOP_CURRENT_SESSION_ID="$TASK" \
  _approval_gate "plan" "polling test summary" </dev/null >/dev/null 2>&1
rc_poll=$?
wait "$dropper_pid" 2>/dev/null || true
assert "APPROVAL_WAIT poll picks up approve → returns 0" "[[ $rc_poll -eq 0 ]]"
assert "APPROVAL_WAIT poll emits tui-poll source" \
  "grep -q '\"source\":\"tui-poll\"' .devloop/events.ndjson"

# ── Test 5d: DEVLOOP_APPROVAL_WAIT timeout falls through ────────────────────
rm -f ".devloop/sessions/$TASK/approvals/plan.json"
> .devloop/events.ndjson
# No background writer — poll should time out and hit no-tty → reject
DEVLOOP_APPROVAL_WAIT=1 DEVLOOP_CURRENT_SESSION_ID="$TASK" \
  _approval_gate "plan" "timeout test" </dev/null >/dev/null 2>&1
rc_timeout=$?
assert "APPROVAL_WAIT timeout → falls through to no-tty reject (rc=1)" "[[ $rc_timeout -eq 1 ]]"

# ── Test 6: extract plan summary from spec ─────────────────────────────────
cat > "$SPECS_PATH/$TASK.md" <<'SPEC'
# TASK-20260516-100000

## Summary
Add a dark-mode toggle to the settings page that persists user choice
across sessions via localStorage.

## Files to Touch
- src/Settings.tsx
- src/theme.ts
- src/__tests__/theme.test.ts

## Implementation Steps
1. Add toggle component
SPEC
out="$(_extract_plan_summary "$SPECS_PATH/$TASK.md")"
assert "summary contains feature text" "echo \"\$out\" | grep -qi 'dark-mode toggle'"
assert "summary lists files"           "echo \"\$out\" | grep -q 'src/Settings.tsx' && echo \"\$out\" | grep -q 'src/theme.ts'"

# ── Test 7: extract diff summary fallback ───────────────────────────────────
# No pre-commit baseline; should fall back to `git diff --stat HEAD`
echo "hello" > a.txt && git add a.txt && git -c user.email=t@t -c user.name=t commit -q -m init
echo "world" >> a.txt
out="$(_extract_diff_summary "$TASK")"
assert "diff summary mentions a.txt"   "echo \"\$out\" | grep -q 'a.txt'"

# ── Test 8: _build_diff_feedback_template ───────────────────────────────────
fake_diff="$TMP/fake.diff"
echo "--- a/foo.txt" > "$fake_diff"
echo "+++ b/foo.txt" >> "$fake_diff"
echo "@@ -1 +1 @@" >> "$fake_diff"
echo "+hello" >> "$fake_diff"
tmpl="$(_build_diff_feedback_template "TASK-001" "$fake_diff")"
assert "template contains ## Feedback section"   "echo \"\$tmpl\" | grep -q '## Feedback'"
assert "template contains fenced diff block"      "echo \"\$tmpl\" | grep -q '\`\`\`diff'"
assert "template task id is in header"            "echo \"\$tmpl\" | grep -q 'TASK-001'"

# ── Test 9: _diff_feedback_has_content — unedited template returns false ─────
unedited_file="$TMP/unedited-feedback.md"
_build_diff_feedback_template "TASK-001" "$fake_diff" > "$unedited_file"
_diff_feedback_has_content "$unedited_file" && rc_unedited=0 || rc_unedited=$?
assert "unedited template has no content (returns 1)" "[[ $rc_unedited -ne 0 ]]"

# ── Test 10: _diff_feedback_has_content — edited template returns true ───────
edited_file="$TMP/edited-feedback.md"
_build_diff_feedback_template "TASK-001" "$fake_diff" > "$edited_file"
# Replace the placeholder with real instructions (portable: awk rewrite avoids BSD/GNU sed -i difference)
awk '{gsub(/\(your instructions here\)/, "Remove the unused import on line 5.")} 1' "$edited_file" > "${edited_file}.tmp" && mv "${edited_file}.tmp" "$edited_file"
_diff_feedback_has_content "$edited_file" && rc_edited=0 || rc_edited=$?
assert "edited template has content (returns 0)" "[[ $rc_edited -eq 0 ]]"

# ── Phase 4C: _compute_resume_from ──────────────────────────────────────────
# All tests use a temporary session dir with hand-crafted events.ndjson.

RSESS="$TMP/.devloop/sessions/TASK-phase4c-test"
mkdir -p "$RSESS"

# Helper: write events.ndjson from positional args (one JSON line each)
_write_events() {
  local sdir="$1"; shift
  printf '' > "$sdir/events.ndjson"
  for line in "$@"; do
    printf '%s\n' "$line" >> "$sdir/events.ndjson"
  done
}

# ── 4C-1: last event = phase.end{architect,done} → next = worker ────────────
_write_events "$RSESS" \
  '{"ts":"2026-01-01T00:00:00Z","session":"TASK-phase4c-test","kind":"session.start","feature":"x"}' \
  '{"ts":"2026-01-01T00:01:00Z","session":"TASK-phase4c-test","kind":"phase.end","phase":"architect","status":"done"}'
result_4c1="$(_compute_resume_from "$RSESS")"
assert "4C-1: after architect.done → worker"   "[[ \"$result_4c1\" == 'worker' ]]"

# ── 4C-2: last event = phase.end{worker,done} → next = reviewer ─────────────
_write_events "$RSESS" \
  '{"ts":"2026-01-01T00:00:00Z","session":"TASK-phase4c-test","kind":"session.start","feature":"x"}' \
  '{"ts":"2026-01-01T00:01:00Z","session":"TASK-phase4c-test","kind":"phase.end","phase":"architect","status":"done"}' \
  '{"ts":"2026-01-01T00:02:00Z","session":"TASK-phase4c-test","kind":"phase.end","phase":"worker","status":"done"}'
result_4c2="$(_compute_resume_from "$RSESS")"
assert "4C-2: after worker.done → reviewer"    "[[ \"$result_4c2\" == 'reviewer' ]]"

# ── 4C-3: reviewer.needs-work + fix-1.done → next = reviewer ────────────────
_write_events "$RSESS" \
  '{"ts":"2026-01-01T00:00:00Z","session":"TASK-phase4c-test","kind":"session.start","feature":"x"}' \
  '{"ts":"2026-01-01T00:01:00Z","session":"TASK-phase4c-test","kind":"phase.end","phase":"architect","status":"done"}' \
  '{"ts":"2026-01-01T00:02:00Z","session":"TASK-phase4c-test","kind":"phase.end","phase":"worker","status":"done"}' \
  '{"ts":"2026-01-01T00:03:00Z","session":"TASK-phase4c-test","kind":"phase.end","phase":"reviewer","status":"needs-work"}' \
  '{"ts":"2026-01-01T00:04:00Z","session":"TASK-phase4c-test","kind":"phase.end","phase":"fix-1","status":"done"}'
result_4c3="$(_compute_resume_from "$RSESS")"
assert "4C-3: after fix-1.done → reviewer"     "[[ \"$result_4c3\" == 'reviewer' ]]"

# ── 4C-4: reviewer.approved → complete ──────────────────────────────────────
_write_events "$RSESS" \
  '{"ts":"2026-01-01T00:00:00Z","session":"TASK-phase4c-test","kind":"session.start","feature":"x"}' \
  '{"ts":"2026-01-01T00:01:00Z","session":"TASK-phase4c-test","kind":"phase.end","phase":"architect","status":"done"}' \
  '{"ts":"2026-01-01T00:02:00Z","session":"TASK-phase4c-test","kind":"phase.end","phase":"worker","status":"done"}' \
  '{"ts":"2026-01-01T00:03:00Z","session":"TASK-phase4c-test","kind":"phase.end","phase":"reviewer","status":"approved"}'
result_4c4="$(_compute_resume_from "$RSESS")"
assert "4C-4: after reviewer.approved → complete" "[[ \"$result_4c4\" == 'complete' ]]"

# ── 4C-5: no events.ndjson → worker ──────────────────────────────────────────
RSESS2="$TMP/.devloop/sessions/TASK-phase4c-nofile"
mkdir -p "$RSESS2"
# deliberately no events.ndjson
result_4c5="$(_compute_resume_from "$RSESS2")"
assert "4C-5: missing events file → worker"    "[[ \"$result_4c5\" == 'worker' ]]"

echo ""
echo "Summary: $pass passed, $fail failed"
exit $fail
