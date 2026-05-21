package views

import (
	"fmt"
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

// ── Top bar (P1-3) ────────────────────────────────────────────────────────────

func TestDashboard_TopBar_DefaultsHealthy(t *testing.T) {
	root := t.TempDir()
	m := NewDashboardWithOptions(root, DashboardOptions{NoStream: true})
	m = m.refreshHealth()

	out := stripANSI(m.renderHeader(120))

	if !strings.Contains(out, "main ✓") {
		t.Errorf("expected 'main ✓' in header, got %q", out)
	}
	if !strings.Contains(out, "worker ✓") {
		t.Errorf("expected 'worker ✓' in header, got %q", out)
	}
	// No pidfile written → daemon ✗
	if !strings.Contains(out, "daemon ✗") {
		t.Errorf("expected 'daemon ✗' in header (no pidfile), got %q", out)
	}
}

func TestDashboard_TopBar_MainLimited(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, ".devloop"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	writeFile(t, filepath.Join(root, ".devloop", "provider-health.sh"),
		"HEALTH_MAIN_LIMITED_SINCE=1716020118\nHEALTH_MAIN_OVERRIDE=copilot\n")

	m := NewDashboardWithOptions(root, DashboardOptions{NoStream: true})
	m = m.refreshHealth()

	out := stripANSI(m.renderHeader(120))

	if !strings.Contains(out, "main ✗→copilot") {
		t.Errorf("expected 'main ✗→copilot' in header, got %q", out)
	}
	if !strings.Contains(out, "worker ✓") {
		t.Errorf("expected 'worker ✓' (worker still healthy) in header, got %q", out)
	}
}

func TestDashboard_TopBar_DaemonAlive(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, ".devloop"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	// Use our own PID — guaranteed alive while the test is running.
	writeFile(t, filepath.Join(root, ".devloop", "daemon.pid"),
		fmt.Sprintf("%d\n", os.Getpid()))

	m := NewDashboardWithOptions(root, DashboardOptions{NoStream: true})
	m = m.refreshHealth()

	out := stripANSI(m.renderHeader(120))
	if !strings.Contains(out, "daemon ✓") {
		t.Errorf("expected 'daemon ✓' (PID %d is us), got %q", os.Getpid(), out)
	}
}

func TestDashboard_TopBar_DaemonRestarts(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, ".devloop"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	writeFile(t, filepath.Join(root, ".devloop", "daemon.pid"),
		fmt.Sprintf("%d\n", os.Getpid()))
	writeFile(t, filepath.Join(root, ".devloop", "daemon.log"),
		"[start] daemon up\n[crash] Restarting in 5s...\n[crash] Restarting in 5s...\n[crash] Restarting in 5s...\n")

	m := NewDashboardWithOptions(root, DashboardOptions{NoStream: true})
	m = m.refreshHealth()

	out := stripANSI(m.renderHeader(120))
	if !strings.Contains(out, "×3") {
		t.Errorf("expected '×3' restart count in header, got %q", out)
	}
}

// ── SPEC panel (P1-8) ─────────────────────────────────────────────────────────

func TestDashboard_SpecPanel_StartsCollapsed(t *testing.T) {
	s := stream.Session{ID: "TASK-20260520-001", Feature: "f", Status: "running"}
	root := makeSession(t, []stream.Session{s})

	// Write a spec file so syncActive has something to load.
	specDir := filepath.Join(root, ".devloop", "specs")
	if err := os.MkdirAll(specDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	writeFile(t, filepath.Join(specDir, s.ID+".md"), "# Spec\n\nUNIQUE_SPEC_BODY")

	m := NewDashboardWithOptions(root, DashboardOptions{NoStream: true})
	loaded, err := stream.Scan(root)
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	m = driveModel(t, m, sessionsLoadedMsg{sessions: loaded})
	m = driveModel(t, m, tea.WindowSizeMsg{Width: 120, Height: 30})

	if m.specPanel.IsOpen() {
		t.Fatal("expected SPEC panel collapsed by default")
	}
	out := stripANSI(m.View())
	if strings.Contains(out, "UNIQUE_SPEC_BODY") {
		t.Errorf("collapsed SPEC panel should not render body, but found UNIQUE_SPEC_BODY in output")
	}
}

func TestDashboard_SpecPanel_OpensOnS(t *testing.T) {
	s := stream.Session{ID: "TASK-20260520-002", Feature: "f", Status: "running"}
	root := makeSession(t, []stream.Session{s})
	specDir := filepath.Join(root, ".devloop", "specs")
	if err := os.MkdirAll(specDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	writeFile(t, filepath.Join(specDir, s.ID+".md"), "# Spec\n\nUNIQUE_SPEC_BODY")

	m := NewDashboardWithOptions(root, DashboardOptions{NoStream: true})
	loaded, _ := stream.Scan(root)
	m = driveModel(t, m, sessionsLoadedMsg{sessions: loaded})
	m = driveModel(t, m, tea.WindowSizeMsg{Width: 120, Height: 30})

	// Press 's'
	m = driveModel(t, m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("s")})

	if !m.specPanel.IsOpen() {
		t.Fatal("expected SPEC panel to open after pressing 's'")
	}
	out := stripANSI(m.View())
	if !strings.Contains(out, "UNIQUE_SPEC_BODY") {
		t.Errorf("expected SPEC body 'UNIQUE_SPEC_BODY' in view after toggle, got %q", out)
	}
}

func TestDashboard_SpecPanel_MissingSpecShowsPlaceholder(t *testing.T) {
	s := stream.Session{ID: "TASK-20260520-003", Feature: "f", Status: "running"}
	root := makeSession(t, []stream.Session{s})

	m := NewDashboardWithOptions(root, DashboardOptions{NoStream: true})
	loaded, _ := stream.Scan(root)
	m = driveModel(t, m, sessionsLoadedMsg{sessions: loaded})
	m = driveModel(t, m, tea.WindowSizeMsg{Width: 120, Height: 30})
	m = driveModel(t, m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("s")})

	out := stripANSI(m.View())
	if !strings.Contains(out, "no spec yet") {
		t.Errorf("expected placeholder for missing spec, got %q", out)
	}
}

// ── Footer + filter (P1-6 / P1-11) ────────────────────────────────────────────

func TestDashboard_Footer_ListsNewKeybinds(t *testing.T) {
	root := t.TempDir()
	m := NewDashboardWithOptions(root, DashboardOptions{NoStream: true})
	m = driveModel(t, m, tea.WindowSizeMsg{Width: 120, Height: 30})

	out := stripANSI(m.View())
	for _, hint := range []string{"/ filter", "s spec", "d diff", "enter focus"} {
		if !strings.Contains(out, hint) {
			t.Errorf("expected footer hint %q in view, got %q", hint, out)
		}
	}
}

func TestDashboard_Filter_ActivatesOnSlash(t *testing.T) {
	s := stream.Session{ID: "TASK-20260520-F01", Feature: "add orders", Status: "running"}
	root := makeSession(t, []stream.Session{s})

	m := NewDashboardWithOptions(root, DashboardOptions{NoStream: true})
	loaded, _ := stream.Scan(root)
	m = driveModel(t, m, sessionsLoadedMsg{sessions: loaded})

	if m.picker.FilterFocused() {
		t.Fatal("expected filter not focused initially")
	}
	m = driveModel(t, m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("/")})
	if !m.picker.FilterFocused() {
		t.Fatal("expected filter focused after '/'")
	}
}

