// Package app contains the root Bubble Tea model for devloop-tui.
//
// AppModel is a thin router: it owns the currently-active view and forwards
// every message to it. The view registry is a map[ViewID]tea.Model so that
// adding ViewRun, ViewChat (Phase 3) and future views requires no structural
// changes to this file — only new constants and construction logic.
package app

import (
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/shaifulshabuj/devloop/devloop-tui/internal/components"
	"github.com/shaifulshabuj/devloop/devloop-tui/internal/uimsg"
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
	// ViewFocus is the single-task full-screen mode (Phase 2). Reached
	// from the dashboard via uimsg.OpenFocus; returns via uimsg.CloseFocus.
	ViewFocus
	// Future: ViewInbox
)

// SwitchViewMsg requests a view change.  The router uses Options to construct
// the target view if it has not been built yet.  Fields that are non-empty
// override the corresponding field in Options before construction.
type SwitchViewMsg struct {
	Target    ViewID
	RunTaskID string // optional: overrides Options.RunTaskID for ViewRun
	ChatMode  string // optional: overrides Options.ChatMode for ViewChat

	// FocusSessionIdx / FocusSessionID let the dashboard hand off the
	// highlighted task when switching into ViewFocus. Both are optional
	// and consulted only when Target == ViewFocus.
	FocusSessionIdx int
	FocusSessionID  string
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

// AppModel is the root tea.Model.  It delegates Init/Update/View to the
// active child view, with two cross-cutting exceptions:
//
//   - Space toggles the global command palette (components.Palette)
//   - uimsg.OpenFocus / CloseFocus / PaletteRun are routed to view switches
//
// All other global key interception is intentionally absent: each view owns
// its own quit semantics.
type AppModel struct {
	current ViewID
	opts    Options // retained so lazy construction on switch has full context
	views   map[ViewID]tea.Model
	width   int
	height  int

	palette components.Palette
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
		palette: components.NewPalette(nil),
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

	// uimsg.OpenFocus / CloseFocus are routed to view transitions so the
	// dashboard and Focus Mode don't need to know about each other.
	if of, ok := msg.(uimsg.OpenFocus); ok {
		return m.handleSwitch(SwitchViewMsg{
			Target:          ViewFocus,
			FocusSessionIdx: of.SessionIdx,
			FocusSessionID:  of.SessionID,
		})
	}
	if _, ok := msg.(uimsg.CloseFocus); ok {
		return m.handleSwitch(SwitchViewMsg{Target: ViewDashboard})
	}

	// Palette dispatch: PaletteRun → switch to ViewChat and forward the
	// run-command message so chat's existing dispatchShell can stream output.
	if pr, ok := msg.(uimsg.PaletteRun); ok {
		next, cmd := m.handleSwitch(SwitchViewMsg{Target: ViewChat})
		updated, runCmd := next.activeView().Update(pr)
		next = next.setActiveView(updated)
		return next, tea.Batch(cmd, runCmd)
	}

	// Global SPACE toggle for the palette. Skip when a text input is
	// currently focused so SPACE typed inside a filter doesn't pop the
	// palette open mid-search.
	if km, ok := msg.(tea.KeyMsg); ok && km.String() == " " && !m.activeViewWantsKey() {
		if m.palette.IsOpen() {
			m.palette = m.palette.Close()
			return m, nil
		}
		var openCmd tea.Cmd
		m.palette, openCmd = m.palette.Open()
		return m, openCmd
	}

	// While the palette is open it owns all key input.
	if m.palette.IsOpen() {
		var pcmd tea.Cmd
		m.palette, pcmd = m.palette.Update(msg)
		return m, pcmd
	}

	updated, cmd := m.activeView().Update(msg)
	m = m.setActiveView(updated)
	return m, cmd
}

// activeViewWantsKey returns true when the active view has an input focused
// that should swallow keys (e.g., chat input, dashboard filter). The palette
// toggle defers to those — typing a space into a search field should not
// pop the palette.
func (m AppModel) activeViewWantsKey() bool {
	type filterer interface {
		FilterFocused() bool
	}
	if f, ok := m.activeView().(filterer); ok && f.FilterFocused() {
		return true
	}
	// ChatModel always has a focused textinput, so SPACE goes to it.
	if m.current == ViewChat {
		return true
	}
	return false
}

// View renders the active view, with the palette overlaid when open.
func (m AppModel) View() string {
	base := m.activeView().View()
	if !m.palette.IsOpen() {
		return base
	}
	// Overlay the palette by anchoring it ~25% from the top, centred.
	w := m.width
	h := m.height
	if w <= 0 {
		w = 100
	}
	if h <= 0 {
		h = 30
	}
	overlay := lipgloss.Place(w, h,
		lipgloss.Center,
		lipgloss.Top,
		m.palette.SetWidth(w).View(),
		lipgloss.WithWhitespaceChars(" "),
	)
	// Composite via lipgloss layer rendering: split base into lines and
	// overwrite a centred band with the palette. Fallback: just append.
	return overlayCompose(base, overlay)
}

// overlayCompose paints `overlay` over `base` line-by-line, preserving the
// underlying view's content outside the overlay's painted glyphs. lipgloss
// doesn't ship a z-buffer; this is a deliberately simple cell-wise composite
// good enough for the palette case (centred opaque box).
func overlayCompose(base, overlay string) string {
	baseLines := strings.Split(base, "\n")
	overLines := strings.Split(overlay, "\n")
	if len(overLines) > len(baseLines) {
		baseLines = append(baseLines, make([]string, len(overLines)-len(baseLines))...)
	}
	for i := 0; i < len(overLines); i++ {
		if strings.TrimSpace(overLines[i]) == "" {
			continue
		}
		baseLines[i] = overLines[i]
	}
	return strings.Join(baseLines, "\n")
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
		case ViewFocus:
			m.views[ViewFocus] = buildFocus(root, m.opts, msg.FocusSessionIdx, msg.FocusSessionID)
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

// buildFocus constructs the Focus Mode view rooted at the given session.
// idx/id come from the originating uimsg.OpenFocus message.
func buildFocus(root string, opts Options, idx int, id string) tea.Model {
	return views.NewFocusWithOptions(root, views.FocusOptions{
		StartIndex: idx,
		StartID:    id,
		NoStream:   opts.Test,
	})
}
