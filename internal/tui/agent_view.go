package tui

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/shaifulshabuj/devloop/internal/agent"
)

// Ensure *AgentView satisfies tea.Model at compile time.
var _ tea.Model = (*AgentView)(nil)

var (
	agentHeaderStyle = lipgloss.NewStyle().
				Bold(true).
				Foreground(lipgloss.Color("#7c7cff"))

	agentAvailableStyle = lipgloss.NewStyle().
				Foreground(lipgloss.Color("#00ff88"))

	agentUnavailableStyle = lipgloss.NewStyle().
				Foreground(lipgloss.Color("#ff6b6b"))

	agentCursorStyle = lipgloss.NewStyle().
				Bold(true).
				Foreground(lipgloss.Color("#ffffff")).
				Background(lipgloss.Color("#1a1a2e"))

	agentRowStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#cccccc"))

	agentFooterStyle = lipgloss.NewStyle().
				Foreground(lipgloss.Color("#444444"))

	agentColHeaderStyle = lipgloss.NewStyle().
				Foreground(lipgloss.Color("#888888")).
				Underline(true)
)

// AgentEntry represents one backend shown in the agent view.
type AgentEntry struct {
	Backend      *agent.Backend
	SessionCount int
}

// AgentView displays available agent backends and their session counts.
type AgentView struct {
	entries []AgentEntry
	cursor  int
	width   int
	height  int
}

// NewAgentView creates an AgentView populated from runner.AvailableBackends()
// with SessionCount initialised to 0 for each entry.
func NewAgentView(runner *agent.Runner) *AgentView {
	var entries []AgentEntry
	for _, b := range runner.AvailableBackends() {
		entries = append(entries, AgentEntry{Backend: b, SessionCount: 0})
	}
	return &AgentView{entries: entries}
}

// SetEntries replaces the entry list (for live updates from the pool).
func (a *AgentView) SetEntries(entries []AgentEntry) {
	a.entries = entries
	// Keep cursor in bounds after the update.
	if a.cursor >= len(a.entries) {
		a.cursor = max(0, len(a.entries)-1)
	}
}

// Init implements tea.Model.
func (a *AgentView) Init() tea.Cmd { return nil }

// Update implements tea.Model.
func (a *AgentView) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		a.width = msg.Width
		a.height = msg.Height

	case tea.KeyMsg:
		switch msg.String() {
		case "up", "k":
			if a.cursor > 0 {
				a.cursor--
			}
		case "down", "j":
			if a.cursor < len(a.entries)-1 {
				a.cursor++
			}
		case "enter":
			// No-op for now; reserved for future session-launch action.
		}
	}

	return a, nil
}

// View renders the agent backend status table.
func (a *AgentView) View() string {
	var sb strings.Builder

	// Header.
	sb.WriteString(agentHeaderStyle.Render("Agent Backends"))
	sb.WriteString("\n\n")

	if len(a.entries) == 0 {
		sb.WriteString(agentRowStyle.Render("No backends registered."))
		sb.WriteString("\n")
	} else {
		// Column header.
		header := fmt.Sprintf("  %-12s  %-16s  %s", "Name", "Status", "Sessions")
		sb.WriteString(agentColHeaderStyle.Render(header))
		sb.WriteString("\n")

		for i, e := range a.entries {
			var statusStr string
			if e.Backend.Found {
				statusStr = agentAvailableStyle.Render("✓ Available")
			} else {
				statusStr = agentUnavailableStyle.Render("✗ Not found")
			}

			// Build the plain-text columns without the status colour so we
			// can control which portion is highlighted for the cursor row.
			name := fmt.Sprintf("%-12s", e.Backend.ID)
			sessions := fmt.Sprintf("%d", e.SessionCount)

			if i == a.cursor {
				// Render the entire row highlighted; re-render status inside.
				rowPlain := fmt.Sprintf("  %s  %-16s  %s", name, stripAnsi(statusStr), sessions)
				sb.WriteString(agentCursorStyle.Render("> " + rowPlain))
			} else {
				// Render name and session count in muted style; status keeps colour.
				left := agentRowStyle.Render(fmt.Sprintf("  %s  ", name))
				right := agentRowStyle.Render(fmt.Sprintf("  %s", sessions))
				sb.WriteString(left + statusStr + right)
			}
			sb.WriteString("\n")
		}
	}

	sb.WriteString("\n")
	sb.WriteString(agentFooterStyle.Render("↑/↓ navigate"))

	return sb.String()
}

// stripAnsi removes ANSI escape sequences from s so that cursor-highlighted
// rows can be re-rendered with a uniform background colour.
func stripAnsi(s string) string {
	var out strings.Builder
	inEsc := false
	for _, r := range s {
		switch {
		case r == '\x1b':
			inEsc = true
		case inEsc && r == 'm':
			inEsc = false
		case !inEsc:
			out.WriteRune(r)
		}
	}
	return out.String()
}

// max returns the larger of a and b.
func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
