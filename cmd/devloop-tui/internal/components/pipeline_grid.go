// Package components provides pure UI primitives for the devloop-tui dashboard.
package components

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
)

// PhaseStatus represents the execution state of a pipeline phase.
type PhaseStatus int

const (
	PhasePending PhaseStatus = iota // not started
	PhaseRunning                    // active now
	PhaseDone                       // completed successfully
	PhaseFailed                     // failed
	PhaseSkipped                    // skipped via gate / user
)

// Phase is one step in the devloop pipeline (architect, worker, reviewer, fix-N, …).
type Phase struct {
	Name     string        // "architect" | "worker" | "reviewer" | "fix-1" | etc.
	Status   PhaseStatus
	Duration time.Duration // 0 if unknown
}

// GridOptions controls how Render lays out the phase badges.
type GridOptions struct {
	Width       int  // total render width in cells; 0 means natural width
	Compact     bool // single-line ultra-compact vs multi-line
	SpinnerTick int  // animation frame counter for running phases (caller increments)
}

// spinnerFrames is a braille spinner cycle.
var spinnerFrames = []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

// Lipgloss styles — computed once at package init.
var (
	stylePending = lipgloss.NewStyle().Faint(true).Foreground(lipgloss.Color("240"))
	styleRunning = lipgloss.NewStyle().Foreground(lipgloss.Color("220")) // yellow
	styleDone    = lipgloss.NewStyle().Foreground(lipgloss.Color("82"))  // green
	styleFailed  = lipgloss.NewStyle().Foreground(lipgloss.Color("196")) // red
	styleSkipped = lipgloss.NewStyle().Faint(true).Foreground(lipgloss.Color("39")) // blue/dim
)

// glyph returns the status indicator character for a phase.
func glyph(status PhaseStatus, tick int) string {
	switch status {
	case PhasePending:
		return "·"
	case PhaseRunning:
		return spinnerFrames[tick%len(spinnerFrames)]
	case PhaseDone:
		return "✓"
	case PhaseFailed:
		return "✗"
	case PhaseSkipped:
		return "→"
	}
	return "?"
}

// style returns the Lipgloss style appropriate for a given status.
func statusStyle(status PhaseStatus) lipgloss.Style {
	switch status {
	case PhasePending:
		return stylePending
	case PhaseRunning:
		return styleRunning
	case PhaseDone:
		return styleDone
	case PhaseFailed:
		return styleFailed
	case PhaseSkipped:
		return styleSkipped
	}
	return lipgloss.NewStyle()
}

// formatDuration formats a duration for display in a phase badge.
// 0 → ""; <1m → "Xs"; <1h → "Xm Ys"; else "Xh Ym".
func formatDuration(d time.Duration) string {
	if d <= 0 {
		return ""
	}
	h := int(d.Hours())
	m := int(d.Minutes()) % 60
	s := int(d.Seconds()) % 60
	if h > 0 {
		return fmt.Sprintf("%dh %dm", h, m)
	}
	if m > 0 {
		return fmt.Sprintf("%dm %ds", m, s)
	}
	return fmt.Sprintf("%ds", s)
}

// Render returns an ANSI-coloured string representing the pipeline phase states.
//
// Non-compact layout: one line per phase — badge glyph + name + duration.
// Compact layout: single line "[name glyph dur] [name glyph dur] …".
//
// When opts.Width > 0, the output is padded/truncated to that width.
// An empty phases slice returns "".
func Render(phases []Phase, opts GridOptions) string {
	if len(phases) == 0 {
		return ""
	}

	if opts.Compact {
		return renderCompact(phases, opts)
	}
	return renderMultiLine(phases, opts)
}

func renderCompact(phases []Phase, opts GridOptions) string {
	var parts []string
	for _, p := range phases {
		st := statusStyle(p.Status)
		g := glyph(p.Status, opts.SpinnerTick)
		dur := formatDuration(p.Duration)

		var inner string
		if dur != "" {
			inner = fmt.Sprintf("%s %s %s", p.Name, g, dur)
		} else {
			inner = fmt.Sprintf("%s %s", p.Name, g)
		}
		parts = append(parts, "["+st.Render(inner)+"]")
	}
	line := strings.Join(parts, " ")
	if opts.Width > 0 {
		line = lipgloss.NewStyle().Width(opts.Width).Render(line)
	}
	return line
}

func renderMultiLine(phases []Phase, opts GridOptions) string {
	var lines []string
	for _, p := range phases {
		st := statusStyle(p.Status)
		g := glyph(p.Status, opts.SpinnerTick)
		dur := formatDuration(p.Duration)

		badge := st.Render(g)
		var line string
		if dur != "" {
			line = fmt.Sprintf("%s %-12s %s", badge, p.Name, st.Render(dur))
		} else {
			line = fmt.Sprintf("%s %s", badge, p.Name)
		}
		if opts.Width > 0 {
			line = lipgloss.NewStyle().Width(opts.Width).Render(line)
		}
		lines = append(lines, line)
	}
	return strings.Join(lines, "\n")
}
