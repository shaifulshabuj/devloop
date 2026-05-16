package components

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// sendKeys sends a sequence of key messages to a Picker and returns the final state.
func sendKeys(p Picker, keys ...string) Picker {
	for _, k := range keys {
		var msg tea.Msg
		if len([]rune(k)) == 1 {
			msg = tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(k)}
		} else {
			// Named keys (esc, enter, up, down…)
			switch k {
			case "esc":
				msg = tea.KeyMsg{Type: tea.KeyEsc}
			case "enter":
				msg = tea.KeyMsg{Type: tea.KeyEnter}
			case "up":
				msg = tea.KeyMsg{Type: tea.KeyUp}
			case "down":
				msg = tea.KeyMsg{Type: tea.KeyDown}
			default:
				msg = tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(k)}
			}
		}
		p, _ = p.Update(msg)
	}
	return p
}

func TestPicker_SelectedEmpty(t *testing.T) {
	p := NewPicker(nil)
	item, ok := p.Selected()
	if ok {
		t.Errorf("expected ok=false for empty picker, got item=%+v", item)
	}
	if item != (Item{}) {
		t.Errorf("expected zero Item, got %+v", item)
	}
}

func TestPicker_SelectedFirst(t *testing.T) {
	items := []Item{
		{ID: "1", Title: "alpha", Subtitle: "running"},
		{ID: "2", Title: "beta", Subtitle: "done"},
		{ID: "3", Title: "gamma", Subtitle: "pending"},
	}
	p := NewPicker(items)
	sel, ok := p.Selected()
	if !ok {
		t.Fatal("expected ok=true for non-empty picker")
	}
	if sel.ID != "1" {
		t.Errorf("expected first item selected (ID=1), got %+v", sel)
	}
}

func TestPicker_FilterMatches(t *testing.T) {
	items := []Item{
		{ID: "1", Title: "foobar", Subtitle: "running"},
		{ID: "2", Title: "bazqux", Subtitle: "foozy"},
		{ID: "3", Title: "nomatch", Subtitle: "nothing"},
	}
	p := NewPicker(items)

	// Press "/" to focus filter, then type "foo"
	p = sendKeys(p, "/", "f", "o", "o")

	view := p.View()

	// Items 1 and 2 should appear (title "foobar" and subtitle "foozy" both fuzzy-match "foo")
	if !strings.Contains(view, "foobar") {
		t.Errorf("expected 'foobar' in filtered view:\n%s", view)
	}
	if !strings.Contains(view, "foozy") {
		t.Errorf("expected 'foozy' (subtitle of item 2) in filtered view:\n%s", view)
	}
	// Item 3 should be absent
	if strings.Contains(view, "nomatch") {
		t.Errorf("expected 'nomatch' to be filtered out:\n%s", view)
	}
}

func TestPicker_SetItems(t *testing.T) {
	original := []Item{
		{ID: "A", Title: "alpha"},
		{ID: "B", Title: "beta"},
	}
	replacement := []Item{
		{ID: "X", Title: "xenon"},
		{ID: "Y", Title: "yttrium"},
	}

	p := NewPicker(original)
	p = p.SetItems(replacement)

	sel, ok := p.Selected()
	if !ok {
		t.Fatal("expected ok=true after SetItems")
	}
	if sel.ID != "X" {
		t.Errorf("expected first item of replacement (ID=X), got %+v", sel)
	}
}

func TestPicker_SetSize(t *testing.T) {
	items := []Item{
		{ID: "1", Title: "alpha", Subtitle: "running"},
		{ID: "2", Title: "beta", Subtitle: "done"},
	}
	p := NewPicker(items)
	p = p.SetSize(60, 20)

	view := p.View()
	lines := strings.Split(view, "\n")

	// Should not produce excessively many lines
	if len(lines) > 22 {
		t.Errorf("expected <= 22 lines for height=20, got %d lines", len(lines))
	}

	// Every line should be within a reasonable width (ANSI escapes may add overhead,
	// so we check the raw byte count is under a generous bound)
	maxWidth := 0
	for _, line := range lines {
		// Strip ANSI sequences for a rough visual-width check
		stripped := stripANSI(line)
		if len([]rune(stripped)) > maxWidth {
			maxWidth = len([]rune(stripped))
		}
	}
	if maxWidth > 80 {
		t.Errorf("expected max visible line width <= 80, got %d", maxWidth)
	}
}

// stripANSI removes ANSI escape sequences for width estimation.
func stripANSI(s string) string {
	var b strings.Builder
	inEscape := false
	for _, r := range s {
		if inEscape {
			if r == 'm' {
				inEscape = false
			}
			continue
		}
		if r == '\x1b' {
			inEscape = true
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}
