// Package app contains the root Bubble Tea model for devloop-tui.
//
// AppModel is a thin router: it owns the currently-active view and forwards
// every message to it. The view registry is a map[ViewID]tea.Model so that
// adding ViewRun, ViewChat (Phase 3) and future views requires no structural
// changes to this file — only new constants and construction logic.
package app

import (
	tea "github.com/charmbracelet/bubbletea"

	"github.com/shaifulshabuj/devloop/devloop-tui/internal/views"
)

// ViewID identifies which top-level view is active.
type ViewID int

const (
	// ViewDashboard is the default split-layout session overview.
	ViewDashboard ViewID = iota
	// ViewRun focuses on a single devloop task / pipeline run.
	ViewRun
	// ViewChat is the slash-command REPL interface.
	ViewChat
	// Future: ViewInbox
)

// SwitchViewMsg requests a view change.  The router uses Options to construct
// the target view if it has not been built yet.  Fields that are non-empty
// override the corresponding field in Options before construction.
type SwitchViewMsg struct {
	Target    ViewID
	RunTaskID string // optional: overrides Options.RunTaskID for ViewRun
	ChatMode  string // optional: overrides Options.ChatMode for ViewChat
}

// Options configures AppModel construction.
type Options struct {
	// ProjectRoot is the resolved absolute path to the devloop project.
	// When empty, NewApp falls back to the process working directory.
	ProjectRoot string

	// Start selects the initial view.  Defaults to ViewDashboard.
	Start ViewID

	// Test disables live subsystems (fsnotify tailer, subprocess exec) so the
	// model is safe to drive entirely via Update() calls in unit tests.
	Test bool

	// RunTaskID is required when Start == ViewRun (or when switching to ViewRun
	// via SwitchViewMsg without an override).
	RunTaskID string

	// ChatMode is "ask" | "code" | "auto".  Defaults to "auto" when empty.
	ChatMode string
}

// AppModel is the root tea.Model.  It delegates Init/Update/View entirely to
// the active child view.  Global key interception is intentionally absent:
// each view owns its own quit semantics.
type AppModel struct {
	current ViewID
	opts    Options // retained so lazy construction on switch has full context
	views   map[ViewID]tea.Model
	width   int
	height  int
}

// NewApp builds the root model.  All three views are constructed eagerly so
// that Init() can return the initial view's command without extra indirection.
// Views constructed in Test mode receive NoStream / NoSubprocess options so
// that no goroutines or subprocesses are spawned.
func NewApp(opts Options) AppModel {
	root := opts.ProjectRoot
	if root == "" {
		root = "."
	}

	m := AppModel{
		current: opts.Start,
		opts:    opts,
		views:   make(map[ViewID]tea.Model),
	}

	// Always build the dashboard eagerly (it is the default fallback).
	m.views[ViewDashboard] = buildDashboard(root, opts)

	// Build the requested start view eagerly so Init() is meaningful.
	switch opts.Start {
	case ViewRun:
		m.views[ViewRun] = buildRun(root, opts)
	case ViewChat:
		m.views[ViewChat] = buildChat(root, opts)
	}

	return m
}

// ─── tea.Model interface ──────────────────────────────────────────────────────

// Init returns the active view's Init command.
func (m AppModel) Init() tea.Cmd {
	return m.activeView().Init()
}

// Update forwards every message to the active view.  WindowSizeMsg is also
// stored on AppModel so that lazily-constructed views can receive correct
// dimensions immediately.  SwitchViewMsg is handled by the router itself.
func (m AppModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	if wsm, ok := msg.(tea.WindowSizeMsg); ok {
		m.width = wsm.Width
		m.height = wsm.Height
	}

	if swm, ok := msg.(SwitchViewMsg); ok {
		return m.handleSwitch(swm)
	}

	updated, cmd := m.activeView().Update(msg)
	m = m.setActiveView(updated)
	return m, cmd
}

// View renders the active view.
func (m AppModel) View() string {
	return m.activeView().View()
}

// ─── View registry helpers ────────────────────────────────────────────────────

// activeView returns the tea.Model for the currently selected view.  Falls
// back to the dashboard if the current view has not been built yet.
func (m AppModel) activeView() tea.Model {
	if v, ok := m.views[m.current]; ok {
		return v
	}
	// Fallback: always present.
	return m.views[ViewDashboard]
}

// setActiveView stores an updated tea.Model back into the correct slot.
func (m AppModel) setActiveView(v tea.Model) AppModel {
	m.views[m.current] = v
	return m
}

// handleSwitch processes a SwitchViewMsg: applies any overrides, lazily
// constructs the target view if needed, switches current, and re-inits.
func (m AppModel) handleSwitch(msg SwitchViewMsg) (AppModel, tea.Cmd) {
	// Apply per-message overrides to opts so lazy construction uses them.
	if msg.RunTaskID != "" {
		m.opts.RunTaskID = msg.RunTaskID
	}
	if msg.ChatMode != "" {
		m.opts.ChatMode = msg.ChatMode
	}

	// Lazily build the target view if it has not been constructed yet.
	if _, exists := m.views[msg.Target]; !exists {
		root := m.opts.ProjectRoot
		if root == "" {
			root = "."
		}
		switch msg.Target {
		case ViewDashboard:
			m.views[ViewDashboard] = buildDashboard(root, m.opts)
		case ViewRun:
			m.views[ViewRun] = buildRun(root, m.opts)
		case ViewChat:
			m.views[ViewChat] = buildChat(root, m.opts)
		}
	}

	m.current = msg.Target

	// Forward pending window size to the new view immediately.
	if m.width > 0 || m.height > 0 {
		updated, _ := m.activeView().Update(tea.WindowSizeMsg{
			Width:  m.width,
			Height: m.height,
		})
		m = m.setActiveView(updated)
	}

	return m, m.activeView().Init()
}

// ─── View constructors ────────────────────────────────────────────────────────

func buildDashboard(root string, opts Options) tea.Model {
	if opts.Test {
		return views.NewDashboardWithOptions(root, views.DashboardOptions{NoStream: true})
	}
	return views.NewDashboard(root)
}

func buildRun(root string, opts Options) tea.Model {
	if opts.Test {
		return views.NewRunWithOptions(root, views.RunOptions{
			TaskID:   opts.RunTaskID,
			NoStream: true,
		})
	}
	return views.NewRun(root, opts.RunTaskID)
}

func buildChat(root string, opts Options) tea.Model {
	if opts.Test {
		return views.NewChatWithOptions(root, views.ChatOptions{
			NoSubprocess: true,
			StartMode:    opts.ChatMode,
		})
	}
	return views.NewChatWithOptions(root, views.ChatOptions{
		StartMode: opts.ChatMode,
	})
}
