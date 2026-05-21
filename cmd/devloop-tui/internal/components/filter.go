package components

// This file extracts the fuzzy-filter primitive that originated inside
// task_picker.go. Two surfaces are exported:
//
//  1. FuzzyMatch(query, text) — pure helper, no UI state. Reused by
//     task_picker, palette (Phase 2), and any future searchable list.
//
//  2. Filter — a small Bubble Tea component wrapping textinput.Model.
//     Use it directly when you don't already have a bubbles/list
//     (task_picker already does, so it just consumes FuzzyMatch).
//
// Keeping these in one file avoids both task_picker and palette diverging
// into two fuzzy-match implementations.

import (
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
)

// FuzzyMatch returns true when every rune of query appears in order
// inside text. Empty query matches everything. Comparison is
// case-sensitive; callers should lower-case both sides if they want
// case-insensitive matching.
func FuzzyMatch(query, text string) bool {
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

// FuzzyMatchAny returns true when query fuzzy-matches any of the candidates.
// Case-insensitive — both sides are lower-cased before comparison.
func FuzzyMatchAny(query string, candidates ...string) bool {
	q := strings.ToLower(query)
	for _, c := range candidates {
		if FuzzyMatch(q, strings.ToLower(c)) {
			return true
		}
	}
	return false
}

// ── Filter component ──────────────────────────────────────────────────────────

// Filter is a thin wrapper around bubbles/textinput suitable for use as the
// input half of a search/palette UI. It does not own a list — callers wire
// the filter's value to whatever they want to render.
//
// Usage:
//
//	f := components.NewFilter("type to filter…")
//	// pass key messages while Focused
//	f, cmd = f.Update(msg)
//	matches := f.MatchIndices(items, func(i int) string { return items[i].Title })
type Filter struct {
	input   textinput.Model
	focused bool
}

// NewFilter constructs a Filter with the given placeholder text.
func NewFilter(placeholder string) Filter {
	ti := textinput.New()
	ti.Placeholder = placeholder
	ti.Prompt = " / "
	return Filter{input: ti}
}

// Focus puts the input into focused mode; the parent should route key
// messages here while focused.
func (f Filter) Focus() (Filter, tea.Cmd) {
	f.input.Focus()
	f.focused = true
	return f, textinput.Blink
}

// Blur defocuses without clearing the value.
func (f Filter) Blur() Filter {
	f.input.Blur()
	f.focused = false
	return f
}

// Clear empties the filter value and defocuses.
func (f Filter) Clear() Filter {
	f.input.SetValue("")
	f.input.Blur()
	f.focused = false
	return f
}

// Focused reports whether the filter currently owns keyboard input.
func (f Filter) Focused() bool { return f.focused }

// Value returns the current filter text.
func (f Filter) Value() string { return f.input.Value() }

// SetValue replaces the filter text without changing focus.
func (f Filter) SetValue(v string) Filter {
	f.input.SetValue(v)
	return f
}

// Update routes a tea.Msg to the underlying textinput when focused. When not
// focused, the message is ignored (caller handles its own key routing).
func (f Filter) Update(msg tea.Msg) (Filter, tea.Cmd) {
	if !f.focused {
		return f, nil
	}
	var cmd tea.Cmd
	f.input, cmd = f.input.Update(msg)
	return f, cmd
}

// View returns the rendered input row.
func (f Filter) View() string { return f.input.View() }

// MatchIndices returns indices of items whose key string fuzzy-matches the
// current filter value (case-insensitive). When the filter is empty, all
// indices are returned in order.
func (f Filter) MatchIndices(n int, key func(i int) string) []int {
	q := strings.ToLower(f.input.Value())
	out := make([]int, 0, n)
	for i := 0; i < n; i++ {
		if FuzzyMatch(q, strings.ToLower(key(i))) {
			out = append(out, i)
		}
	}
	return out
}
