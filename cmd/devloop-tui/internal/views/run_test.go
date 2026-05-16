package views

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/shaifulshabuj/devloop/devloop-tui/internal/stream"
)

// ─── helpers ──────────────────────────────────────────────────────────────────

// driveRun sends a sequence of messages to a RunModel and returns the final model.
func driveRun(t *testing.T, m RunModel, msgs ...tea.Msg) RunModel {
	t.Helper()
	var model tea.Model = m
	for _, msg := range msgs {
		var _ tea.Cmd
		model, _ = model.Update(msg)
	}
	return model.(RunModel)
}

// makeApprovalRequestEvent creates a fake approval.request stream.Event.
func makeApprovalRequestEvent(sessionID, gate, summary, decisionFile string) stream.Event {
	return stream.Event{
		TS:           time.Now().UTC(),
		Session:      sessionID,
		Kind:         "approval.request",
		Gate:         gate,
		Summary:      summary,
		DetailPath:   ".devloop/specs/" + sessionID + ".md",
		DetailSize:   "1234",
		DecisionFile: decisionFile,
	}
}

// makeApprovalDecisionEvent creates a fake approval.decision stream.Event.
func makeApprovalDecisionEvent(sessionID, gate, decision string) stream.Event {
	return stream.Event{
		TS:       time.Now().UTC(),
		Session:  sessionID,
		Kind:     "approval.decision",
		Gate:     gate,
		Decision: decision,
		Source:   "gum",
	}
}

// ─── Tests ────────────────────────────────────────────────────────────────────

// TestRun_NoTaskID: constructing with empty TaskID → View() shows "no task specified".
func TestRun_NoTaskID(t *testing.T) {
	m := NewRunWithOptions(t.TempDir(), RunOptions{NoStream: true, TaskID: ""})
	view := m.View()
	if !strings.Contains(view, "no task specified") {
		t.Errorf("expected 'no task specified' in view; got:\n%s", view)
	}
}

// TestRun_RendersTask: inject a session via runSessionLoadedMsg → View() contains Task ID and feature.
func TestRun_RendersTask(t *testing.T) {
	const taskID = "TASK-20260516-100001"
	const feature = "add dark mode toggle"

	s := stream.Session{
		ID:      taskID,
		Feature: feature,
		Status:  "running",
		PhaseStates: map[string]stream.PhaseState{
			"architect": {Status: "done"},
		},
	}

	root := makeSession(t, []stream.Session{s})
	m := NewRunWithOptions(root, RunOptions{TaskID: taskID, NoStream: true})
	m = driveRun(t, m, runSessionLoadedMsg{session: &s})

	view := m.View()
	if !strings.Contains(view, taskID) {
		t.Errorf("expected Task ID %q in view; got:\n%s", taskID, view)
	}
	if !strings.Contains(view, feature) {
		t.Errorf("expected feature %q in view; got:\n%s", feature, view)
	}
}

// TestRun_ApprovalModalAppears: inject approval.request event → View() shows "Approval needed" and "gate=plan".
func TestRun_ApprovalModalAppears(t *testing.T) {
	const taskID = "TASK-20260516-100002"
	const feature = "implement search"

	s := stream.Session{
		ID:      taskID,
		Feature: feature,
		Status:  "running",
	}
	root := makeSession(t, []stream.Session{s})

	m := NewRunWithOptions(root, RunOptions{TaskID: taskID, NoStream: true})
	m = driveRun(t, m, runSessionLoadedMsg{session: &s})

	// Inject approval.request event.
	ev := makeApprovalRequestEvent(taskID, "plan", "Implement search with filters", "")
	m = driveRun(t, m, runStreamEventMsg{event: ev})

	view := m.View()
	if !strings.Contains(view, "Approval needed") {
		t.Errorf("expected 'Approval needed' in view; got:\n%s", view)
	}
	if !strings.Contains(view, "gate=plan") {
		t.Errorf("expected 'gate=plan' in view; got:\n%s", view)
	}
}

