// Package tui implements the Bubble Tea TUI layer.
package tui

import (
	"context"
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/shaifulshabuj/devloop/v6/internal/agent"
	"github.com/shaifulshabuj/devloop/v6/internal/orchestrator"
	"github.com/shaifulshabuj/devloop/v6/internal/storage"
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
	focusPlanReview
)

// Model is the root Bubble Tea application model.
type Model struct {
	width        int
	height       int
	ready        bool
	focus        focusArea
	sidebar      Sidebar
	output       Output
	input        Input
	planView     *PlanView
	orch         *orchestrator.Orchestrator
	disp         *orchestrator.Dispatcher
	outputCh     <-chan string
	running      bool
	runningTitle string
}

// New creates a root Model for the given project name.
func New(projectName string, store *storage.Store, runner *agent.Runner) Model {
	return Model{
		sidebar: NewSidebar(projectName),
		output:  NewOutput(),
		input:   NewInput(),
		focus:   focusInput,
		orch:    orchestrator.New(store, runner),
		disp:    orchestrator.NewDispatcher(store, runner),
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
		if m.planView != nil {
			m.planView.SetSize(msg.Width, msg.Height-statusBarHeight-inputBarHeight)
		}
		// Focus input on first resize so the cursor blink is active.
		if m.focus != focusPlanReview {
			return m, m.input.Focus()
		}
		return m, nil

	case tea.KeyMsg:
		switch msg.Type {
		case tea.KeyCtrlC:
			return m, tea.Quit

		case tea.KeyTab:
			if m.focus != focusPlanReview {
				cmd := m.toggleFocus()
				return m, cmd
			}
		}

	case SubmitMsg:
		if m.running || m.focus == focusPlanReview {
			return m, nil
		}
		text := msg.Text
		m.output.AppendLine("Planning: " + text)
		orch := m.orch
		return m, func() tea.Msg {
			plan, err := orch.Plan(context.Background(), text)
			if err != nil {
				return taskResultMsg{err: err}
			}
			return PlanReviewMsg{Plan: plan}
		}

	case PlanReviewMsg:
		pv := NewPlanView(msg.Plan)
		pv.SetSize(m.width, m.height-statusBarHeight-inputBarHeight)
		m.planView = pv
		m.focus = focusPlanReview
		m.input.Blur()
		return m, nil

	case PlanApprovedMsg:
		m.planView = nil
		m.focus = focusInput
		m.running = true
		m.runningTitle = msg.Plan.Title
		m.sidebar.SetRunningTask(msg.Plan.Title)
		m.output.AppendLine("▶ Dispatching: " + msg.Plan.Title)

		ch := make(chan string, 256)
		m.outputCh = ch
		disp := m.disp
		plan := msg.Plan
		go func() {
			defer close(ch)
			for _, step := range plan.Steps {
				ch <- fmt.Sprintf("[%d/%d] %s", step.Number, len(plan.Steps), step.Description)
			}
			result, err := disp.Dispatch(context.Background(), plan)
			if err != nil {
				ch <- "Error: " + err.Error()
			}
			if result != nil {
				for _, sr := range result.Results {
					if sr.Output != "" {
						for _, line := range strings.Split(sr.Output, "\n") {
							if line != "" {
								ch <- line
							}
						}
					}
				}
			}
		}()
		return m, waitForLine(ch)

	case PlanRejectedMsg:
		m.planView = nil
		m.focus = focusInput
		m.output.AppendLine("Task cancelled.")
		return m, m.input.Focus()

	case OutputLineMsg:
		m.output.AppendLine(msg.Line)
		if m.outputCh != nil {
			return m, waitForLine(m.outputCh)
		}
		return m, nil

	case taskResultMsg:
		m.running = false
		m.runningTitle = ""
		m.outputCh = nil
		m.sidebar.SetRunningTask("")
		if msg.err != nil {
			m.output.AppendLine("Error: " + msg.err.Error())
		}
		return m, nil
	}

	// Delegate remaining messages to the focused component.
	if m.focus == focusPlanReview && m.planView != nil {
		var cmd tea.Cmd
		_, cmd = m.planView.Update(msg)
		return m, cmd
	}
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

	statusText := "  devloop v6"
	switch {
	case m.focus == focusPlanReview:
		statusText = "  Plan Review  [Enter approve  q cancel]"
	case m.running:
		statusText = "  ● " + m.runningTitle
	}
	statusBar := statusBarStyle.Width(m.width).Render(statusText)

	var middle string
	if m.focus == focusPlanReview && m.planView != nil {
		middle = m.planView.View()
	} else {
		middle = lipgloss.JoinHorizontal(
			lipgloss.Top,
			m.sidebar.View(),
			m.output.View(),
		)
	}

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

// waitForLine returns a Cmd that reads one line from ch.
// When ch is closed it returns taskResultMsg signalling completion.
func waitForLine(ch <-chan string) tea.Cmd {
	return func() tea.Msg {
		line, ok := <-ch
		if !ok {
			return taskResultMsg{}
		}
		return OutputLineMsg{Line: line}
	}
}

// Run starts the Bubble Tea program in alternate-screen mode.
func Run(projectName string, store *storage.Store, runner *agent.Runner) error {
	m := New(projectName, store, runner)
	p := tea.NewProgram(m, tea.WithAltScreen())
	_, err := p.Run()
	return err
}
