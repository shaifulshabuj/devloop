package components

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func TestFuzzyMatch_Empty(t *testing.T) {
	if !FuzzyMatch("", "anything") {
		t.Errorf("empty query should match everything")
	}
}

func TestFuzzyMatch_InOrder(t *testing.T) {
	cases := []struct {
		q, t string
		want bool
	}{
		{"abc", "axbxcx", true},
		{"abc", "abc", true},
		{"abc", "cba", false},
		{"add", "add date filter", true},
		{"ord", "add GET /orders endpoint", true},
		{"xyz", "abc", false},
		{"date", "add date filter", true},
	}
	for _, c := range cases {
		got := FuzzyMatch(c.q, c.t)
		if got != c.want {
			t.Errorf("FuzzyMatch(%q, %q) = %v, want %v", c.q, c.t, got, c.want)
		}
	}
}

func TestFuzzyMatchAny_CaseInsensitive(t *testing.T) {
	if !FuzzyMatchAny("ord", "ADD ORDERS", "fix bug") {
		t.Errorf("expected case-insensitive match")
	}
	if FuzzyMatchAny("xyz", "ADD ORDERS", "fix bug") {
		t.Errorf("expected no match")
	}
}

func TestFilter_UpdateAndMatch(t *testing.T) {
	items := []string{"add orders endpoint", "fix auth bug", "refactor billing"}
	f := NewFilter("…")
	f, _ = f.Focus()

	// Type "ord"
	for _, r := range "ord" {
		f, _ = f.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
	}

	if f.Value() != "ord" {
		t.Fatalf("filter value: want %q, got %q", "ord", f.Value())
	}

	idx := f.MatchIndices(len(items), func(i int) string { return items[i] })
	if len(idx) != 1 || idx[0] != 0 {
		t.Errorf("expected only 'add orders endpoint' (index 0), got %v", idx)
	}
}

func TestFilter_EmptyMatchesAll(t *testing.T) {
	items := []string{"a", "b", "c"}
	f := NewFilter("…")
	idx := f.MatchIndices(len(items), func(i int) string { return items[i] })
	if len(idx) != 3 {
		t.Errorf("empty filter should match all 3 items, got %d", len(idx))
	}
}

func TestFilter_BlurAndClear(t *testing.T) {
	f := NewFilter("…").SetValue("hello")
	f, _ = f.Focus()
	if !f.Focused() {
		t.Fatal("expected focused")
	}

	f = f.Blur()
	if f.Focused() || f.Value() != "hello" {
		t.Errorf("Blur should defocus but keep value, got focused=%v value=%q",
			f.Focused(), f.Value())
	}

	f = f.Clear()
	if f.Focused() || f.Value() != "" {
		t.Errorf("Clear should defocus and empty value, got focused=%v value=%q",
			f.Focused(), f.Value())
	}
}

func TestFilter_UpdateIgnoredWhenBlurred(t *testing.T) {
	f := NewFilter("…")
	// Not focused — Update should be a no-op.
	f, _ = f.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'x'}})
	if f.Value() != "" {
		t.Errorf("Update while blurred should not change value, got %q", f.Value())
	}
}

func TestFilter_View(t *testing.T) {
	f := NewFilter("typehere")
	out := f.View()
	if !strings.Contains(out, "/") {
		t.Errorf("expected '/' prompt in view, got %q", out)
	}
}
