package components

// Palette is the floating command palette overlay introduced by Phase 2.
// SPACE anywhere opens it (handled by the root AppModel); the palette
// renders centred over the active view, fuzzy-filters a list of devloop
// subcommands, and emits uimsg.PaletteRun when the user picks one.
//
// The component owns no subprocess execution. Picking an action emits the
// PaletteRun message; the root router forwards it to ChatModel which already
// knows how to run `bash devloop.sh <cmd> <arg>` via dispatchShell.

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/shaifulshabuj/devloop/devloop-tui/internal/theme"
	"github.com/shaifulshabuj/devloop/devloop-tui/internal/uimsg"
)

// PaletteAction is one row in the palette.
type PaletteAction struct {
	// Key is the single-letter shortcut shown on the left (typed when
	// the filter is empty). Case-insensitive.
	Key string
	// Label is the action name shown in the row.
	Label string
	// Desc is a one-line description shown to the right of the label.
	Desc string
	// Command is the devloop subcommand to run.
	Command string
}

// DefaultActions is the action set shown when no user filter is active.
// Ordering matches the redesign brief (core loop first, then read-only
// utilities, then Phase 4 additions for permit/daemon/resume).
var DefaultActions = []PaletteAction{
	{"A", "architect", "design a spec for a new feature", "architect"},
	{"W", "work", "run worker on the latest task", "work"},
	{"R", "review", "review implementation vs spec", "review"},
	{"F", "fix", "apply reviewer fix instructions", "fix"},
	{"L", "learn", "extract lessons to CLAUDE.md", "learn"},
	{"T", "tasks", "list all tasks with status", "tasks"},
	{"P", "providers", "show provider failover status", "failover"},
	{"D", "diff", "show git diff from baseline", "diff"},
	{"H", "hooks", "install Claude pipeline hooks", "hooks"},
	{"U", "update", "self-upgrade devloop script", "update"},

	// Phase 4 additions
	{"E", "run", "full pipeline: architect+work+review", "run"},
	{"G", "permit grant", "approve a queued permission request", "permit grant"},
	{"X", "permit deny", "deny a queued permission request", "permit deny"},
	{"Q", "permit status", "show permission gate status + log", "permit status"},
	{"I", "daemon start", "start devloop daemon (background)", "daemon"},
	{"K", "daemon stop", "stop running daemon", "daemon stop"},
	{"J", "daemon log", "tail live daemon log", "daemon log"},
	{"Z", "resume", "resume a quiet or paused pipeline", "resume"},
}

// Palette is a Bubble Tea sub-model.
type Palette struct {
	actions []PaletteAction
	filter  Filter
	cursor  int // index into the filtered list
	open    bool
	width   int
}

// NewPalette builds a palette with the given action set. Pass nil to use
// DefaultActions.
func NewPalette(actions []PaletteAction) Palette {
	if actions == nil {
		actions = DefaultActions
	}
	return Palette{
		actions: actions,
		filter:  NewFilter("search commands…"),
	}
}

// IsOpen reports whether the palette is currently displayed.
func (p Palette) IsOpen() bool { return p.open }

// Open shows the palette (resets cursor + clears any prior filter text).
func (p Palette) Open() (Palette, tea.Cmd) {
	p.filter = p.filter.Clear()
	var cmd tea.Cmd
	p.filter, cmd = p.filter.Focus()
	p.cursor = 0
	p.open = true
	return p, cmd
}

// Close hides the palette and defocuses the filter input.
func (p Palette) Close() Palette {
	p.filter = p.filter.Blur()
	p.open = false
	return p
}

// SetWidth tells the palette how wide its containing terminal is, so the
// overlay can be placed correctly by the caller.
func (p Palette) SetWidth(w int) Palette { p.width = w; return p }