// TestRun_ApprovalKeysWriteFile: verify that pressing a/r/e writes the correct
// decision to the decision file.
func TestRun_ApprovalKeysWriteFile(t *testing.T) {
	cases := []struct {
		key      tea.Msg
		decision string
	}{
		{tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("a")}, "approve"},
		{tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("r")}, "reject"},
		{tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("e")}, "edit"},
	}

	for _, tc := range cases {
		t.Run("key_"+tc.decision, func(t *testing.T) {
			const taskID = "TASK-20260516-100003"

			root := t.TempDir()
			decisionDir := filepath.Join(root, ".devloop", "sessions", taskID, "approvals")
			if err := os.MkdirAll(decisionDir, 0o755); err != nil {
				t.Fatal(err)
			}
			decisionFile := filepath.Join(decisionDir, "plan.json")

			m := NewRunWithOptions(root, RunOptions{TaskID: taskID, NoStream: true})

			// Inject the approval.request event with decision_file pointing into tempdir.
			ev := makeApprovalRequestEvent(taskID, "plan", "Test approval", decisionFile)
			m = driveRun(t, m, runStreamEventMsg{event: ev})

			// Modal should be visible.
			if m.pendingApproval == nil {
				t.Fatal("expected pendingApproval to be set after approval.request")
			}

			// Press the key — this enqueues a Cmd that writes the file.
			// In the test harness we must execute the returned Cmd manually.
			var model tea.Model = m
			var cmd tea.Cmd
			model, cmd = model.Update(tc.key)

			// The Cmd writes the file. Execute it synchronously.
			if cmd != nil {
				msg := cmd()
				if msg != nil {
					model, _ = model.Update(msg)
				}
			}

			// Verify file was written.
			data, err := os.ReadFile(decisionFile)
			if err != nil {
				t.Fatalf("decision file not written for %q: %v", tc.decision, err)
			}

			var parsed map[string]string
			if err := json.Unmarshal(data, &parsed); err != nil {
				t.Fatalf("decision file is not valid JSON: %v\nContent: %s", err, data)
			}
			if got := parsed["decision"]; got != tc.decision {
				t.Errorf("decision file has decision=%q; want %q", got, tc.decision)
			}
			if parsed["source"] != "tui" {
				t.Errorf("decision file has source=%q; want %q", parsed["source"], "tui")
			}

			// Modal should be dismissed after the key press.
			runM := model.(RunModel)
			if runM.pendingApproval != nil {
				t.Error("expected modal to be dismissed after key press")
			}
			_ = model
		})
	}
}

// TestRun_ApprovalResolvedDismisses: after modal shown, inject approval.decision → modal gone.
func TestRun_ApprovalResolvedDismisses(t *testing.T) {
	const taskID = "TASK-20260516-100004"

	root := t.TempDir()
	m := NewRunWithOptions(root, RunOptions{TaskID: taskID, NoStream: true})

	// Show the modal.
	reqEv := makeApprovalRequestEvent(taskID, "plan", "Some work to review", "")
	m = driveRun(t, m, runStreamEventMsg{event: reqEv})

	if m.pendingApproval == nil {
		t.Fatal("modal did not appear after approval.request")
	}

	viewWithModal := m.View()
	if !strings.Contains(viewWithModal, "Approval needed") {
		t.Errorf("modal not visible in view; got:\n%s", viewWithModal)
	}

	// Inject approval.decision — authoritative dismiss.
	decEv := makeApprovalDecisionEvent(taskID, "plan", "approve")
	m = driveRun(t, m, runStreamEventMsg{event: decEv})

	if m.pendingApproval != nil {
		t.Error("expected pendingApproval to be nil after approval.decision")
	}

	viewAfter := m.View()
	if strings.Contains(viewAfter, "Approval needed") {
		t.Errorf("modal still visible after approval.decision; view:\n%s", viewAfter)
	}
}
