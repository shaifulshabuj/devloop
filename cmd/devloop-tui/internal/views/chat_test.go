package views

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// ─── test helpers ─────────────────────────────────────────────────────────────

// driveChatModel sends msgs to the ChatModel and returns the final model.
// It also drains all tea.Cmd results by running them and feeding back messages,
// up to maxDepth rounds of command expansion (to handle async cmd chains).
func driveChatModel(t *testing.T, m ChatModel, msgs ...tea.Msg) ChatModel {
	t.Helper()
	var model tea.Model = m
	for _, msg := range msgs {
		var cmds []tea.Cmd
		var cmd tea.Cmd
		model, cmd = model.Update(msg)
		if cmd != nil {
			cmds = append(cmds, cmd)
		}
		// Run any returned commands up to 20 hops deep.
		for depth := 0; depth < 20 && len(cmds) > 0; depth++ {
			var next []tea.Cmd
			for _, c := range cmds {
				if c == nil {
					continue
				}
				result := c()
				if result == nil {
					continue
				}
				// If it's a tea.QuitMsg or batchMsg, stop early.
				var cmd2 tea.Cmd
				model, cmd2 = model.Update(result)
				if cmd2 != nil {
					next = append(next, cmd2)
				}
			}
			cmds = next
		}
	}
	return model.(ChatModel)
}

// enterText sends individual rune messages followed by an Enter key.
func enterText(t *testing.T, m ChatModel, text string) ChatModel {
	t.Helper()
	for _, r := range text {
		m = driveChatModel(t, m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
	}
	m = driveChatModel(t, m, tea.KeyMsg{Type: tea.KeyEnter})
	return m
}

// scrollbackTexts returns the Text fields of all scrollback lines.
func scrollbackTexts(m ChatModel) []string {
	out := make([]string, len(m.scrollback))
	for i, cl := range m.scrollback {
		out[i] = cl.Text
	}
	return out
}

// containsAny returns true when any element of ss contains sub.
func containsAny(ss []string, sub string) bool {
	for _, s := range ss {
		if strings.Contains(s, sub) {
			return true
		}
	}
	return false
}

// makeFakeProject creates a minimal project directory for tests.
func makeFakeProject(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	_ = os.MkdirAll(filepath.Join(root, ".devloop", "sessions"), 0o755)
	_ = os.MkdirAll(filepath.Join(root, ".devloop", "specs"), 0o755)
	// Create a fake session so /mode has somewhere to write.
	sessionID := "TASK-20260516-100000"
	sessionDir := filepath.Join(root, ".devloop", "sessions", sessionID)
	_ = os.MkdirAll(sessionDir, 0o755)
	_ = os.WriteFile(filepath.Join(sessionDir, "feature.txt"), []byte("test feature"), 0o644)
	_ = os.WriteFile(filepath.Join(sessionDir, "status"), []byte("running"), 0o644)
	return root
}

// ─── Tests ────────────────────────────────────────────────────────────────────

// TestChat_ParsesSlashCommand — /help should produce both an input echo and
// the help text lines in the scrollback.
func TestChat_ParsesSlashCommand(t *testing.T) {
	root := makeFakeProject(t)
	m := NewChatWithOptions(root, ChatOptions{NoSubprocess: true, StartMode: "auto"})

	m = enterText(t, m, "/help")

	texts := scrollbackTexts(m)
	if !containsAny(texts, "> /help") {
		t.Errorf("expected echo '>  /help' in scrollback; got: %v", texts)
	}
	if !containsAny(texts, "Available commands") {
		t.Errorf("expected 'Available commands' in scrollback; got: %v", texts)
	}
}

// TestChat_NaturalLanguageRoutesToRun — typing without a slash prefix should
// be treated as /run <text>.
func TestChat_NaturalLanguageRoutesToRun(t *testing.T) {
	root := makeFakeProject(t)

	var dispatched struct{ command, arg string }
	m := NewChatWithOptions(root, ChatOptions{NoSubprocess: true, StartMode: "auto"})
	m.testHook = func(command, arg string) {
		dispatched.command = command
		dispatched.arg = arg
	}

	m = enterText(t, m, "add dark mode")

	if dispatched.command != "run" {
		t.Errorf("expected command 'run', got %q", dispatched.command)
	}
	if dispatched.arg != "add dark mode" {
		t.Errorf("expected arg 'add dark mode', got %q", dispatched.arg)
	}
	// The scrollback should also contain the echoed fake output.
	texts := scrollbackTexts(m)
	if !containsAny(texts, "add dark mode") {
		t.Errorf("expected feature text in scrollback; got: %v", texts)
	}
}

// TestChat_ModeSwitching — /mode code should update the header mode field and
// write a mode file under the session directory.
func TestChat_ModeSwitching(t *testing.T) {
	root := makeFakeProject(t)
	m := NewChatWithOptions(root, ChatOptions{NoSubprocess: true, StartMode: "auto"})

	if m.mode != "auto" {
		t.Fatalf("expected initial mode 'auto', got %q", m.mode)
	}

	m = enterText(t, m, "/mode code")

	if m.mode != "code" {
		t.Errorf("expected mode 'code', got %q", m.mode)
	}

	// Check mode file written for the fake session.
	sessionID := "TASK-20260516-100000"
	modeFile := filepath.Join(root, ".devloop", "sessions", sessionID, "mode")
	content, err := os.ReadFile(modeFile)
	if err != nil {
		t.Fatalf("mode file not created: %v", err)
	}
	if strings.TrimSpace(string(content)) != "code" {
		t.Errorf("mode file content: got %q, want 'code'", string(content))
	}

	// Header should reflect the mode.
	view := m.View()
	if !strings.Contains(view, "mode: code") {
		t.Errorf("header should show 'mode: code'; view:\n%s", view)
	}
}

// TestChat_UnknownCommand — an unknown slash command should add an error line
// to the scrollback and not panic.
func TestChat_UnknownCommand(t *testing.T) {
	root := makeFakeProject(t)
	m := NewChatWithOptions(root, ChatOptions{NoSubprocess: true})

	m = enterText(t, m, "/wat")

	texts := scrollbackTexts(m)
	if !containsAny(texts, "unknown command") {
		t.Errorf("expected 'unknown command' error in scrollback; got: %v", texts)
	}
	// Exactly one error line.
	var errLines int
	for _, cl := range m.scrollback {
		if cl.Kind == lineError {
			errLines++
		}
	}
	if errLines != 1 {
		t.Errorf("expected 1 error line, got %d", errLines)
	}
}

// TestChat_Quit — /quit should return tea.Quit.
func TestChat_Quit(t *testing.T) {
	root := makeFakeProject(t)
	m := NewChatWithOptions(root, ChatOptions{NoSubprocess: true})

	// Manually type /quit and press Enter, capturing the Cmd returned.
	var model tea.Model = m
	for _, r := range "/quit" {
		model, _ = model.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
	}
	_, cmd := model.Update(tea.KeyMsg{Type: tea.KeyEnter})

	if cmd == nil {
		t.Fatal("expected a tea.Cmd from /quit, got nil")
	}

	// Execute the command and check it's tea.Quit.
	msg := cmd()
	if _, ok := msg.(tea.QuitMsg); !ok {
		t.Errorf("expected tea.QuitMsg from /quit, got %T: %v", msg, msg)
	}
}