// Update handles palette-specific keystrokes when open. Returns the new
// model and either nil or a tea.Cmd that closes the palette and emits the
// selected uimsg.PaletteRun.
func (p Palette) Update(msg tea.Msg) (Palette, tea.Cmd) {
	if !p.open {
		return p, nil
	}
	switch km := msg.(type) {
	case tea.KeyMsg:
		switch km.String() {
		case "esc":
			return p.Close(), nil
		case "up":
			if p.cursor > 0 {
				p.cursor--
			}
			return p, nil
		case "down":
			if p.cursor < len(p.filtered())-1 {
				p.cursor++
			}
			return p, nil
		case "enter":
			matches := p.filtered()
			if len(matches) == 0 || p.cursor >= len(matches) {
				return p, nil
			}
			act := matches[p.cursor]
			p = p.Close()
			return p, func() tea.Msg {
				return uimsg.PaletteRun{Command: act.Command}
			}
		}
		// Single-letter shortcut when the filter input is empty: pick the
		// matching action immediately without enter.
		if p.filter.Value() == "" {
			if act, ok := p.findByKey(km.String()); ok {
				p = p.Close()
				return p, func() tea.Msg {
					return uimsg.PaletteRun{Command: act.Command}
				}
			}
		}
	}
	// All other keys (typing into the filter) flow through to the filter.
	var cmd tea.Cmd
	p.filter, cmd = p.filter.Update(msg)
	// Keep cursor in bounds as the filtered set shrinks.
	if p.cursor >= len(p.filtered()) {
		p.cursor = 0
	}
	return p, cmd
}

// View renders the palette as a floating box. Callers compose it over the
// active view's output via lipgloss.Place.
func (p Palette) View() string {
	if !p.open {
		return ""
	}

	header := lipgloss.NewStyle().
		Foreground(theme.Blue).
		Padding(0, 1).
		Render("⌘ ") +
		p.filter.View() +
		lipgloss.NewStyle().Foreground(theme.Dim).Render("  esc")

	var rows []string
	matches := p.filtered()
	if len(matches) == 0 {
		rows = []string{lipgloss.NewStyle().Foreground(theme.Dim).Padding(0, 2).Render("(no matching commands)")}
	} else {
		for i, act := range matches {
			rows = append(rows, p.renderRow(act, i == p.cursor))
		}
	}

	body := strings.Join(rows, "\n")
	return theme.StylePalette.Render(lipgloss.JoinVertical(lipgloss.Left,
		header,
		lipgloss.NewStyle().Foreground(theme.Border).Render(strings.Repeat("─", 38)),
		body,
	))
}

func (p Palette) renderRow(act PaletteAction, selected bool) string {
	keyBadge := lipgloss.NewStyle().
		Background(theme.Surface2).
		Foreground(theme.Blue).
		Padding(0, 1).
		Render(act.Key)
	label := lipgloss.NewStyle().Foreground(theme.Text).Render(act.Label)
	desc := lipgloss.NewStyle().Foreground(theme.Dim).Render("— " + act.Desc)

	row := fmt.Sprintf("%s  %-10s %s", keyBadge, label, desc)
	if selected {
		return theme.StylePaletteSelected.Padding(0, 1).Render(row)
	}
	return lipgloss.NewStyle().Padding(0, 1).Render(row)
}

// filtered returns the actions matching the current filter value.
func (p Palette) filtered() []PaletteAction {
	q := strings.ToLower(strings.TrimSpace(p.filter.Value()))
	if q == "" {
		return p.actions
	}
	out := make([]PaletteAction, 0, len(p.actions))
	for _, a := range p.actions {
		if FuzzyMatch(q, strings.ToLower(a.Label)) ||
			FuzzyMatch(q, strings.ToLower(a.Desc)) ||
			FuzzyMatch(q, strings.ToLower(a.Command)) {
			out = append(out, a)
		}
	}
	return out
}

// findByKey returns the action whose Key matches (case-insensitive). Used
// for direct single-letter dispatch when the filter is empty.
func (p Palette) findByKey(key string) (PaletteAction, bool) {
	if len(key) != 1 {
		return PaletteAction{}, false
	}
	wanted := strings.ToUpper(key)
	for _, a := range p.actions {
		if strings.ToUpper(a.Key) == wanted {
			return a, true
		}
	}
	return PaletteAction{}, false
}
