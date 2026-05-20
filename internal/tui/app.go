// Package tui implements the Bubble Tea TUI layer.
package tui

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/shaifulshabuj/devloop/v6/internal/agent"
	"github.com/shaifulshabuj/devloop/v6/internal/config"
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
	focusSidebar
	focusPlanReview
	focusSkills
	focusPersonas
	focusCost
)

// Model is the root Bubble Tea application model.
type Model struct {
	width        int
	height       int
	ready        bool
	focus        focusArea
	prevFocus    focusArea
	sidebar      Sidebar
	output       Output
	input        Input
	planView     *PlanView
	skillView    *SkillView
	showSkills   bool
	personaView  *PersonaView
	showPersonas bool
	costView     *CostView
	showCost     bool
	splitActive  bool
	splitPanes   []string // per-step descriptions / outputs
	splitFocIdx  int      // focused pane index for left/right nav
	orch         *orchestrator.Orchestrator
	disp         *orchestrator.Dispatcher
	store        *storage.Store
	runner       *agent.Runner
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
		store:   store,
		runner:  runner,
	}
}

// Init implements tea.Model. Loads async data and focuses the input.
func (m Model) Init() tea.Cmd {
	return tea.Batch(
		m.input.Init(),
		loadSkills(),
		loadProjects(),
		loadPersonas(),
		loadCost(m.store),
	)
}

// loadSkills reads skill files asynchronously and emits SkillsLoadedMsg.
// Paths are resolved eagerly before the closure so they are always absolute,
// regardless of any working-directory change that might happen later.
func loadSkills() tea.Cmd {
	projectDir, _ := os.Getwd()
	home, _ := os.UserHomeDir()
	dirs := []string{
		filepath.Join(home, ".devloop", "skills"),
		filepath.Join(projectDir, ".devloop", "skills"),
	}
	return func() tea.Msg {
		var all []agent.Skill
		for _, dir := range dirs {
			loader := agent.NewSkillLoader(dir)
			skills, _ := loader.Load()
			all = append(all, skills...)
		}
		return SkillsLoadedMsg{Skills: all}
	}
}

// loadProjects reads the project registry and emits ProjectsLoadedMsg.
func loadProjects() tea.Cmd {
	return func() tea.Msg {
		home, err := os.UserHomeDir()
		if err != nil {
			return ProjectsLoadedMsg{}
		}
		reg, err := config.LoadRegistry(filepath.Join(home, ".devloop", "projects.toml"))
		if err != nil {
			return ProjectsLoadedMsg{}
		}
		return ProjectsLoadedMsg{Projects: reg.List()}
	}
}

// loadPersonas returns the built-in persona list as PersonasLoadedMsg.
func loadPersonas() tea.Cmd {
	return func() tea.Msg {
		reg := agent.NewPersonaRegistry()
		return PersonasLoadedMsg{Personas: reg.List()}
	}
}

// loadCost computes cost estimates from recent tasks.
func loadCost(store *storage.Store) tea.Cmd {
	if store == nil {
		return func() tea.Msg { return CostSummaryMsg{} }
	}
	return func() tea.Msg {
		costs, _ := storage.ComputeAllCosts(store, "", 20)
		return CostSummaryMsg{Costs: costs}
	}
}

