package views

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/shaifulshabuj/devloop/devloop-tui/internal/stream"
)

// ─── helpers ──────────────────────────────────────────────────────────────────

// makeSession creates a fake session directory tree and returns the rootDir.
// If multiple sessions are passed they are all created.
func makeSession(t *testing.T, sessions []stream.Session) string {
	t.Helper()
	root := t.TempDir()
	for _, s := range sessions {
		dir := filepath.Join(root, ".devloop", "sessions", s.ID)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		if s.Feature != "" {
			writeFile(t, filepath.Join(dir, "feature.txt"), s.Feature)
		}
		if s.Status != "" {
			writeFile(t, filepath.Join(dir, "status"), s.Status)
		}
		if !s.StartedAt.IsZero() {
			writeFile(t, filepath.Join(dir, "started_at"), s.StartedAt.Format("2006-01-02T15:04:05"))
		}
		for phase, ps := range s.PhaseStates {
			val := ps.Status
			if !ps.Time.IsZero() {
				val += ":" + ps.Time.Format("2006-01-02T15:04:05")
			}
			writeFile(t, filepath.Join(dir, phase+".state"), val)
		}
	}
	return root
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("writeFile %s: %v", path, err)
	}
}

// driveModel sends a sequence of messages to the model and returns the final
// model and the combined View() output after all updates.
func driveModel(t *testing.T, m DashboardModel, msgs ...tea.Msg) DashboardModel {
	t.Helper()
	var model tea.Model = m
	for _, msg := range msgs {
		var _ tea.Cmd
		model, _ = model.Update(msg)
	}
	return model.(DashboardModel)
}

// ─── Tests ────────────────────────────────────────────────────────────────────

// TestNewDashboard_NoSessions: a temp dir with no .devloop/ → View() contains
// "no session selected".
func TestNewDashboard_NoSessions(t *testing.T) {
	root := t.TempDir() // empty dir — no .devloop/ at all

	m := NewDashboardWithOptions(root, DashboardOptions{NoStream: true})

	// Load sessions (empty).
	sessions, err := stream.Scan(root)
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	m = driveModel(t, m, sessionsLoadedMsg{sessions: sessions})

	view := m.View()
	if !strings.Contains(view, "no session selected") {
		t.Errorf("expected 'no session selected' in view; got:\n%s", view)
	}
}

// TestNewDashboard_OneSession: one session on disk → View() contains feature
// text AND architect phase rendered by pipeline_grid.
func TestNewDashboard_OneSession(t *testing.T) {
	s := stream.Session{
		ID:      "TASK-20260516-100000",
		Feature: "add authentication flow",
		Status:  "running",
		PhaseStates: map[string]stream.PhaseState{
			"architect": {Status: "done"},
		},
	}
	root := makeSession(t, []stream.Session{s})

	m := NewDashboardWithOptions(root, DashboardOptions{NoStream: true})

	sessions, err := stream.Scan(root)
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	m = driveModel(t, m, sessionsLoadedMsg{sessions: sessions})

	view := m.View()

	if !strings.Contains(view, "add authentication flow") {
		t.Errorf("feature text not found in view; view:\n%s", view)
	}
	// pipeline_grid renders the architect phase with a glyph; at minimum the
	// phase name "architect" should appear.
	if !strings.Contains(view, "architect") {
		t.Errorf("'architect' phase name not found in view; view:\n%s", view)
	}
	// For a done phase, pipeline_grid renders "✓".
	if !strings.Contains(view, "✓") {
		t.Errorf("done glyph '✓' not found in view; view:\n%s", view)
	}
}

// TestDashboard_NavigationUpdatesActive: 2 sessions; send KeyDown → right pane
// shows the second session's ID.
func TestDashboard_NavigationUpdatesActive(t *testing.T) {
	sessions := []stream.Session{
		{ID: "TASK-20260516-200000", Feature: "feature alpha", Status: "done"},
		{ID: "TASK-20260516-100000", Feature: "feature beta", Status: "running"},
	}
	root := makeSession(t, sessions)

	m := NewDashboardWithOptions(root, DashboardOptions{NoStream: true})

	loaded, err := stream.Scan(root)
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	// Sort order from Scan: TASK-20260516-200000 first (no StartedAt, descending ID).
	m = driveModel(t, m, sessionsLoadedMsg{sessions: loaded})

	// Confirm first session is shown initially.
	view1 := m.View()
	if !strings.Contains(view1, "TASK-20260516-200000") {
		t.Errorf("expected first session ID in initial view; got:\n%s", view1)
	}

	// Navigate down.
	m = driveModel(t, m, tea.KeyMsg{Type: tea.KeyDown})

	view2 := m.View()
	if !strings.Contains(view2, "TASK-20260516-100000") {
		t.Errorf("expected second session ID after navigation; got:\n%s", view2)
	}
}

// TestDashboard_RKeyRescans: create dashboard with one session; write a second
// session to disk; press r; verify the new session appears.
func TestDashboard_RKeyRescans(t *testing.T) {
	s1 := stream.Session{
		ID:      "TASK-20260516-100000",
		Feature: "original feature",
		Status:  "done",
	}
	root := makeSession(t, []stream.Session{s1})

	m := NewDashboardWithOptions(root, DashboardOptions{NoStream: true})

	loaded, err := stream.Scan(root)
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	m = driveModel(t, m, sessionsLoadedMsg{sessions: loaded})

	// Write a second session directly to disk.
	s2 := stream.Session{
		ID:      "TASK-20260516-200000",
		Feature: "brand new feature",
		Status:  "running",
	}
	_ = makeSessionInRoot(t, root, s2)

	// Press 'r' — this enqueues a scanCmd but does NOT immediately execute it
	// in unit test context (no running tea.Program). Instead, we manually
	// execute the scan and feed the result back.
	m = driveModel(t, m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("r")})

	// Simulate the scan completing.
	newSessions, err := stream.Scan(root)
	if err != nil {
		t.Fatalf("Scan after add: %v", err)
	}
	m = driveModel(t, m, sessionsLoadedMsg{sessions: newSessions})

	view := m.View()
	if !strings.Contains(view, "brand new feature") {
		t.Errorf("new session not visible after r+rescan; view:\n%s", view)
	}
}

// makeSessionInRoot creates a single session directory inside an existing root.
func makeSessionInRoot(t *testing.T, root string, s stream.Session) string {
	t.Helper()
	dir := filepath.Join(root, ".devloop", "sessions", s.ID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if s.Feature != "" {
		writeFile(t, filepath.Join(dir, "feature.txt"), s.Feature)
	}
	if s.Status != "" {
		writeFile(t, filepath.Join(dir, "status"), s.Status)
	}
	return dir
}
