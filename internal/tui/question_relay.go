package tui

import (
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

var (
	questionStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#ffff00")).
			Bold(true)

	questionFooterStyle = lipgloss.NewStyle().
				Foreground(lipgloss.Color("#888888"))
)

// QuestionAnsweredMsg is sent when the user submits their answer.
type QuestionAnsweredMsg struct {
	Question string
	Answer   string
}

// QuestionRelay is a Bubble Tea component for relaying agent questions to the user.
type QuestionRelay struct {
	question string
	input    textinput.Model
	answered bool
	width    int
}

// NewQuestionRelay creates a QuestionRelay for the given question string.
// The input placeholder is set to "Type your answer...".
func NewQuestionRelay(question string) *QuestionRelay {
	ti := textinput.New()
	ti.Placeholder = "Type your answer..."
	ti.CharLimit = 500
	ti.Focus()

	return &QuestionRelay{
		question: question,
		input:    ti,
	}
}

// Init implements tea.Model. Returns the textinput blink command.
func (q *QuestionRelay) Init() tea.Cmd {
	return textinput.Blink
}

// Update implements tea.Model.
// Handles:
//   - tea.WindowSizeMsg → update width
//   - tea.KeyMsg "enter" → answered=true, return QuestionAnsweredMsg with current answer
//   - tea.KeyMsg "esc" → answered=true, return QuestionAnsweredMsg with empty answer
//   - all other keys → delegate to input.Update()
func (q *QuestionRelay) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		q.width = msg.Width
		return q, nil

	case tea.KeyMsg:
		switch msg.Type {
		case tea.KeyEnter:
			q.answered = true
			return q, func() tea.Msg {
				return QuestionAnsweredMsg{
					Question: q.question,
					Answer:   q.input.Value(),
				}
			}

		case tea.KeyEsc:
			q.answered = true
			return q, func() tea.Msg {
				return QuestionAnsweredMsg{
					Question: q.question,
					Answer:   "",
				}
			}
		}
	}

	var cmd tea.Cmd
	q.input, cmd = q.input.Update(msg)
	return q, cmd
}

// View implements tea.Model.
// Shows the question text in yellow, the text input below, and a footer hint.
func (q *QuestionRelay) View() string {
	questionLine := questionStyle.Render(q.question)
	inputLine := q.input.View()
	footer := questionFooterStyle.Render("Enter to submit  Esc to skip")

	return lipgloss.JoinVertical(lipgloss.Left,
		questionLine,
		inputLine,
		footer,
	)
}