// Update implements tea.Model.
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.setSize(msg.Width, msg.Height)
		m.ready = true
		contentH := msg.Height - statusBarHeight - inputBarHeight
		if m.planView != nil {
			m.planView.SetSize(msg.Width, contentH)
		}
		if m.skillView != nil {
			m.skillView.SetSize(msg.Width, contentH)
		}
		if m.personaView != nil {
			m.personaView.SetSize(msg.Width, contentH)
		}
		if m.costView != nil {
			m.costView.SetSize(msg.Width, contentH)
		}
		// Focus input on first resize unless an overlay is active.
		if m.focus == focusInput || m.focus == focusViewport || m.focus == focusSidebar {
			return m, m.input.Focus()
		}
		return m, nil

	case tea.KeyMsg:
		switch msg.Type {
		case tea.KeyCtrlC:
			return m, tea.Quit

		case tea.KeyEsc:
			switch m.focus {
			case focusSkills:
				return m, m.toggleOverlay(focusSkills)
			case focusPersonas:
				return m, m.toggleOverlay(focusPersonas)
			case focusCost:
				return m, m.toggleOverlay(focusCost)
			}

		case tea.KeyTab:
			if m.focus != focusPlanReview &&
				m.focus != focusSkills &&
				m.focus != focusPersonas &&
				m.focus != focusCost {
				return m, m.cycleFocus()
			}
		case tea.KeyUp, tea.KeyDown:
			if m.focus == focusSidebar {
				if msg.Type == tea.KeyUp {
					m.sidebar.MoveCursor(-1)
				} else {
					m.sidebar.MoveCursor(1)
				}
				return m, nil
			}
		case tea.KeyEnter:
			if m.focus == focusSidebar {
				if path := m.sidebar.SelectedPath(); path != "" {
					return m, func() tea.Msg { return ProjectSwitchMsg{Path: path} }
				}
				return m, nil
			}
		case tea.KeyLeft:
			if m.splitActive && m.splitFocIdx > 0 {
				m.splitFocIdx--
				return m, nil
			}
		case tea.KeyRight:
			if m.splitActive && m.splitFocIdx < len(m.splitPanes)-1 {
				m.splitFocIdx++
				return m, nil
			}
		}

		switch msg.String() {
		case "s":
			if m.focus != focusPlanReview {
				return m, m.toggleOverlay(focusSkills)
			}
		case "p":
			if m.focus != focusPlanReview {
				return m, m.toggleOverlay(focusPersonas)
			}
		case "$":
			if m.focus != focusPlanReview {
				return m, m.toggleOverlay(focusCost)
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
		plan := msg.Plan

		if len(plan.Steps) > 1 && m.runner != nil {
			// Parallel dispatch — show split pane view.
			m.splitActive = true
			m.splitFocIdx = 0
			m.splitPanes = make([]string, len(plan.Steps))
			for i, step := range plan.Steps {
				m.splitPanes[i] = step.Description
			}
			parDisp := orchestrator.NewParallelDispatcher(m.store, m.runner, 0)
			go func() {
				defer close(ch)
				result, err := parDisp.Dispatch(context.Background(), plan)
				if err != nil {
					ch <- "Error: " + err.Error()
				}
				if result != nil {
					for i, sr := range result.Results {
						// Update pane content with actual output.
						line := fmt.Sprintf("[step %d] %s", i+1, sr.Output)
						if sr.Error != nil {
							line = fmt.Sprintf("[step %d error] %s", i+1, sr.Error)
						}
						ch <- line
					}
				}
			}()
		} else {
			// Sequential dispatch.
			disp := m.disp
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
		}
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
		m.splitActive = false
		m.splitPanes = nil
		m.sidebar.SetRunningTask("")
		if msg.err != nil {
			m.output.AppendLine("Error: " + msg.err.Error())
		}
		// Refresh cost data after task completes.
		return m, loadCost(m.store)

	case SkillsLoadedMsg:
		sv := NewSkillView(msg.Skills)
		sv.SetSize(m.width, m.height-statusBarHeight-inputBarHeight)
		m.skillView = sv
		return m, nil

	case ProjectsLoadedMsg:
		cwd, _ := os.Getwd()
		m.sidebar.SetProjects(msg.Projects, cwd)
		return m, nil

	case ProjectSwitchMsg:
		m.sidebar.activePath = msg.Path
		m.output.AppendLine("Switched to: " + msg.Path)
		return m, nil

	case PersonasLoadedMsg:
		pv := NewPersonaView(msg.Personas)
		pv.SetSize(m.width, m.height-statusBarHeight-inputBarHeight)
		m.personaView = pv
		return m, nil

	case CostSummaryMsg:
		cv := NewCostView(msg.Costs)
		cv.SetSize(m.width, m.height-statusBarHeight-inputBarHeight)
		m.costView = cv
		return m, nil

	case SplitViewMsg:
		m.splitActive = true
		m.splitFocIdx = 0
		m.splitPanes = make([]string, len(msg.Steps))
		for i, s := range msg.Steps {
			m.splitPanes[i] = s.Description
		}
		return m, nil

	case PaneOutputMsg:
		if msg.PaneIndex >= 0 && msg.PaneIndex < len(m.splitPanes) {
			m.splitPanes[msg.PaneIndex] += "\n" + msg.Line
		}
		return m, nil
	}

	// Delegate remaining messages to the focused component.
	switch m.focus {
	case focusPlanReview:
		if m.planView != nil {
			var cmd tea.Cmd
			_, cmd = m.planView.Update(msg)
			return m, cmd
		}
	case focusSkills:
		if m.skillView != nil {
			var cmd tea.Cmd
			_, cmd = m.skillView.Update(msg)
			return m, cmd
		}
	case focusPersonas:
		if m.personaView != nil {
			var cmd tea.Cmd
			_, cmd = m.personaView.Update(msg)
			return m, cmd
		}
	case focusCost:
		if m.costView != nil {
			var cmd tea.Cmd
			_, cmd = m.costView.Update(msg)
			return m, cmd
		}
	case focusInput:
		var cmd tea.Cmd
		m.input, cmd = m.input.Update(msg)
		return m, cmd
	default:
		// Viewport or sidebar — viewport handles ↑/↓ scroll.
		var cmd tea.Cmd
		m.output, cmd = m.output.Update(msg)
		return m, cmd
	}

	return m, nil
}

