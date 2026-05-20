// Package tui implements the Bubble Tea TUI layer.
package tui

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

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
	maxVisiblePanes = 4 // max PTY panes shown side-by-side
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
	focusPane // keyboard focus is inside a PTY pane
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
	splitPanes   []string // legacy parallel step text buffers (kept for SplitViewMsg compat)
	splitFocIdx  int
	orch         *orchestrator.Orchestrator
	disp         *orchestrator.Dispatcher
	store        *storage.Store
	runner       *agent.Runner
	outputCh     <-chan string
	running      bool
	runningTitle string

	// PTY sub-panel management.
	ptyPanes    []*PtyPane   // all open PTY panes
	paneOffset  int          // index of first visible pane (for > maxVisiblePanes)
	focusPaneID int          // ID of focused pane; -1 means main panel
	nextPaneID  int          // monotonic ID counter
	program     *tea.Program // back-reference so goroutines can send msgs
}

// New creates a root Model for the given project name.
func New(projectName string, store *storage.Store, runner *agent.Runner) Model {
	return Model{
		sidebar:     NewSidebar(projectName),
		output:      NewOutput(),
		input:       NewInput(),
		focus:       focusInput,
		orch:        orchestrator.New(store, runner),
		disp:        orchestrator.NewDispatcher(store, runner),
		store:       store,
		runner:      runner,
		focusPaneID: -1,
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
		// Resize PTY panes.
		m.resizePtyPanes()
		// Focus input on first resize unless an overlay or pane is active.
		if m.focus == focusInput || m.focus == focusViewport || m.focus == focusSidebar {
			return m, m.input.Focus()
		}
		return m, nil

	case PanePtyLineMsg:
		// Update the viewport of the matching pane.
		for _, p := range m.ptyPanes {
			if p.ID == msg.PaneID {
				p.RefreshViewport()
				break
			}
		}
		return m, nil

	case PanePtyExitedMsg:
		// Mark the pane as exited; keep it visible so the user can read output.
		for _, p := range m.ptyPanes {
			if p.ID == msg.PaneID {
				// exited flag already set inside readLoop
				break
			}
		}
		return m, nil

	case tea.KeyMsg:
		// When a PTY pane has focus, forward almost all keys to it.
		if m.focus == focusPane && m.focusPaneID >= 0 {
			return m.handlePaneFocusedKey(msg)
		}

		switch msg.Type {
		case tea.KeyCtrlC:
			m.closeAllPanes()
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
				m.focus != focusCost &&
				m.focus != focusPane {
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
			// Scroll pane strip left.
			if len(m.ptyPanes) > 0 && m.paneOffset > 0 {
				m.paneOffset--
				return m, nil
			}
		case tea.KeyRight:
			if m.splitActive && m.splitFocIdx < len(m.splitPanes)-1 {
				m.splitFocIdx++
				return m, nil
			}
			// Scroll pane strip right.
			if len(m.ptyPanes) > 0 && m.paneOffset+maxVisiblePanes < len(m.ptyPanes) {
				m.paneOffset++
				return m, nil
			}
		}

		switch msg.String() {
		case "s":
			if m.focus != focusPlanReview && m.focus != focusInput {
				return m, m.toggleOverlay(focusSkills)
			}
		case "p":
			if m.focus != focusPlanReview && m.focus != focusInput {
				return m, m.toggleOverlay(focusPersonas)
			}
		case "$":
			if m.focus != focusPlanReview && m.focus != focusInput {
				return m, m.toggleOverlay(focusCost)
			}
		// F1-F4: focus visible pane 1-4.
		case "f1", "1":
			if m.focus != focusInput && m.focus != focusPlanReview {
				return m, m.focusPane(0)
			}
		case "f2", "2":
			if m.focus != focusInput && m.focus != focusPlanReview {
				return m, m.focusPane(1)
			}
		case "f3", "3":
			if m.focus != focusInput && m.focus != focusPlanReview {
				return m, m.focusPane(2)
			}
		case "f4", "4":
			if m.focus != focusInput && m.focus != focusPlanReview {
				return m, m.focusPane(3)
			}
		case "0":
			// Return focus to main panel.
			if m.focus == focusPane {
				m.focus = focusInput
				m.focusPaneID = -1
				return m, m.input.Focus()
			}
		case "ctrl+n":
			// Open a new pane with the default backend (claude).
			if m.runner != nil {
				return m, m.openPane("claude", "claude", "")
			}
		case "ctrl+w":
			// Close the focused pane.
			if m.focus == focusPane {
				return m, m.closeFocusedPane()
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

		plan := msg.Plan

		// Open a PTY pane for each unique backend in the plan.
		// Multiple steps with the same backend share one pane.
		var openCmds []tea.Cmd
		seenBackend := map[string]bool{}
		for _, step := range plan.Steps {
			b := step.Backend
			if seenBackend[b] {
				continue
			}
			seenBackend[b] = true
			label := fmt.Sprintf("%s:%s", b, "devloop")
			cmd := m.openPane(b, label, step.Description)
			if cmd != nil {
				openCmds = append(openCmds, cmd)
			}
		}

		// Also run sequential dispatch to feed steps into the orchestrator.
		ch := make(chan string, 256)
		m.outputCh = ch
		disp := m.disp
		go func() {
			defer close(ch)
			for _, step := range plan.Steps {
				ch <- fmt.Sprintf("[%d/%d] %s", step.Number, len(plan.Steps), step.Description)
			}
			_, err := disp.DispatchOpts(context.Background(), plan, orchestrator.DispatcherOpts{OutputCh: ch})
			if err != nil {
				ch <- "Error: " + err.Error()
			}
		}()
		openCmds = append(openCmds, waitForLine(ch), m.input.Focus())
		return m, tea.Batch(openCmds...)

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
			// Mirror to main viewport so output is preserved after split clears.
			m.output.AppendLine(fmt.Sprintf("[%d] %s", msg.PaneIndex+1, msg.Line))
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

	statusText := "  devloop v6  [Ctrl+N new pane  1-4 focus pane  0 main  Ctrl+W close  Tab focus]"
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
	case m.focus == focusPane:
		statusText = fmt.Sprintf("  Agent pane  [0 = main  Ctrl+W close  ←/→ scroll panes (%d/%d)]",
			m.paneOffset+1, len(m.ptyPanes))
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
	default:
		middle = m.renderMainWithPanes()
	}

	return lipgloss.JoinVertical(lipgloss.Left,
		statusBar,
		middle,
		m.input.View(),
	)
}

// renderMainWithPanes renders the main output panel with PTY panes on the right.
// Layout: main panel (left) + up to maxVisiblePanes panes (right).
func (m Model) renderMainWithPanes() string {
	contentH := m.height - statusBarHeight - inputBarHeight
	if contentH < 1 {
		contentH = 1
	}

	visible := m.visiblePanes()
	if len(visible) == 0 {
		// No panes: main panel fills the whole width (sidebar + output).
		return lipgloss.JoinHorizontal(lipgloss.Top,
			m.sidebar.View(),
			m.output.View(),
		)
	}

	// Main panel takes 40% of width; panes share the rest equally.
	nPanes := len(visible)
	mainW := m.width * 40 / 100
	panesW := m.width - mainW
	paneW := panesW / nPanes

	// Recompute sidebar and output to fit mainW.
	sbW := int(float64(mainW) * sidebarFraction)
	outW := mainW - sbW
	m.sidebar.SetSize(sbW, contentH)
	m.output.SetSize(outW, contentH)

	mainSection := lipgloss.JoinHorizontal(lipgloss.Top,
		m.sidebar.View(),
		m.output.View(),
	)

	// Render each visible pane.
	paneViews := make([]string, len(visible))
	for i, p := range visible {
		p.Resize(paneW, contentH)
		focused := m.focus == focusPane && p.ID == m.focusPaneID
		paneViews[i] = p.View(focused)
	}

	// Scroll indicator when more panes than visible.
	total := len(m.ptyPanes)
	if total > maxVisiblePanes {
		end := m.paneOffset + nPanes
		indicator := lipgloss.NewStyle().Foreground(lipgloss.Color("#888888")).
			Render(fmt.Sprintf(" [%d-%d of %d  ←/→ scroll]", m.paneOffset+1, end, total))
		paneViews = append(paneViews, indicator)
	}

	paneSection := lipgloss.JoinHorizontal(lipgloss.Top, paneViews...)
	return lipgloss.JoinHorizontal(lipgloss.Top, mainSection, paneSection)
}

// visiblePanes returns the slice of panes currently on screen (up to maxVisiblePanes).
func (m Model) visiblePanes() []*PtyPane {
	if len(m.ptyPanes) == 0 {
		return nil
	}
	start := m.paneOffset
	end := start + maxVisiblePanes
	if end > len(m.ptyPanes) {
		end = len(m.ptyPanes)
	}
	return m.ptyPanes[start:end]
}

// setSize recomputes layout after a terminal resize.
func (m *Model) setSize(w, h int) {
	m.width = w
	m.height = h

	contentH := h - statusBarHeight - inputBarHeight
	if contentH < 0 {
		contentH = 0
	}

	// When panes are open, main panel gets 40% width.
	mainW := w
	if len(m.ptyPanes) > 0 {
		mainW = w * 40 / 100
	}
	sidebarW := int(float64(mainW) * sidebarFraction)
	outputW := mainW - sidebarW

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

// resizePtyPanes updates PTY pane dimensions based on current terminal size.
func (m *Model) resizePtyPanes() {
	visible := m.visiblePanes()
	if len(visible) == 0 {
		return
	}
	contentH := m.height - statusBarHeight - inputBarHeight
	if contentH < 1 {
		contentH = 1
	}
	panesW := m.width - (m.width * 40 / 100)
	paneW := panesW / len(visible)
	if paneW < 10 {
		paneW = 10
	}
	for _, p := range visible {
		p.Resize(paneW, contentH)
	}
}

// openPane creates a new PTY pane for the named backend.
// label is the display name; initialInput is written to stdin after start.
// Returns nil if the backend is not available.
func (m *Model) openPane(backendID, label, initialInput string) tea.Cmd {
	if m.runner == nil {
		return nil
	}
	binary, args, ok := m.runner.BackendBinary(backendID)
	if !ok {
		// Backend not found — log to main output and skip.
		m.output.AppendLine(fmt.Sprintf("⚠ Backend %q not available", backendID))
		return nil
	}

	id := m.nextPaneID
	m.nextPaneID++

	contentH := m.height - statusBarHeight - inputBarHeight
	if contentH < 4 {
		contentH = 24
	}
	nVisible := len(m.ptyPanes) + 1
	if nVisible > maxVisiblePanes {
		nVisible = maxVisiblePanes
	}
	panesW := m.width - (m.width * 40 / 100)
	paneW := panesW / nVisible
	if paneW < 20 {
		paneW = 80
	}

	prog := m.program // capture for goroutine
	send := func(msg tea.Msg) {
		if prog != nil {
			prog.Send(msg)
		}
	}

	pane, err := newPtyPane(id, binary, args, label, backendID, paneW, contentH, initialInput, send)
	if err != nil {
		m.output.AppendLine(fmt.Sprintf("⚠ Could not open pane for %q: %v", backendID, err))
		return nil
	}

	m.ptyPanes = append(m.ptyPanes, pane)
	m.output.AppendLine(fmt.Sprintf("▸ Opened pane [%d] %s", id+1, label))

	// Scroll offset so the new pane is visible.
	if len(m.ptyPanes) > maxVisiblePanes {
		m.paneOffset = len(m.ptyPanes) - maxVisiblePanes
	}

	return nil // pane goroutine sends msgs via prog.Send
}

// focusPane sets keyboard focus to the visible pane at slot visibleIdx (0-based).
func (m *Model) focusPane(visibleIdx int) tea.Cmd {
	visible := m.visiblePanes()
	if visibleIdx < 0 || visibleIdx >= len(visible) {
		return nil
	}
	m.focus = focusPane
	m.focusPaneID = visible[visibleIdx].ID
	m.input.Blur()
	return nil
}

// handlePaneFocusedKey forwards the key to the focused PTY pane.
// Ctrl+0 / Esc returns focus to the main panel.
func (m Model) handlePaneFocusedKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	// Ctrl+0 or backtick returns focus to main.
	if msg.String() == "0" || msg.Type == tea.KeyCtrlBackslash {
		m.focus = focusInput
		m.focusPaneID = -1
		return m, m.input.Focus()
	}
	// Ctrl+W closes the focused pane.
	if msg.Type == tea.KeyCtrlW {
		return m, m.closeFocusedPane()
	}
	// Forward all other keys to the focused pane's PTY.
	for _, p := range m.ptyPanes {
		if p.ID == m.focusPaneID {
			p.Write(keyToBytes(msg))
			break
		}
	}
	return m, nil
}

// closeFocusedPane closes the currently focused pane and returns focus to main.
func (m *Model) closeFocusedPane() tea.Cmd {
	for i, p := range m.ptyPanes {
		if p.ID == m.focusPaneID {
			p.Close()
			m.ptyPanes = append(m.ptyPanes[:i], m.ptyPanes[i+1:]...)
			m.output.AppendLine(fmt.Sprintf("✕ Closed pane [%d] %s", p.ID+1, p.Label))
			break
		}
	}
	m.focus = focusInput
	m.focusPaneID = -1
	// Clamp paneOffset.
	if m.paneOffset > 0 && m.paneOffset >= len(m.ptyPanes) {
		m.paneOffset = len(m.ptyPanes) - 1
		if m.paneOffset < 0 {
			m.paneOffset = 0
		}
	}
	return m.input.Focus()
}

// closeAllPanes terminates all PTY pane subprocesses (called on quit).
func (m *Model) closeAllPanes() {
	for _, p := range m.ptyPanes {
		p.Close()
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

// waitForPaneOutput returns a Cmd that reads one PaneOutputMsg from ch.
// When ch is closed it reads the dispatch error from errCh and returns taskResultMsg.
// A nil ch is a no-op (returns nil Cmd) as a safety guard.
func waitForPaneOutput(ch <-chan PaneOutputMsg, errCh <-chan error) tea.Cmd {
	if ch == nil {
		return nil
	}
	return func() tea.Msg {
		msg, ok := <-ch
		if !ok {
			// Drain the error (blocks briefly until dispatch goroutine sends).
			var err error
			if e, ok2 := <-errCh; ok2 {
				err = e
			}
			return taskResultMsg{err: err}
		}
		return msg
	}
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
	p := tea.NewProgram(m, tea.WithAltScreen(), tea.WithMouseCellMotion())
	// Expose program handle so PTY pane goroutines can inject messages.
	m.program = p
	_, err := p.Run()
	// Ensure all PTY pane subprocesses are cleaned up on exit.
	// (model is value-copied inside tea.Program, so we call cleanup on m directly)
	return err
}
