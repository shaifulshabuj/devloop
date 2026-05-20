package tui

import (
	"fmt"

	"github.com/charmbracelet/lipgloss"

	"github.com/shaifulshabuj/devloop/v6/internal/config"
)

var (
	sidebarStyle = lipgloss.NewStyle().
			Background(lipgloss.Color("#1a1a2e")).
			Foreground(lipgloss.Color("#ffffff"))

	sidebarLabelStyle = lipgloss.NewStyle().
				Bold(true).
				Foreground(lipgloss.Color("#7c7cff")).
				Background(lipgloss.Color("#1a1a2e"))

	sidebarActiveStyle = lipgloss.NewStyle().
				Foreground(lipgloss.Color("#00ff88")).
				Background(lipgloss.Color("#1a1a2e"))

	sidebarCursorStyle = lipgloss.NewStyle().
				Bold(true).
				Foreground(lipgloss.Color("#ffffff")).
				Background(lipgloss.Color("#2a2a4e"))

	sidebarNameStyle = lipgloss.NewStyle().
				Foreground(lipgloss.Color("#aaaaaa")).
				Background(lipgloss.Color("#1a1a2e"))
)

// Sidebar is the left-side project list component.
type Sidebar struct {
	projectName  string
	activePath   string
	runningTitle string
	projects     []config.ProjectEntry
	cursor       int
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

// SetProjects updates the project list and active project path.
func (s *Sidebar) SetProjects(projects []config.ProjectEntry, activePath string) {
	s.projects = projects
	s.activePath = activePath
	// Sync cursor to active project.
	for i, p := range projects {
		if p.Path == activePath {
			s.cursor = i
			break
		}
	}
}

// MoveCursor shifts the cursor by delta rows (clamped to list bounds).
func (s *Sidebar) MoveCursor(delta int) {
	s.cursor += delta
	if s.cursor < 0 {
		s.cursor = 0
	}
	if s.cursor >= len(s.projects) && len(s.projects) > 0 {
		s.cursor = len(s.projects) - 1
	}
}

// SelectedPath returns the path of the currently highlighted project.
func (s *Sidebar) SelectedPath() string {
	if len(s.projects) == 0 || s.cursor < 0 || s.cursor >= len(s.projects) {
		return ""
	}
	return s.projects[s.cursor].Path
}

// View renders the sidebar.
func (s Sidebar) View() string {
	var content string

	projectsLabel := sidebarLabelStyle.Render("Projects")
	content = "  " + projectsLabel + "\n"

	if len(s.projects) == 0 {
		content += "  " + sidebarNameStyle.Render(s.projectName) + "\n"
	} else {
		for i, p := range s.projects {
			name := p.Name
			if name == "" {
				name = p.Path
			}
			// Truncate name to fit sidebar width.
			maxLen := s.width - 6
			if maxLen > 0 && len(name) > maxLen {
				name = name[:maxLen]
			}

			var marker string
			if p.Path == s.activePath {
				marker = "●"
			} else {
				marker = " "
			}

			line := fmt.Sprintf("  %s %s", marker, name)
			if i == s.cursor {
				content += sidebarCursorStyle.Render(line) + "\n"
			} else if p.Path == s.activePath {
				content += sidebarActiveStyle.Render(line) + "\n"
			} else {
				content += sidebarNameStyle.Render(line) + "\n"
			}
		}
	}

	if s.runningTitle != "" {
		runLabel := sidebarLabelStyle.Render("Running")
		content += "\n  " + runLabel + "\n  " + sidebarNameStyle.Render(s.runningTitle) + "\n"
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
