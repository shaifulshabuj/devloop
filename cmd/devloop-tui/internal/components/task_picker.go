package components

import (
	"fmt"
	"io"
	"strings"
	"unicode/utf8"

	"github.com/charmbracelet/bubbles/list"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// Item is one entry shown in the Picker list.
type Item struct {
	ID       string // unique key (e.g. "TASK-20260516-...")
	Title    string // primary display text
	Subtitle string // secondary text (status, timestamps, …)
}

// Satisfy the bubbles/list.Item interface.
func (i Item) FilterValue() string { return i.Title }

// pickerDelegate controls how each Item is rendered inside the list.
type pickerDelegate struct{}

func (d pickerDelegate) Height() int                              { return 2 }
func (d pickerDelegate) Spacing() int                            { return 0 }
func (d pickerDelegate) Update(_ tea.Msg, _ *list.Model) tea.Cmd { return nil }
func (d pickerDelegate) Render(w io.Writer, m list.Model, index int, listItem list.Item) {
	item, ok := listItem.(Item)
	if !ok {
		return
	}

	isSelected := index == m.Index()
	var titleStyle, subtitleStyle lipgloss.Style
	if isSelected {
		titleStyle = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("205"))
		subtitleStyle = lipgloss.NewStyle().Faint(true).Foreground(lipgloss.Color("205"))
	} else {
		titleStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("252"))
		subtitleStyle = lipgloss.NewStyle().Faint(true)
	}

	fmt.Fprintf(w, "%s\n%s", titleStyle.Render(item.Title), subtitleStyle.Render(item.Subtitle))
}

// Picker is an fzf-style fuzzy-filter list component.
// It is a tea.Model and is meant to be embedded in a parent view.
type Picker struct {
	items         []Item
	filter        textinput.Model
	list          list.Model
	filterFocused bool
	width         int
	height        int
}

const defaultPickerHeight = 12

// NewPicker creates a Picker pre-loaded with items.
func NewPicker(items []Item) Picker {
	// Text input for filter
	ti := textinput.New()
	ti.Placeholder = "type to filter…"
	ti.Prompt = " / "
	ti.PromptStyle = lipgloss.NewStyle().Faint(true)
	ti.TextStyle = lipgloss.NewStyle()

	// List
	l := list.New(itemsToListItems(items), pickerDelegate{}, 0, defaultPickerHeight-2)
	l.SetShowHelp(false)
	l.SetShowTitle(false)
	l.SetShowStatusBar(false)
	l.SetFilteringEnabled(false) // we do our own filtering

	return Picker{
		items:  items,
		filter: ti,
		list:   l,
		height: defaultPickerHeight,
	}
}

func (p Picker) Init() tea.Cmd {
	return nil
}

func (p Picker) Update(msg tea.Msg) (Picker, tea.Cmd) {
	var cmds []tea.Cmd

	switch msg := msg.(type) {
	case tea.KeyMsg:
		if p.filterFocused {
			switch msg.String() {
			case "esc":
				// Clear filter, defocus
				p.filter.SetValue("")
				p.filter.Blur()
				p.filterFocused = false
				p = p.applyFilter()
				return p, nil

			case "enter":
				// Confirm filter, defocus (keep value)
				p.filter.Blur()
				p.filterFocused = false
				return p, nil

			case "up", "k":
				// Move selection without leaving filter
				var cmd tea.Cmd
				p.list, cmd = p.list.Update(tea.KeyMsg{Type: tea.KeyUp})
				cmds = append(cmds, cmd)
				return p, tea.Batch(cmds...)

			case "down", "j":
				var cmd tea.Cmd
				p.list, cmd = p.list.Update(tea.KeyMsg{Type: tea.KeyDown})
				cmds = append(cmds, cmd)
				return p, tea.Batch(cmds...)

			default:
				// Let textinput handle the keystroke, then re-filter
				var cmd tea.Cmd
				p.filter, cmd = p.filter.Update(msg)
				cmds = append(cmds, cmd)
				p = p.applyFilter()
				return p, tea.Batch(cmds...)
			}
		}

		// List-focused key handling
		switch msg.String() {
		case "/":
			// Focus the filter input
			p.filter.Focus()
			p.filterFocused = true
			return p, textinput.Blink

		default:
			// Delegate navigation keys and everything else to bubbles/list
			var cmd tea.Cmd
			p.list, cmd = p.list.Update(msg)
			cmds = append(cmds, cmd)
		}

	default:
		// Forward non-key messages (e.g. spinner ticks) to list
		var cmd tea.Cmd
		p.list, cmd = p.list.Update(msg)
		cmds = append(cmds, cmd)
	}

	return p, tea.Batch(cmds...)
}

