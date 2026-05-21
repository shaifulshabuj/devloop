package components

// Panel is a collapsible viewport-backed pane used by the dashboard for SPEC
// and DIFF sections (P1-8 / P1-9) and by Focus Mode for the same content.
//
// Visual states:
//
//	Collapsed:   ▶ SPEC                                            expand
//	Expanded:    ▼ SPEC                                            collapse
//	             <viewport scrolling the content>
//
// The component owns no key handling itself — the parent decides which key
// toggles which panel. Forwarding tea.Msg to Update routes scroll keys to
// the underlying viewport only when expanded.

import (
	"strings"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/shaifulshabuj/devloop/devloop-tui/internal/theme"
)

// PanelOptions configures a Panel at construction time.
type PanelOptions struct {
	// Label appears in the header (e.g. "SPEC", "DIFF", "PERMIT").
	Label string
	// ExpandedHeight is the viewport height when the panel is open.
	// Defaults to 10 lines if <= 0.
	ExpandedHeight int
}

// Panel is a single collapsible content pane.
type Panel struct {
	label      string
	open       bool
	width      int
	height     int
	vp         viewport.Model
	hasContent bool // true once SetContent was called at least once
}

// NewPanel constructs a Panel with the given label. ExpandedHeight defaults
// to 10 rows when zero.
func NewPanel(opts PanelOptions) Panel {
	h := opts.ExpandedHeight
	if h <= 0 {
		h = 10
	}
	return Panel{
		label:  strings.ToUpper(opts.Label),
		height: h,
		vp:     viewport.New(0, h),
	}
}

// IsOpen reports the current expanded/collapsed state.
func (p Panel) IsOpen() bool { return p.open }

// Toggle flips between expanded and collapsed.
func (p Panel) Toggle() Panel { p.open = !p.open; return p }

// SetOpen forces a state (idempotent).
func (p Panel) SetOpen(open bool) Panel { p.open = open; return p }

// SetContent replaces the body text shown in the viewport. Scroll position
// is reset to the top.
func (p Panel) SetContent(content string) Panel {
	p.vp.SetContent(content)
	p.vp.GotoTop()
	p.hasContent = true
	return p
}

// SetSize lets the parent control the panel's width. Height stays fixed at
// the ExpandedHeight from construction.
func (p Panel) SetSize(width int) Panel {
	p.width = width
	if width > 0 {
		p.vp.Width = width
	}
	return p
}

// Update forwards scroll/navigation keys to the viewport — but only when the
// panel is open. The toggle key itself is the parent's responsibility.
func (p Panel) Update(msg tea.Msg) (Panel, tea.Cmd) {
	if !p.open {
		return p, nil
	}
	var cmd tea.Cmd
	p.vp, cmd = p.vp.Update(msg)
	return p, cmd
}

// View renders the panel. Width is taken from SetSize; height is one line
// for the collapsed header, or header + ExpandedHeight for the open form.
func (p Panel) View() string {
	w := p.width
	if w <= 0 {
		w = 40
	}

	header := p.renderHeader(w)
	if !p.open {
		return header
	}
	return lipgloss.JoinVertical(lipgloss.Left, header, p.vp.View())
}

func (p Panel) renderHeader(w int) string {
	arrow := "▶"
	hint := "expand"
	if p.open {
		arrow = "▼"
		hint = "collapse"
	}

	left := arrow + "  " + p.label
	right := hint
	if !p.hasContent && !p.open {
		// Subtle nudge that opening will show something.
		right = "expand"
	}

	pad := w - lipgloss.Width(left) - lipgloss.Width(right) - 4 // 2 padding chars each side
	if pad < 1 {
		pad = 1
	}
	content := left + strings.Repeat(" ", pad) + right

	border := theme.Border
	if p.open {
		border = theme.Blue
	}
	return lipgloss.NewStyle().
		Width(w).
		Foreground(theme.Dim).
		Border(lipgloss.NormalBorder(), true, false, false, false).
		BorderForeground(border).
		Padding(0, 2).
		Render(content)
}
