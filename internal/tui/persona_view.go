package tui

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/shaifulshabuj/devloop/v6/internal/agent"
)

// Ensure *PersonaView satisfies tea.Model at compile time.
var _ tea.Model = (*PersonaView)(nil)

var (
	personaHeaderStyle = lipgloss.NewStyle().
				Bold(true).
				Foreground(lipgloss.Color("#7c7cff"))

	personaCursorStyle = lipgloss.NewStyle().
				Bold(true).
				Foreground(lipgloss.Color("#ffffff")).
				Background(lipgloss.Color("#1a1a2e"))

	personaNameStyle = lipgloss.NewStyle().
				Foreground(lipgloss.Color("#cccccc"))

	personaDetailStyle = lipgloss.NewStyle().
				Foreground(lipgloss.Color("#aaaaaa"))

	personaFooterStyle = lipgloss.NewStyle().
				Foreground(lipgloss.Color("#444444"))
)

const personaPromptPreviewLen = 300

// PersonaView displays available agent personas with a detail pane.
type PersonaView struct {
	personas []agent.Persona
	cursor   int
	width    int
	height   int
}

// NewPersonaView creates a PersonaView for the given slice of personas.
func NewPersonaView(personas []agent.Persona) *PersonaView {
	return &PersonaView{personas: personas}
}

// SetSize updates the display dimensions.
func (p *PersonaView) SetSize(w, h int) {
	p.width = w
	p.height = h
}

// Init implements tea.Model.
func (p *PersonaView) Init() tea.Cmd { return nil }

// Update implements tea.Model.
func (p *PersonaView) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	if km, ok := msg.(tea.KeyMsg); ok {
		switch km.String() {
		case "up", "k":
			if p.cursor > 0 {
				p.cursor--
			}
		case "down", "j":
			if p.cursor < len(p.personas)-1 {
				p.cursor++
			}
		}
	}
	return p, nil
}

// View renders the persona list with a detail pane.
func (p *PersonaView) View() string {
	var sb strings.Builder

	sb.WriteString(personaHeaderStyle.Render("Agent Personas"))
	sb.WriteString("\n\n")

	if len(p.personas) == 0 {
		sb.WriteString(personaNameStyle.Render("No personas available."))
		sb.WriteString("\n")
		return sb.String()
	}

	// Left column: numbered list of persona names.
	var leftLines []string
	for i, pr := range p.personas {
		line := fmt.Sprintf("%d. %s", i+1, pr.Name)
		if i == p.cursor {
			leftLines = append(leftLines, personaCursorStyle.Render("> "+line))
		} else {
			leftLines = append(leftLines, personaNameStyle.Render("  "+line))
		}
	}
	left := strings.Join(leftLines, "\n")

	// Right column: selected persona detail.
	var right string
	if p.cursor >= 0 && p.cursor < len(p.personas) {
		pr := p.personas[p.cursor]
		detail := fmt.Sprintf("Backend:  %s\nModel:    %s\n\n%s",
			pr.DefaultBackend, pr.PreferredModel, pr.Description)
		if pr.SystemPrompt != "" {
			prompt := pr.SystemPrompt
			if len(prompt) > personaPromptPreviewLen {
				prompt = prompt[:personaPromptPreviewLen] + "…"
			}
			detail += "\n\nSystem Prompt:\n" + prompt
		}
		right = personaDetailStyle.Render(detail)
	}

	if p.width > 0 {
		leftWidth := p.width / 3
		rightWidth := p.width - leftWidth - 3
		leftCol := lipgloss.NewStyle().Width(leftWidth).Render(left)
		rightCol := lipgloss.NewStyle().Width(rightWidth).Render(right)
		sb.WriteString(lipgloss.JoinHorizontal(lipgloss.Top, leftCol, "  │  ", rightCol))
	} else {
		sb.WriteString(left)
		sb.WriteString("\n\n")
		sb.WriteString(right)
	}

	sb.WriteString("\n\n")
	sb.WriteString(personaFooterStyle.Render("↑/↓ navigate  p/Esc close"))

	return sb.String()
}