// View implements tea.Model.
func (m Model) View() string {
	if !m.ready {
		return "Initializing…"
	}

	statusText := "  devloop v6  [s skills  p personas  $ cost  Tab focus]"
	switch {
	case m.focus == focusPlanReview:
		statusText = "  Plan Review  [Enter approve  q cancel]"
	case m.focus == focusSkills:
		statusText = "  Skills  [↑/↓ navigate  s/Esc close]"
	case m.focus == focusPersonas:
		statusText = "  Personas  [↑/↓ navigate  p/Esc close]"
	case m.focus == focusCost:
		statusText = "  Cost  [↑/↓ navigate  $/Esc close]"
	case m.focus == focusSidebar:
		statusText = "  Projects  [↑/↓ navigate  Enter switch  Tab next]"
	case m.running:
		statusText = "  ● " + m.runningTitle
	}
	statusBar := statusBarStyle.Width(m.width).Render(statusText)

	var middle string
	switch {
	case m.focus == focusPlanReview && m.planView != nil:
		middle = m.planView.View()
	case m.showSkills && m.skillView != nil:
		middle = m.skillView.View()
	case m.showPersonas && m.personaView != nil:
		middle = m.personaView.View()
	case m.showCost && m.costView != nil:
		middle = m.costView.View()
	case m.splitActive && len(m.splitPanes) > 0:
		middle = m.renderSplitPanes()
	default:
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

// renderSplitPanes renders parallel step panes side by side.
func (m Model) renderSplitPanes() string {
	n := len(m.splitPanes)
	if n == 0 {
		return m.output.View()
	}
	contentH := m.height - statusBarHeight - inputBarHeight
	paneW := m.width / n

	panes := make([]string, n)
	for i, content := range m.splitPanes {
		header := fmt.Sprintf("▸ Step %d", i+1)
		body := "Running…\n\n" + content
		style := lipgloss.NewStyle().Width(paneW).Height(contentH)
		if i == m.splitFocIdx {
			style = style.BorderStyle(lipgloss.NormalBorder()).
				BorderForeground(lipgloss.Color("#7c7cff"))
		}
		panes[i] = style.Render(header + "\n" + body)
	}
	return lipgloss.JoinHorizontal(lipgloss.Top, panes...)
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
	if m.skillView != nil {
		m.skillView.SetSize(w, contentH)
	}
	if m.personaView != nil {
		m.personaView.SetSize(w, contentH)
	}
	if m.costView != nil {
		m.costView.SetSize(w, contentH)
	}
}

// cycleFocus rotates keyboard focus: input → sidebar → viewport → input.
func (m *Model) cycleFocus() tea.Cmd {
	switch m.focus {
	case focusInput:
		m.focus = focusSidebar
		m.input.Blur()
		return nil
	case focusSidebar:
		m.focus = focusViewport
		return nil
	default: // focusViewport
		m.focus = focusInput
		return m.input.Focus()
	}
}

// toggleOverlay opens or closes an overlay panel (skills, personas, cost).
// Only one overlay is active at a time.
func (m *Model) toggleOverlay(which focusArea) tea.Cmd {
	// If this overlay is already active, close it.
	if m.focus == which {
		m.showSkills = false
		m.showPersonas = false
		m.showCost = false
		m.focus = m.prevFocus
		if m.focus == focusInput {
			return m.input.Focus()
		}
		return nil
	}

	// Close any currently open overlay.
	m.showSkills = false
	m.showPersonas = false
	m.showCost = false

	// Save focus and open the requested overlay.
	if m.focus != focusSkills && m.focus != focusPersonas && m.focus != focusCost {
		m.prevFocus = m.focus
	}
	m.input.Blur()

	switch which {
	case focusSkills:
		m.showSkills = true
		if m.skillView != nil {
			m.skillView.SetSize(m.width, m.height-statusBarHeight-inputBarHeight)
		}
	case focusPersonas:
		m.showPersonas = true
		if m.personaView != nil {
			m.personaView.SetSize(m.width, m.height-statusBarHeight-inputBarHeight)
		}
	case focusCost:
		m.showCost = true
		if m.costView != nil {
			m.costView.SetSize(m.width, m.height-statusBarHeight-inputBarHeight)
		}
	}
	m.focus = which
	return nil
}

// waitForLine returns a Cmd that reads one line from ch.
// When ch is closed it returns taskResultMsg signalling completion.
// A nil ch is a no-op (returns nil Cmd) as a safety guard.
func waitForLine(ch <-chan string) tea.Cmd {
	if ch == nil {
		return nil
	}
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
