package tui

import (
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

var (
	tabActiveStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("#7c7cff")).
			Underline(true)

	tabInactiveStyle = lipgloss.NewStyle().
				Foreground(lipgloss.Color("#666666"))

	tabSeparatorStyle = lipgloss.NewStyle().
				Foreground(lipgloss.Color("#333333"))
)

// Tab represents a single tab entry.
type Tab struct {
	Label string
	Key   string // keyboard shortcut, e.g. "1", "2"
}

// TabChangedMsg is sent when the active tab changes.
type TabChangedMsg struct {
	Index int
	Tab   Tab
}

// DefaultTabs is the standard set of tabs for devloop v6.
var DefaultTabs = []Tab{
	{Label: "Chat", Key: "1"},
	{Label: "Plan", Key: "2"},
	{Label: "Agents", Key: "3"},
	{Label: "Skills", Key: "4"},
}

// TabBar renders a horizontal tab bar.
type TabBar struct {
	tabs   []Tab
	active int // index of active tab
	width  int
}

// Ensure *TabBar satisfies tea.Model at compile time.
var _ tea.Model = (*TabBar)(nil)

// NewTabBar creates a TabBar with the given tabs. The first tab is active
// by default.
func NewTabBar(tabs []Tab) *TabBar {
	return &TabBar{tabs: tabs}
}

// ActiveIndex returns the index of the currently active tab.
func (t *TabBar) ActiveIndex() int { return t.active }

// ActiveTab returns the currently active Tab.
func (t *TabBar) ActiveTab() Tab {
	if len(t.tabs) == 0 {
		return Tab{}
	}
	return t.tabs[t.active]
}

// Init implements tea.Model.
func (t *TabBar) Init() tea.Cmd { return nil }

// Update implements tea.Model.
//
// Handled messages:
//   - tea.WindowSizeMsg  — updates the width used for the separator line.
//   - tea.KeyMsg "1"–"4" — switches to the matching tab by key shortcut.
//   - tea.KeyMsg "tab"   — cycles to the next tab (wraps).
//   - tea.KeyMsg "shift+tab" — cycles to the previous tab (wraps).
func (t *TabBar) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		t.width = msg.Width

	case tea.KeyMsg:
		switch msg.String() {
		case "tab":
			return t, t.setActive((t.active + 1) % len(t.tabs))

		case "shift+tab":
			prev := t.active - 1
			if prev < 0 {
				prev = len(t.tabs) - 1
			}
			return t, t.setActive(prev)

		default:
			// Check if the key matches a tab shortcut.
			for i, tab := range t.tabs {
				if msg.String() == tab.Key {
					return t, t.setActive(i)
				}
			}
		}
	}

	return t, nil
}

// setActive switches to the given index and emits TabChangedMsg when the
// index actually changes.
func (t *TabBar) setActive(idx int) tea.Cmd {
	if idx == t.active {
		return nil
	}
	t.active = idx
	selected := t.tabs[idx]
	return func() tea.Msg {
		return TabChangedMsg{Index: idx, Tab: selected}
	}
}

// View renders the horizontal tab bar.
//
// Format:  "[1] Chat  [2] Plan  [3] Agents  [4] Skills"
// followed by a full-width separator line.
func (t *TabBar) View() string {
	if len(t.tabs) == 0 {
		return ""
	}

	parts := make([]string, len(t.tabs))
	for i, tab := range t.tabs {
		label := "[" + tab.Key + "] " + tab.Label
		if i == t.active {
			parts[i] = tabActiveStyle.Render(label)
		} else {
			parts[i] = tabInactiveStyle.Render(label)
		}
	}

	bar := strings.Join(parts, "  ")

	// Separator line — a horizontal rule the full width of the terminal.
	w := t.width
	if w < 1 {
		w = 1
	}
	separator := tabSeparatorStyle.Render(strings.Repeat("─", w))

	return lipgloss.JoinVertical(lipgloss.Left, bar, separator)
}