// ── DIFF panel (P1-9) ─────────────────────────────────────────────────────────

func TestDashboard_DiffPanel_StartsCollapsed(t *testing.T) {
	s := stream.Session{ID: "TASK-20260520-D01", Feature: "f", Status: "running"}
	root := makeSession(t, []stream.Session{s})

	m := NewDashboardWithOptions(root, DashboardOptions{NoStream: true})
	loaded, _ := stream.Scan(root)
	m = driveModel(t, m, sessionsLoadedMsg{sessions: loaded})

	if m.diffPanel.IsOpen() {
		t.Fatal("expected DIFF panel collapsed by default")
	}
}

func TestDashboard_DiffPanel_TogglesOnD(t *testing.T) {
	s := stream.Session{ID: "TASK-20260520-D02", Feature: "f", Status: "running"}
	root := makeSession(t, []stream.Session{s})

	m := NewDashboardWithOptions(root, DashboardOptions{NoStream: true})
	loaded, _ := stream.Scan(root)
	m = driveModel(t, m, sessionsLoadedMsg{sessions: loaded})
	m = driveModel(t, m, tea.WindowSizeMsg{Width: 120, Height: 30})

	// First 'd' opens
	m = driveModel(t, m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("d")})
	if !m.diffPanel.IsOpen() {
		t.Fatal("expected DIFF panel to open after first 'd'")
	}
	// Second 'd' closes
	m = driveModel(t, m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("d")})
	if m.diffPanel.IsOpen() {
		t.Fatal("expected DIFF panel to close after second 'd'")
	}
}

func TestColourisedDiff_PreservesContent(t *testing.T) {
	in := `diff --git a/x b/x
--- a/x
+++ b/x
@@ -1,2 +1,2 @@
-old line
+new line
 unchanged
`
	out := colourisedDiff(in)

	// File headers should always be present in plain form (no styling).
	if !strings.Contains(out, "--- a/x") {
		t.Errorf("expected --- header preserved, got %q", out)
	}
	if !strings.Contains(out, "+++ b/x") {
		t.Errorf("expected +++ header preserved, got %q", out)
	}
	// Every line of the input is preserved by stripANSI(out). Done
	// modulo trailing newlines because colourisedDiff appends one.
	plain := strings.TrimRight(stripANSI(out), "\n")
	wantPlain := strings.TrimRight(in, "\n")
	if plain != wantPlain {
		t.Errorf("colourise should be reversible via stripANSI:\n want %q\n  got %q",
			wantPlain, plain)
	}
}

func TestDashboard_TopBar_DaemonMaxRestarts(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, ".devloop"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	// PID 1 is alive but we don't own it — kill -0 may succeed or fail
	// depending on platform. Use our own PID + log a max-reached line.
	writeFile(t, filepath.Join(root, ".devloop", "daemon.pid"),
		fmt.Sprintf("%d\n", os.Getpid()))
	writeFile(t, filepath.Join(root, ".devloop", "daemon.log"),
		"[crash] Restarting in 5s...\n[crash] Restarting in 5s...\n[fatal] Max restarts (20) reached\n")

	m := NewDashboardWithOptions(root, DashboardOptions{NoStream: true})
	m = m.refreshHealth()

	out := stripANSI(m.renderHeader(120))
	if !strings.Contains(out, "max") || !strings.Contains(out, "⊘") {
		t.Errorf("expected '⊘ ×N max' chip, got %q", out)
	}
}

// stripANSI removes ANSI colour escape sequences so test assertions can match
// the rendered visible text directly.
func stripANSI(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	i := 0
	for i < len(s) {
		if s[i] == 0x1b && i+1 < len(s) && s[i+1] == '[' {
			// Skip past the CSI sequence up to a letter terminator.
			j := i + 2
			for j < len(s) && (s[j] < 0x40 || s[j] > 0x7e) {
				j++
			}
			if j < len(s) {
				j++
			}
			i = j
			continue
		}
		b.WriteByte(s[i])
		i++
	}
	return b.String()
}
