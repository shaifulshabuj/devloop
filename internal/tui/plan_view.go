package tui

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/shaifulshabuj/devloop/v6/internal/orchestrator"
)

// Ensure *PlanView satisfies tea.Model at compile time.
var _ tea.Model = (*PlanView)(nil)

var (
	planHeaderStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("#7c7cff"))

	planCursorStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("#ffffff")).
			Background(lipgloss.Color("#1a1a2e"))

	planStepStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#cccccc"))

	planFooterStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#444444"))
)

// PlanApprovedMsg is sent when the user approves the plan.
type PlanApprovedMsg struct{ Plan *orchestrator.Plan }

// PlanRejectedMsg is sent when the user rejects the plan.
type PlanRejectedMsg struct{}

// PlanView is a Bubble Tea component for reviewing an orchestrator Plan.
type PlanView struct {
	plan     *orchestrator.Plan
	cursor   int  // which step is highlighted
	approved bool // set to true when user presses Enter/y
	rejected bool // set to true when user presses q/n/Escape
	width    int
	height   int
}

// NewPlanView creates a PlanView for the given plan.
func NewPlanView(plan *orchestrator.Plan) *PlanView {
	return &PlanView{plan: plan}
}

// Init implements tea.Model.
func (p *PlanView) Init() tea.Cmd { return nil }

// Update implements tea.Model.
func (p *PlanView) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		p.width = msg.Width
		p.height = msg.Height

	case tea.KeyMsg:
		switch msg.String() {
		case "up", "k":
			if p.cursor > 0 {
				p.cursor--
			}
		case "down", "j":
			if p.plan != nil && p.cursor < len(p.plan.Steps)-1 {
				p.cursor++
			}
		case "enter", "y":
			p.approved = true
			return p, func() tea.Msg { return PlanApprovedMsg{Plan: p.plan} }
		case "q", "n", "esc":
			p.rejected = true
			return p, func() tea.Msg { return PlanRejectedMsg{} }
		}
	}

	return p, nil
}

// View renders the plan review UI.
func (p *PlanView) View() string {
	if p.plan == nil {
		return "No plan loaded."
	}

	var sb strings.Builder

	// Header: "Plan: <title>" in bold.
	sb.WriteString(planHeaderStyle.Render("Plan: " + p.plan.Title))
	sb.WriteString("\n")

	// Estimated time line.
	fmt.Fprintf(&sb, "Estimated time: %s\n\n", p.plan.EstimatedTime)

	// Numbered list of steps — highlight the cursor row with ">".
	for i, step := range p.plan.Steps {
		line := fmt.Sprintf("%d. %s  [%s / %s]  (%s)",
			step.Number, step.Description, step.Backend, step.Model, step.Status)
		if i == p.cursor {
			sb.WriteString(planCursorStyle.Render("> " + line))
		} else {
			sb.WriteString(planStepStyle.Render("  " + line))
		}
		sb.WriteString("\n")
	}

	sb.WriteString("\n")

	// Footer: navigation hint.
	sb.WriteString(planFooterStyle.Render("↑/↓ navigate  Enter/y approve  q/n reject"))

	return sb.String()
}
