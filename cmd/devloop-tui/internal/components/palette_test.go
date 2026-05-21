package components

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/shaifulshabuj/devloop/devloop-tui/internal/uimsg"
)

func TestPalette_StartsClosed(t *testing.T) {
	p := NewPalette(nil)
	if p.IsOpen() {
		t.Error("expected new palette to be closed")
	}
	if p.View() != "" {
		t.Error("closed palette View() should be empty")
	}
}

func TestPalette_OpenAndClose(t *testing.T) {
	p := NewPalette(nil)
	p, _ = p.Open()
	if !p.IsOpen() {
		t.Fatal("expected palette open after Open()")
	}
	out := p.SetWidth(60).View()
	if !strings.Contains(out, "architect") {
		t.Errorf("open palette should list default actions, got %q", out)
	}

	p = p.Close()
	if p.IsOpen() {
		t.Fatal("expected palette closed after Close()")
	}
}

func TestPalette_SingleLetterShortcut(t *testing.T) {
	p := NewPalette(nil)
	p, _ = p.Open()

	// Pressing 'a' should immediately select the 'architect' action
	// (filter is empty so single-letter dispatch is enabled).
	_, cmd := p.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("a")})
	if cmd == nil {
		t.Fatal("expected tea.Cmd from 'a' shortcut")
	}
	msg := cmd()
	pr, ok := msg.(uimsg.PaletteRun)
	if !ok {
		t.Fatalf("expected uimsg.PaletteRun, got %T", msg)
	}
	if pr.Command != "architect" {
		t.Errorf("expected Command 'architect', got %q", pr.Command)
	}
}

func TestPalette_EnterDispatchesSelected(t *testing.T) {
	p := NewPalette(nil)
	p, _ = p.Open()

	// Move cursor down twice → "review"
	p, _ = p.Update(tea.KeyMsg{Type: tea.KeyDown})
	p, _ = p.Update(tea.KeyMsg{Type: tea.KeyDown})

	_, cmd := p.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("expected tea.Cmd from enter")
	}
	msg := cmd()
	pr, ok := msg.(uimsg.PaletteRun)
	if !ok {
		t.Fatalf("expected uimsg.PaletteRun, got %T", msg)
	}
	if pr.Command != "review" {
		t.Errorf("expected Command 'review' (cursor on row 3), got %q", pr.Command)
	}
}

func TestPalette_FuzzyFilter(t *testing.T) {
	p := NewPalette(nil)
	p, _ = p.Open()

	// Lead with a non-shortcut letter so palette goes into filter-typing
	// mode instead of single-letter dispatch. Shortcut keys are
	// A W R F L T P D H U; 'o' isn't one, so it enters the filter.
	for _, r := range "ovid" { // fuzzy substring of "providers"
		p, _ = p.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
	}

	// Palette must stay open (filter typing, not dispatch).
	if !p.IsOpen() {
		t.Fatal("typing non-shortcut letters should not dispatch")
	}

	// "providers" must be among the matches.
	found := false
	for _, m := range p.filtered() {
		if m.Command == "failover" { // 'providers' action's underlying cmd
			found = true
			break
		}
	}
	if !found {
		t.Errorf("expected 'providers' in filtered set, got %v", p.filtered())
	}
}

func TestPalette_SingleLetterIgnoredAfterTyping(t *testing.T) {
	p := NewPalette(nil)
	p, _ = p.Open()

	// Start typing with a non-shortcut letter so we enter filter mode.
	// 'm' is not a single-letter shortcut in the default action set.
	p, _ = p.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'m'}})
	// Now 'a' should narrow the filter further, NOT dispatch architect.
	p, cmd := p.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'a'}})
	if cmd != nil {
		if _, ok := cmd().(uimsg.PaletteRun); ok {
			t.Error("'a' after typing should filter, not dispatch")
		}
	}
	if !p.IsOpen() {
		t.Error("palette should still be open after typing")
	}
}

func TestPalette_EscClosesWithoutDispatch(t *testing.T) {
	p := NewPalette(nil)
	p, _ = p.Open()

	p, cmd := p.Update(tea.KeyMsg{Type: tea.KeyEsc})
	if cmd != nil {
		t.Errorf("esc should not emit a command, got %v", cmd())
	}
	if p.IsOpen() {
		t.Error("esc should close the palette")
	}
}

func TestPalette_NoMatchesPlaceholder(t *testing.T) {
	p := NewPalette(nil)
	p, _ = p.Open()
	// "mnopq" — none of the leading letters are single-letter shortcuts
	// (shortcut set: A W R F L T P D H U E G X Q I K J Z), so the keys
	// flow into the filter. The sequence then matches nothing.
	for _, r := range "mnopq" {
		p, _ = p.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
	}
	out := p.SetWidth(60).View()
	if !strings.Contains(out, "no matching commands") {
		t.Errorf("expected 'no matching commands' placeholder, got %q", out)
	}
}
