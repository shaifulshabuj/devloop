package tui

import (
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

var outputStyle = lipgloss.NewStyle().
	Border(lipgloss.NormalBorder()).
	BorderForeground(lipgloss.Color("#444444"))

// Output wraps the bubbles viewport for streaming agent output.
type Output struct {
	vp      viewport.Model
	content string
}

// NewOutput creates an Output with placeholder text.
func NewOutput() Output {
	vp := viewport.New(0, 0)
	const placeholder = "Waiting for input…"
	vp.SetContent(placeholder)
	return Output{vp: vp, content: placeholder}
}

// SetSize updates the viewport dimensions, accounting for the surrounding border.
func (o *Output) SetSize(w, h int) {
	// The NormalBorder adds 1 char on each side (2 total per axis).
	vpW := w - 2
	vpH := h - 2
	if vpW < 0 {
		vpW = 0
	}
	if vpH < 0 {
		vpH = 0
	}
	o.vp.Width = vpW
	o.vp.Height = vpH
}

// Update forwards messages to the underlying viewport (handles ↑/↓ scrolling).
func (o Output) Update(msg tea.Msg) (Output, tea.Cmd) {
	var cmd tea.Cmd
	o.vp, cmd = o.vp.Update(msg)
	return o, cmd
}

// View renders the output viewport inside a border.
func (o Output) View() string {
	return outputStyle.Render(o.vp.View())
}

// SetContent replaces the viewport content and scrolls to the bottom.
func (o *Output) SetContent(s string) {
	o.content = s
	o.vp.SetContent(s)
	o.vp.GotoBottom()
}

// AppendLine adds a line to the viewport content and scrolls to the bottom.
func (o *Output) AppendLine(line string) {
	if o.content == "" {
		o.content = line
	} else {
		o.content += "\n" + line
	}
	o.vp.SetContent(o.content)
	o.vp.GotoBottom()
}