func (p Picker) View() string {
	h := p.height
	if h <= 0 {
		h = defaultPickerHeight
	}

	// Render filter input (always visible, dim if not focused)
	var filterView string
	if p.filterFocused {
		filterView = p.filter.View()
	} else {
		// Show dim prompt + current value when not focused
		val := p.filter.Value()
		prompt := lipgloss.NewStyle().Faint(true).Render(" / ")
		if val == "" {
			filterView = lipgloss.NewStyle().Faint(true).Render(prompt + p.filter.Placeholder)
		} else {
			filterView = prompt + lipgloss.NewStyle().Faint(true).Render(val)
		}
	}

	// Resize list to fill remaining height
	listHeight := h - 2 // 1 line for filter + 1 line separator
	if listHeight < 1 {
		listHeight = 1
	}
	p.list.SetHeight(listHeight)
	if p.width > 0 {
		p.list.SetWidth(p.width)
	}

	sep := lipgloss.NewStyle().Faint(true).Render(strings.Repeat("─", max(p.width, 20)))

	return lipgloss.JoinVertical(lipgloss.Left, filterView, sep, p.list.View())
}

// SetItems replaces the underlying list and re-applies the current filter.
func (p Picker) SetItems(items []Item) Picker {
	p.items = items
	return p.applyFilter()
}

// Selected returns the highlighted item, or (Item{}, false) if empty.
func (p Picker) Selected() (Item, bool) {
	if len(p.list.Items()) == 0 {
		return Item{}, false
	}
	sel := p.list.SelectedItem()
	if sel == nil {
		return Item{}, false
	}
	item, ok := sel.(Item)
	return item, ok
}

// SetSize lets the parent control geometry.
func (p Picker) SetSize(width, height int) Picker {
	p.width = width
	p.height = height
	p.list.SetWidth(width)
	listHeight := height - 2
	if listHeight < 1 {
		listHeight = 1
	}
	p.list.SetHeight(listHeight)
	return p
}

// applyFilter re-filters p.items by the current filter value and resets the list.
func (p Picker) applyFilter() Picker {
	query := strings.ToLower(p.filter.Value())
	if query == "" {
		p.list.SetItems(itemsToListItems(p.items))
		return p
	}
	var filtered []list.Item
	for _, item := range p.items {
		if fuzzyMatch(query, strings.ToLower(item.Title)) ||
			fuzzyMatch(query, strings.ToLower(item.Subtitle)) {
			filtered = append(filtered, item)
		}
	}
	p.list.SetItems(filtered)
	return p
}

// fuzzyMatch returns true when every rune in query appears in order in text.
func fuzzyMatch(query, text string) bool {
	if query == "" {
		return true
	}
	qi := 0
	queryRunes := []rune(query)
	for _, r := range text {
		if qi < len(queryRunes) && r == queryRunes[qi] {
			qi++
		}
		if qi == len(queryRunes) {
			return true
		}
	}
	return qi == len(queryRunes)
}

// itemsToListItems converts []Item to []list.Item (interface slice).
func itemsToListItems(items []Item) []list.Item {
	out := make([]list.Item, len(items))
	for i, it := range items {
		out[i] = it
	}
	return out
}

// max returns the larger of two ints (Go 1.21 has built-in max, but 1.24 does too).
func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

// Ensure utf8 is referenced (used indirectly via rune iteration).
var _ = utf8.RuneCountInString
