package app_test

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/shaifulshabuj/devloop/devloop-tui/internal/app"
)

// TestNewApp_DefaultsToDashboard verifies that NewApp returns an AppModel
// whose View() is non-empty and contains dashboard content.  An empty
// project root (no .devloop/) should still render the "no session selected"
// placeholder from the dashboard.
func TestNewApp_DefaultsToDashboard(t *testing.T) {
	root := t.TempDir() // empty dir — no .devloop/

	m := app.NewApp(app.Options{
		ProjectRoot: root,
		Start:       app.ViewDashboard,
		Test:        true,
	})

	view := m.View()
	if view == "" {
		t.Fatal("View() returned empty string")
	}
	// The dashboard renders this placeholder when the session list is empty.
	if !strings.Contains(view, "no session selected") {
		t.Errorf("expected 'no session selected' in View(); got:\n%s", view)
	}
}

// TestAppModel_ForwardsKeys confirms that forwarding a key message does not
// panic and returns an AppModel (not a nil or different type).
func TestAppModel_ForwardsKeys(t *testing.T) {
	root := t.TempDir()

	m := app.NewApp(app.Options{
		ProjectRoot: root,
		Test:        true,
	})

	got, _ := m.Update(tea.KeyMsg{Type: tea.KeyDown})
	if _, ok := got.(app.AppModel); !ok {
		t.Fatalf("Update returned %T, want app.AppModel", got)
	}
}

// TestAppModel_View_Width confirms that after receiving a WindowSizeMsg the
// model still renders a non-empty view.
func TestAppModel_View_Width(t *testing.T) {
	root := t.TempDir()

	m := app.NewApp(app.Options{
		ProjectRoot: root,
		Test:        true,
	})

	got, _ := m.Update(tea.WindowSizeMsg{Width: 80, Height: 24})
	view := got.(app.AppModel).View()
	if view == "" {
		t.Fatal("View() returned empty string after WindowSizeMsg")
	}
}

// TestApp_StartsAtViewDashboard verifies the zero-value Start defaults to
// ViewDashboard and that View() renders dashboard content.
func TestApp_StartsAtViewDashboard(t *testing.T) {
	root := t.TempDir()

	m := app.NewApp(app.Options{
		ProjectRoot: root,
		// Start omitted — zero value == ViewDashboard
		Test: true,
	})

	view := m.View()
	if view == "" {
		t.Fatal("View() returned empty string")
	}
	if !strings.Contains(view, "no session selected") {
		t.Errorf("expected dashboard placeholder in View(); got:\n%s", view)
	}
}

// TestApp_StartsAtViewRun verifies that Start: ViewRun renders run-view content.
// The run view header always contains the task ID when one is provided.
func TestApp_StartsAtViewRun(t *testing.T) {
	root := t.TempDir()

	m := app.NewApp(app.Options{
		ProjectRoot: root,
		Start:       app.ViewRun,
		RunTaskID:   "TASK-x",
		Test:        true,
	})

	view := m.View()
	if view == "" {
		t.Fatal("View() returned empty string for ViewRun")
	}
	if !strings.Contains(view, "TASK-x") {
		t.Errorf("expected 'TASK-x' in run view; got:\n%s", view)
	}
}

// TestApp_StartsAtViewChat verifies that Start: ViewChat renders chat-view content.
// The chat header contains "Chat" and "mode:".
func TestApp_StartsAtViewChat(t *testing.T) {
	root := t.TempDir()

	m := app.NewApp(app.Options{
		ProjectRoot: root,
		Start:       app.ViewChat,
		Test:        true,
	})

	view := m.View()
	if view == "" {
		t.Fatal("View() returned empty string for ViewChat")
	}
	if !strings.Contains(view, "Chat") {
		t.Errorf("expected 'Chat' in chat view; got:\n%s", view)
	}
	if !strings.Contains(view, "mode:") {
		t.Errorf("expected 'mode:' in chat view; got:\n%s", view)
	}
}

// TestApp_SwitchViewMsg_DashboardToChat starts at dashboard and sends a
// SwitchViewMsg to ViewChat; verifies View() now reflects the chat view.
func TestApp_SwitchViewMsg_DashboardToChat(t *testing.T) {
	root := t.TempDir()

	m := app.NewApp(app.Options{
		ProjectRoot: root,
		Start:       app.ViewDashboard,
		Test:        true,
	})

	// Confirm we start at dashboard.
	if !strings.Contains(m.View(), "no session selected") {
		t.Fatalf("expected dashboard initially; got:\n%s", m.View())
	}

	// Switch to chat.
	got, _ := m.Update(app.SwitchViewMsg{Target: app.ViewChat})
	appM, ok := got.(app.AppModel)
	if !ok {
		t.Fatalf("Update returned %T, want app.AppModel", got)
	}

	view := appM.View()
	if !strings.Contains(view, "Chat") {
		t.Errorf("expected 'Chat' after switch; got:\n%s", view)
	}
	if !strings.Contains(view, "mode:") {
		t.Errorf("expected 'mode:' after switch; got:\n%s", view)
	}
}

// TestApp_SwitchViewMsg_DashboardToRunWithOverride starts at dashboard and
// sends a SwitchViewMsg with a RunTaskID override; verifies the run view
// shows the overridden task ID.
func TestApp_SwitchViewMsg_DashboardToRunWithOverride(t *testing.T) {
	root := t.TempDir()

	m := app.NewApp(app.Options{
		ProjectRoot: root,
		Start:       app.ViewDashboard,
		RunTaskID:   "TASK-old", // will be overridden
		Test:        true,
	})

	got, _ := m.Update(app.SwitchViewMsg{
		Target:    app.ViewRun,
		RunTaskID: "TASK-new",
	})
	appM, ok := got.(app.AppModel)
	if !ok {
		t.Fatalf("Update returned %T, want app.AppModel", got)
	}

	view := appM.View()
	if !strings.Contains(view, "TASK-new") {
		t.Errorf("expected 'TASK-new' in run view after switch; got:\n%s", view)
	}
}
