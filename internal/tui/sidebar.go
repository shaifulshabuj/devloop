package tui

import "github.com/charmbracelet/lipgloss"

var (
	sidebarStyle = lipgloss.NewStyle().
			Background(lipgloss.Color("#1a1a2e")).
			Foreground(lipgloss.Color("#ffffff"))

	sidebarLabelStyle = lipgloss.NewStyle().
				Bold(true).
				Foreground(lipgloss.Color("#7c7cff")).
				Background(lipgloss.Color("#1a1a2e"))
)

// Sidebar is the left-side project list component. For Phase 1 it shows
// only the name of the current project.
type Sidebar struct {
	projectName  string
	runningTitle string
	width        int
	height       int
}

// NewSidebar creates a Sidebar that displays projectName.
func NewSidebar(projectName string) Sidebar {
	return Sidebar{projectName: projectName}
}

// SetSize updates the rendered dimensions of the sidebar.
func (s *Sidebar) SetSize(w, h int) {
	s.width = w
	s.height = h
}

// View renders the sidebar.
func (s Sidebar) View() string {
	label := sidebarLabelStyle.Render("Project")
	content := "  " + label + "\n  " + s.projectName
	if s.runningTitle != "" {
		runLabel := sidebarLabelStyle.Render("Running")
		content += "\n\n  " + runLabel + "\n  " + s.runningTitle
	}

	return sidebarStyle.
		Width(s.width).
		Height(s.height).
		Render(content)
}

// SetRunningTask updates the sidebar's in-progress task display.
// Pass an empty string to clear.
func (s *Sidebar) SetRunningTask(title string) {
	s.runningTitle = title
}
