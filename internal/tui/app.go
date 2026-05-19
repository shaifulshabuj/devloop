// Package tui implements the Bubble Tea TUI layer.
package tui

import (
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

const (
	statusBarHeight = 1
	// inputBarHeight accounts for the top border line (1) + the input line (1).
	inputBarHeight  = 2
	sidebarFraction = 0.25
)

var statusBarStyle = lipgloss.NewStyle().
	Background(lipgloss.Color("#1a1a2e")).
	Foreground(lipgloss.Color("#ffffff")).
	Bold(true)

type focusArea int

const (
	focusInput focusArea = iota
	focusViewport
)

// Model is the root Bubble Tea application model.
type Model struct {
	width   int
	height  int
	ready   bool
	focus   focusArea
	sidebar Sidebar
	output  Output
	input   Input
}

// New creates a root Model for the given project name.
func New(projectName string) Model {
	return Model{
		sidebar: NewSidebar(projectName),
		output:  NewOutput(),
		input:   NewInput(),
		focus:   focusInput,
	}
}

// Init implements tea.Model. Focuses the input and starts the cursor blink.
func (m Model) Init() tea.Cmd {
	return m.input.Init()
}

// Update implements tea.Model.
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.setSize(msg.Width, msg.Height)
		m.ready = true
		// Focus input on first resize so the cursor blink is active.
		return m, m.input.Focus()

	case tea.KeyMsg:
		switch msg.Type {
		case tea.KeyCtrlC:
			return m, tea.Quit

		case tea.KeyTab:
			cmd := m.toggleFocus()
			return m, cmd
		}
	}

	// Delegate remaining messages to the focused component.
	if m.focus == focusInput {
		var cmd tea.Cmd
		m.input, cmd = m.input.Update(msg)
		return m, cmd
	}

	// Viewport is focused — ↑/↓ scroll is handled inside viewport.Update.
	var cmd tea.Cmd
	m.output, cmd = m.output.Update(msg)
	return m, cmd
}

// View implements tea.Model.
func (m Model) View() string {
	if !m.ready {
		return "Initializing…"
	}

	statusBar := statusBarStyle.Width(m.width).Render("  devloop v6.0.0-dev")

	middle := lipgloss.JoinHorizontal(
		lipgloss.Top,
		m.sidebar.View(),
		m.output.View(),
	)

	return lipgloss.JoinVertical(lipgloss.Left,
		statusBar,
		middle,
		m.input.View(),
	)
}

// setSize recomputes layout after a terminal resize.
func (m *Model) setSize(w, h int) {
	m.width = w
	m.height = h

	sidebarW := int(float64(w) * sidebarFraction)
	outputW := w - sidebarW
	contentH := h - statusBarHeight - inputBarHeight
	if contentH < 0 {
		contentH = 0
	}

	m.sidebar.SetSize(sidebarW, contentH)
	m.output.SetSize(outputW, contentH)
	m.input.SetWidth(w)
}

// toggleFocus switches keyboard focus between input and viewport.
func (m *Model) toggleFocus() tea.Cmd {
	if m.focus == focusInput {
		m.focus = focusViewport
		m.input.Blur()
		return nil
	}
	m.focus = focusInput
	return m.input.Focus()
}

// Run starts the Bubble Tea program in alternate-screen mode.
//
// projectName is shown in the sidebar for Phase 1.
func Run(projectName string) error {
	m := New(projectName)
	p := tea.NewProgram(m, tea.WithAltScreen())
	_, err := p.Run()
	return err
}
