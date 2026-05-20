package tui

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/shaifulshabuj/devloop/v6/internal/storage"
)

// Ensure *CostView satisfies tea.Model at compile time.
var _ tea.Model = (*CostView)(nil)

var (
	costHeaderStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("#7c7cff"))

	costCursorStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("#ffffff")).
			Background(lipgloss.Color("#1a1a2e"))

	costRowStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#cccccc"))

	costFooterStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#444444"))
)

// CostView displays estimated cost breakdown per task.
type CostView struct {
	costs  []storage.TaskCost
	cursor int
	width  int
	height int
	total  float64
}

// NewCostView creates a CostView for the given slice of TaskCost entries.
// It computes the total estimated USD from all entries.
func NewCostView(costs []storage.TaskCost) *CostView {
	var total float64
	for _, c := range costs {
		total += c.EstimatedUSD
	}
	return &CostView{costs: costs, total: total}
}

// Init implements tea.Model.
func (c *CostView) Init() tea.Cmd { return nil }

// Update implements tea.Model.
func (c *CostView) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		c.width = msg.Width
		c.height = msg.Height

	case tea.KeyMsg:
		switch msg.String() {
		case "up", "k":
			if c.cursor > 0 {
				c.cursor--
			}
		case "down", "j":
			if c.cursor < len(c.costs)-1 {
				c.cursor++
			}
		}
	}

	return c, nil
}

// View renders the cost tracking UI.
func (c *CostView) View() string {
	var sb strings.Builder

	// Header.
	sb.WriteString(costHeaderStyle.Render("Cost Tracking"))
	sb.WriteString("\n\n")

	if len(c.costs) == 0 {
		sb.WriteString(costRowStyle.Render("No cost data available."))
		sb.WriteString("\n")
	} else {
		// Column header.
		header := fmt.Sprintf("%-8s  %-20s  %10s  %11s  %10s",
			"Task ID", "Model", "Tokens In", "Tokens Out", "USD")
		sb.WriteString(costHeaderStyle.Render(header))
		sb.WriteString("\n")
		sb.WriteString(costFooterStyle.Render(strings.Repeat("─", len(header))))
		sb.WriteString("\n")

		// Rows.
		for i, tc := range c.costs {
			taskID := tc.TaskID
			if len(taskID) > 8 {
				taskID = taskID[:8]
			}

			line := fmt.Sprintf("%-8s  %-20s  %10d  %11d  %10.4f",
				taskID, tc.Model, tc.InputTokens, tc.OutputTokens, tc.EstimatedUSD)

			if i == c.cursor {
				sb.WriteString(costCursorStyle.Render("> " + line))
			} else {
				sb.WriteString(costRowStyle.Render("  " + line))
			}
			sb.WriteString("\n")
		}
	}

	sb.WriteString("\n")

	// Footer: navigation hint and total.
	sb.WriteString(costFooterStyle.Render("↑/↓ navigate"))
	sb.WriteString("\n")
	sb.WriteString(costHeaderStyle.Render(fmt.Sprintf("Total: $%.4f", c.total)))

	return sb.String()
}
