package views

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/shaifulshabuj/devloop/devloop-tui/internal/stream"
	"github.com/shaifulshabuj/devloop/devloop-tui/internal/uimsg"
)

func driveFocus(t *testing.T, m FocusModel, msg tea.Msg) FocusModel {
	t.Helper()
	updated, _ := m.Update(msg)
	mm, ok := updated.(FocusModel)
	if !ok {
		t.Fatalf("Update returned %T, want FocusModel", updated)
	}
	return mm
}

func TestFocus_EmptyState(t *testing.T) {
	root := t.TempDir()
	m := NewFocusWithOptions(root, FocusOptions{NoStream: true})
	m = driveFocus(t, m, tea.WindowSizeMsg{Width: 100, Height: 30})
	out := stripANSI(m.View())
	if !strings.Contains(out, "no sessions yet") {
		t.Errorf("expected empty-state hint, got %q", out)
	}
}

func TestFocus_StartIndexFromID(t *testing.T) {
	root := t.TempDir()
	m := NewFocusWithOptions(root, FocusOptions{
		StartIndex: 0, // would be wrong — should be overridden by StartID
		StartID:    "TASK-B",
		NoStream:   true,
	})
	m = driveFocus(t, m, focusSessionsLoadedMsg{sessions: []stream.Session{
		{ID: "TASK-A", Feature: "a", Status: "done"},
		{ID: "TASK-B", Feature: "b", Status: "running"},
		{ID: "TASK-C", Feature: "c", Status: "needs-work"},
	}})
	if m.idx != 1 {
		t.Errorf("expected idx 1 from StartID match, got %d", m.idx)
	}
}

func TestFocus_LeftRightWrapAround(t *testing.T) {
	root := t.TempDir()
	m := NewFocusWithOptions(root, FocusOptions{NoStream: true})
	m = driveFocus(t, m, focusSessionsLoadedMsg{sessions: []stream.Session{
		{ID: "TASK-A", Feature: "a"},
		{ID: "TASK-B", Feature: "b"},
	}})
	m = driveFocus(t, m, tea.WindowSizeMsg{Width: 100, Height: 30})

	// Right from idx 0 → 1
	m = driveFocus(t, m, tea.KeyMsg{Type: tea.KeyRight})
	if m.idx != 1 {
		t.Errorf("expected idx 1 after →, got %d", m.idx)
	}
	// Right from 1 wraps to 0
	m = driveFocus(t, m, tea.KeyMsg{Type: tea.KeyRight})
	if m.idx != 0 {
		t.Errorf("expected wrap to idx 0 after second →, got %d", m.idx)
	}
	// Left from 0 wraps to 1
	m = driveFocus(t, m, tea.KeyMsg{Type: tea.KeyLeft})
	if m.idx != 1 {
		t.Errorf("expected wrap to idx 1 after ←, got %d", m.idx)
	}
}

func TestFocus_TabSwitching(t *testing.T) {
	root := t.TempDir()
	m := NewFocusWithOptions(root, FocusOptions{NoStream: true})
	m = driveFocus(t, m, focusSessionsLoadedMsg{sessions: []stream.Session{
		{ID: "TASK-A", Feature: "a"},
	}})

	if m.tab != TabLog {
		t.Errorf("expected default tab TabLog, got %v", m.tab)
	}
	m = driveFocus(t, m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("2")})
	if m.tab != TabSpec {
		t.Errorf("expected '2' → TabSpec, got %v", m.tab)
	}
	m = driveFocus(t, m, tea.KeyMsg{Type: tea.KeyTab})
	if m.tab != TabDiff {
		t.Errorf("expected tab cycle → TabDiff, got %v", m.tab)
	}
	m = driveFocus(t, m, tea.KeyMsg{Type: tea.KeyTab})
	if m.tab != TabLog {
		t.Errorf("expected tab cycle wrap → TabLog, got %v", m.tab)
	}
}

func TestFocus_SpecTabLoadsContent(t *testing.T) {
	root := t.TempDir()
	if err := writeAt(root, ".devloop/specs/TASK-A.md", "FOCUS_SPEC_BODY"); err != nil {
		t.Fatalf("write spec: %v", err)
	}
	m := NewFocusWithOptions(root, FocusOptions{StartID: "TASK-A", NoStream: true})
	m = driveFocus(t, m, focusSessionsLoadedMsg{sessions: []stream.Session{
		{ID: "TASK-A", Feature: "a"},
	}})
	m = driveFocus(t, m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("2")}) // SPEC tab
	m = driveFocus(t, m, tea.WindowSizeMsg{Width: 100, Height: 30})

	out := stripANSI(m.View())
	if !strings.Contains(out, "FOCUS_SPEC_BODY") {
		t.Errorf("expected spec body in SPEC tab view, got %q", out)
	}
}

func TestFocus_LogTabAccumulatesEvents(t *testing.T) {
	root := t.TempDir()
	m := NewFocusWithOptions(root, FocusOptions{StartID: "TASK-A", NoStream: true})
	m = driveFocus(t, m, focusSessionsLoadedMsg{sessions: []stream.Session{
		{ID: "TASK-A", Feature: "a"},
	}})
	// Initially LOG tab is empty.
	out := stripANSI(m.View())
	if !strings.Contains(out, "no events yet") {
		t.Errorf("expected empty-log hint, got %q", out)
	}
	// Feed a phase.start event.
	m = driveFocus(t, m, focusStreamEventMsg{event: stream.Event{
		Session: "TASK-A",
		Kind:    "phase.start",
		Phase:   "worker",
	}})
	out = stripANSI(m.View())
	if !strings.Contains(out, "worker") || !strings.Contains(out, "start") {
		t.Errorf("expected log line for phase.start worker, got %q", out)
	}
}

// writeAt creates a file at root/relpath with the given content, creating
// parent directories as needed. Returns the first error encountered.
func writeAt(root, relpath, content string) error {
	full := filepath.Join(root, relpath)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		return err
	}
	return os.WriteFile(full, []byte(content), 0o644)
}

func TestFocus_EscEmitsCloseFocus(t *testing.T) {
	root := t.TempDir()
	m := NewFocusWithOptions(root, FocusOptions{NoStream: true})
	m = driveFocus(t, m, focusSessionsLoadedMsg{sessions: []stream.Session{
		{ID: "TASK-A", Feature: "a"},
	}})

	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEsc})
	if cmd == nil {
		t.Fatal("esc should return a tea.Cmd")
	}
	msg := cmd()
	if _, ok := msg.(uimsg.CloseFocus); !ok {
		t.Errorf("expected uimsg.CloseFocus, got %T", msg)
	}
}
