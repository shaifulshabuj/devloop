package tui

import (
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// SplitPane manages a two-pane horizontal layout.
// Left pane: sidebar/navigation (fixed width ~25%)
// Right pane: main content (remaining width)
type SplitPane struct {
	leftContent  string // rendered left pane content
	rightContent string // rendered right pane content
	width        int
	height       int
	leftWidth    int // computed as width/4
	borderColor  string
}

// NewSplitPane returns a SplitPane with sensible defaults.
func NewSplitPane() *SplitPane {
	return &SplitPane{
		borderColor: "#444444",
	}
}

// SetSize updates the terminal dimensions and recomputes pane widths.
func (s *SplitPane) SetSize(width, height int) {
	s.width = width
	s.height = height
	s.leftWidth = width / 4
}

// SetLeft sets the rendered content for the left pane.
func (s *SplitPane) SetLeft(content string) {
	s.leftContent = content
}

// SetRight sets the rendered content for the right pane.
func (s *SplitPane) SetRight(content string) {
	s.rightContent = content
}

// Init implements tea.Model.
func (s *SplitPane) Init() tea.Cmd { return nil }

// Update implements tea.Model. Only tea.WindowSizeMsg is handled here;
// all other messages are forwarded to the caller to route to pane contents.
func (s *SplitPane) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	if wsMsg, ok := msg.(tea.WindowSizeMsg); ok {
		s.SetSize(wsMsg.Width, wsMsg.Height)
	}
	return s, nil
}

// View renders the left and right panes side by side.
// Left pane: fixed width s.leftWidth with a right-edge border.
// Right pane: fills remaining width.
// Both panes are constrained to s.height-2 rows to leave room for the
// tab bar and footer.
func (s *SplitPane) View() string {
	paneHeight := s.height - 2
	if paneHeight < 0 {
		paneHeight = 0
	}

	rightWidth := s.width - s.leftWidth
	if rightWidth < 0 {
		rightWidth = 0
	}

	leftStyle := lipgloss.NewStyle().
		Width(s.leftWidth).
		Height(paneHeight).
		BorderRight(true).
		BorderStyle(lipgloss.NormalBorder()).
		BorderForeground(lipgloss.Color(s.borderColor))

	rightStyle := lipgloss.NewStyle().
		Width(rightWidth).
		Height(paneHeight)

	left := leftStyle.Render(s.leftContent)
	right := rightStyle.Render(s.rightContent)

	return lipgloss.JoinHorizontal(lipgloss.Top, left, right)
}
