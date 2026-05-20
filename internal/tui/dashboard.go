package tui

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/shaifulshabuj/devloop/v6/internal/storage"
)

// Ensure *Dashboard satisfies tea.Model at compile time.
var _ tea.Model = (*Dashboard)(nil)

var (
	dashHeaderStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("#7c7cff"))

	dashDoneStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#00ff88"))

	dashFailedStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#ff6b6b"))

	dashRunningStyle = lipgloss.NewStyle().
				Foreground(lipgloss.Color("#ffff00"))

	dashSepStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#333333"))

	dashFooterStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#444444"))

	dashLabelStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#cccccc"))
)

// DashboardStats holds the summary data for display.
type DashboardStats struct {
	ProjectName  string
	TotalTasks   int
	DoneTasks    int
	FailedTasks  int
	RunningTasks int
	RecentTasks  []*storage.Task // last 5
}

// Dashboard is a Bubble Tea component displaying project-wide stats.
type Dashboard struct {
	stats  DashboardStats
	width  int
	height int
}

// NewDashboard creates a Dashboard with the given stats.
func NewDashboard(stats DashboardStats) *Dashboard {
	return &Dashboard{stats: stats}
}

// SetStats updates the dashboard's displayed stats.
func (d *Dashboard) SetStats(stats DashboardStats) {
	d.stats = stats
}

// Init implements tea.Model.
func (d *Dashboard) Init() tea.Cmd { return nil }

// Update implements tea.Model. Only tea.WindowSizeMsg is handled.
func (d *Dashboard) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	if sz, ok := msg.(tea.WindowSizeMsg); ok {
		d.width = sz.Width
		d.height = sz.Height
	}
	return d, nil
}

// View renders the dashboard UI.
//
// Layout:
//
//	Header:    "DevLoop — <ProjectName>" in bold purple
//	Stats row: "Tasks: <total>  Done: <done>  Failed: <failed>  Running: <running>"
//	Separator line
//	"Recent Tasks:" header
//	Table of last 5 tasks: ID[:8] | status | title
//	Footer: "Press Tab to switch views"
func (d *Dashboard) View() string {
	var sb strings.Builder

	// Header.
	sb.WriteString(dashHeaderStyle.Render("DevLoop — " + d.stats.ProjectName))
	sb.WriteString("\n\n")

	// Stats row.
	total := dashLabelStyle.Render(fmt.Sprintf("Tasks: %d", d.stats.TotalTasks))
	done := dashDoneStyle.Render(fmt.Sprintf("Done: %d", d.stats.DoneTasks))
	failed := dashFailedStyle.Render(fmt.Sprintf("Failed: %d", d.stats.FailedTasks))
	running := dashRunningStyle.Render(fmt.Sprintf("Running: %d", d.stats.RunningTasks))
	sb.WriteString(strings.Join([]string{total, done, failed, running}, "  "))
	sb.WriteString("\n\n")

	// Separator.
	w := d.width
	if w < 1 {
		w = 40
	}
	sb.WriteString(dashSepStyle.Render(strings.Repeat("─", w)))
	sb.WriteString("\n\n")

	// Recent tasks header.
	sb.WriteString(dashHeaderStyle.Render("Recent Tasks:"))
	sb.WriteString("\n")

	if len(d.stats.RecentTasks) == 0 {
		sb.WriteString(dashLabelStyle.Render("  No tasks yet."))
		sb.WriteString("\n")
	} else {
		for _, t := range d.stats.RecentTasks {
			shortID := t.ID
			if len(shortID) > 8 {
				shortID = shortID[:8]
			}
			row := fmt.Sprintf("  %-8s │ %-10s │ %s", shortID, t.Status, t.Title)
			sb.WriteString(dashLabelStyle.Render(row))
			sb.WriteString("\n")
		}
	}

	sb.WriteString("\n")

	// Footer.
	sb.WriteString(dashFooterStyle.Render("Press Tab to switch views"))

	return sb.String()
}
