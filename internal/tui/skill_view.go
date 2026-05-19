package tui

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/shaifulshabuj/devloop/internal/agent"
)

// Ensure *SkillView satisfies tea.Model at compile time.
var _ tea.Model = (*SkillView)(nil)

var (
	skillHeaderStyle = lipgloss.NewStyle().
				Bold(true).
				Foreground(lipgloss.Color("#7c7cff"))

	skillCursorStyle = lipgloss.NewStyle().
				Bold(true).
				Foreground(lipgloss.Color("#ffffff")).
				Background(lipgloss.Color("#1a1a2e"))

	skillNameStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#cccccc"))

	skillPreviewStyle = lipgloss.NewStyle().
				Foreground(lipgloss.Color("#cccccc"))

	skillFooterStyle = lipgloss.NewStyle().
				Foreground(lipgloss.Color("#444444"))
)

const skillPreviewLines = 10

// SkillView displays available skills and a content preview.
type SkillView struct {
	skills []agent.Skill
	cursor int
	width  int
	height int
}

// NewSkillView creates a SkillView for the given slice of skills.
func NewSkillView(skills []agent.Skill) *SkillView {
	return &SkillView{skills: skills}
}

// Init implements tea.Model.
func (s *SkillView) Init() tea.Cmd { return nil }

// Update implements tea.Model.
func (s *SkillView) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		s.width = msg.Width
		s.height = msg.Height

	case tea.KeyMsg:
		switch msg.String() {
		case "up", "k":
			if s.cursor > 0 {
				s.cursor--
			}
		case "down", "j":
			if s.cursor < len(s.skills)-1 {
				s.cursor++
			}
		}
	}

	return s, nil
}

// View renders the skill list with a content preview panel.
func (s *SkillView) View() string {
	var sb strings.Builder

	// Header.
	sb.WriteString(skillHeaderStyle.Render("Skills (.devloop/skills/)"))
	sb.WriteString("\n\n")

	// Empty state.
	if len(s.skills) == 0 {
		sb.WriteString(skillNameStyle.Render("No skills found. Add .md files to .devloop/skills/"))
		sb.WriteString("\n")
		return sb.String()
	}

	// Left column: numbered list of skill names.
	var leftLines []string
	for i, sk := range s.skills {
		line := fmt.Sprintf("%d. %s", i+1, sk.Name)
		if i == s.cursor {
			leftLines = append(leftLines, skillCursorStyle.Render("> "+line))
		} else {
			leftLines = append(leftLines, skillNameStyle.Render("  "+line))
		}
	}
	left := strings.Join(leftLines, "\n")

	// Right column: first skillPreviewLines lines of selected skill content.
	var right string
	if s.cursor >= 0 && s.cursor < len(s.skills) {
		content := s.skills[s.cursor].Content
		lines := strings.Split(content, "\n")
		if len(lines) > skillPreviewLines {
			lines = lines[:skillPreviewLines]
		}
		right = skillPreviewStyle.Render(strings.Join(lines, "\n"))
	}

	// Render columns side by side when we have a width to work with.
	if s.width > 0 {
		leftWidth := s.width / 3
		rightWidth := s.width - leftWidth - 3 // 3 for separator padding

		leftCol := lipgloss.NewStyle().Width(leftWidth).Render(left)
		rightCol := lipgloss.NewStyle().Width(rightWidth).Render(right)

		sb.WriteString(lipgloss.JoinHorizontal(lipgloss.Top, leftCol, "  │  ", rightCol))
	} else {
		// Fallback: stacked layout when width is unknown.
		sb.WriteString(left)
		sb.WriteString("\n\n")
		sb.WriteString(right)
	}

	sb.WriteString("\n\n")

	// Footer.
	sb.WriteString(skillFooterStyle.Render("↑/↓ navigate"))

	return sb.String()
}
