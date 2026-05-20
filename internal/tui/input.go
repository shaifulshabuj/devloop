package tui

import (
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

var inputStyle = lipgloss.NewStyle().
	BorderStyle(lipgloss.NormalBorder()).
	BorderTop(true).
	BorderForeground(lipgloss.Color("#444444"))

// Input wraps the bubbles text-input for single-line command entry.
type Input struct {
	ti    textinput.Model
	width int
}

// NewInput creates an Input with a "> " prompt.
func NewInput() Input {
	ti := textinput.New()
	ti.Prompt = "> "
	ti.CharLimit = 500
	return Input{ti: ti}
}

// Init returns the blinking cursor command.
func (i Input) Init() tea.Cmd {
	return textinput.Blink
}

// Update forwards messages to the underlying text-input.
// On Enter with non-empty content, emits SubmitMsg and clears the field.
func (i Input) Update(msg tea.Msg) (Input, tea.Cmd) {
	if km, ok := msg.(tea.KeyMsg); ok && km.Type == tea.KeyEnter {
		if text := i.ti.Value(); text != "" {
			i.ti.Reset()
			return i, func() tea.Msg { return SubmitMsg{Text: text} }
		}
	}
	var cmd tea.Cmd
	i.ti, cmd = i.ti.Update(msg)
	return i, cmd
}

// View renders the input field.
func (i Input) View() string {
	// The top border adds 1 line; the content occupies 1 line.
	return inputStyle.Width(i.width).Render(i.ti.View())
}

// SetWidth updates the visible width.
func (i *Input) SetWidth(w int) {
	i.width = w
	// Subtract prompt length (2) and border padding (2) from usable width.
	usable := w - 4
	if usable < 1 {
		usable = 1
	}
	i.ti.Width = usable
}

// Focus gives keyboard focus to the input and returns a Cmd for the cursor.
func (i *Input) Focus() tea.Cmd {
	return i.ti.Focus()
}

// Blur removes keyboard focus from the input.
func (i *Input) Blur() {
	i.ti.Blur()
}

// Value returns the current text.
func (i Input) Value() string {
	return i.ti.Value()
}

// Reset clears the input field.
func (i *Input) Reset() {
	i.ti.Reset()
}
