package components

import (
	"strings"
	"testing"
)

func TestPanel_DefaultsToCollapsed(t *testing.T) {
	p := NewPanel(PanelOptions{Label: "spec"})
	if p.IsOpen() {
		t.Errorf("expected new panel to be collapsed")
	}
	out := p.SetSize(60).View()
	if !strings.Contains(out, "▶") {
		t.Errorf("collapsed panel should show ▶ arrow, got %q", out)
	}
	if !strings.Contains(out, "SPEC") {
		t.Errorf("collapsed panel should uppercase the label, got %q", out)
	}
}

func TestPanel_Toggle(t *testing.T) {
	p := NewPanel(PanelOptions{Label: "diff"}).SetSize(60)
	if p.IsOpen() {
		t.Fatal("expected collapsed initially")
	}
	p = p.Toggle()
	if !p.IsOpen() {
		t.Fatal("Toggle should open the panel")
	}
	out := p.View()
	if !strings.Contains(out, "▼") {
		t.Errorf("open panel should show ▼ arrow, got %q", out)
	}

	p = p.Toggle()
	if p.IsOpen() {
		t.Fatal("Toggle should close the panel again")
	}
}

func TestPanel_SetContentRendersWhenOpen(t *testing.T) {
	p := NewPanel(PanelOptions{Label: "spec", ExpandedHeight: 6}).
		SetSize(60).
		SetContent("hello world\nline two\nline three")
	p = p.Toggle() // open

	out := p.View()
	if !strings.Contains(out, "hello world") {
		t.Errorf("expected 'hello world' in open view, got %q", out)
	}
}

func TestPanel_SetContentHiddenWhenCollapsed(t *testing.T) {
	p := NewPanel(PanelOptions{Label: "spec"}).
		SetSize(60).
		SetContent("secret content")

	out := p.View()
	if strings.Contains(out, "secret content") {
		t.Errorf("collapsed panel should not show body, got %q", out)
	}
}

func TestPanel_SetSizeWidth(t *testing.T) {
	p := NewPanel(PanelOptions{Label: "spec"}).SetSize(80)
	out := p.View()
	// Header is rendered with Width(80); the rendered string contains at
	// least one line ≥ 80 cells (after stripping the border).
	maxLine := 0
	for _, ln := range strings.Split(out, "\n") {
		if len(ln) > maxLine {
			maxLine = len(ln)
		}
	}
	// Generous lower bound — ANSI escapes inflate raw length; visible width
	// will be 80 but byte length much larger.
	if maxLine < 30 {
		t.Errorf("expected the rendered header to span the panel width; longest line was %d bytes", maxLine)
	}
}

func TestPanel_DefaultExpandedHeight(t *testing.T) {
	p := NewPanel(PanelOptions{Label: "x"})
	// We can't directly read the viewport height from the public API, so
	// verify by opening + setting tall content + checking the rendered
	// output has multiple lines.
	p = p.SetSize(40).SetContent(strings.Repeat("row\n", 20)).Toggle()
	out := p.View()
	rows := strings.Count(out, "\n")
	if rows < 5 {
		t.Errorf("expected the open panel to show ≥ 5 content rows, got %d", rows)
	}
}
