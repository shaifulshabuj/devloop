// Package theme defines the shared color tokens and style helpers for devloop-tui.
// All views and components must import this package instead of hardcoding colors.
package theme

import "github.com/charmbracelet/lipgloss"

// ── Color tokens ──────────────────────────────────────────────────────────────

var (
	// Backgrounds
	Bg       = lipgloss.Color("#0d1117")
	Surface  = lipgloss.Color("#161b22")
	Surface2 = lipgloss.Color("#1c2128")

	// Borders & text
	Border = lipgloss.Color("#30363d")
	Text   = lipgloss.Color("#c9d1d9")
	Dim    = lipgloss.Color("#6e7681")

	// Semantic status colors
	Green  = lipgloss.Color("#3fb950") // done / ok / approved
	Yellow = lipgloss.Color("#e3b341") // running / warning / needs-work / quiet
	Red    = lipgloss.Color("#f85149") // failed / rejected / error / timed-out
	Blue   = lipgloss.Color("#58a6ff") // selected / active / info / re-arch
	Purple = lipgloss.Color("#bc8cff") // brand / logo / selection accent
)

// ── Semantic helpers ──────────────────────────────────────────────────────────

// StatusColor returns the appropriate color for a phase or session status string.
func StatusColor(status string) lipgloss.Color {
	switch status {
	case "done", "approved":
		return Green
	case "running":
		return Yellow
	case "failed", "rejected":
		return Red
	case "needs-work":
		return Yellow
	default:
		return Dim
	}
}

// StatusIcon returns a single-glyph icon for a status string.
func StatusIcon(status string) string {
	switch status {
	case "done", "approved":
		return "✓"
	case "running":
		return "⠙"
	case "failed", "rejected":
		return "✗"
	case "needs-work":
		return "⚑"
	case "skipped":
		return "→"
	default:
		return "·"
	}
}

// SpinnerFrames is the braille spinner sequence for running phases.
// Advance by (spinnerTick % len(SpinnerFrames)).
var SpinnerFrames = []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

// ── Common styles ──────────────────────────────────────────────────────────────

var (
	// Brand logo: bold purple
	StyleLogo = lipgloss.NewStyle().Bold(true).Foreground(Purple)

	// Section label: dim, uppercase — caller supplies the upper-case content
	StyleSectionLabel = lipgloss.NewStyle().Foreground(Dim)

	// Task feature title: bold
	StyleFeatureTitle = lipgloss.NewStyle().Bold(true).Foreground(Text)

	// Dim metadata (timestamps, IDs)
	StyleMeta = lipgloss.NewStyle().Foreground(Dim)

	// Log output line (subprocess output)
	StyleLogLine = lipgloss.NewStyle().Foreground(Dim).PaddingLeft(2)

	// Footer hint bar
	StyleFooter = lipgloss.NewStyle().Foreground(Dim)

	// Keyboard shortcut key badge
	StyleKBD = lipgloss.NewStyle().
			Background(Surface2).
			Foreground(Dim).
			Border(lipgloss.RoundedBorder()).
			BorderForeground(lipgloss.Color("#484f58")).
			Padding(0, 1)

	// Top bar / bottom bar background
	StyleBar = lipgloss.NewStyle().Background(Surface)

	// Divider line
	StyleDivider = lipgloss.NewStyle().Foreground(Border)

	// Selected item in task list
	StyleSelected = lipgloss.NewStyle().
			Background(lipgloss.Color("#0d2244")).
			Foreground(Text)

	// Active tab label
	StyleTabActive = lipgloss.NewStyle().
			Foreground(Text).
			Border(lipgloss.Border{Bottom: "─"}, false, false, true, false).
			BorderForeground(Blue)

	// Inactive tab label
	StyleTabInactive = lipgloss.NewStyle().Foreground(Dim)

	// Collapsible panel header
	StylePanelHeader = lipgloss.NewStyle().
				Foreground(Dim).
				Border(lipgloss.RoundedBorder()).
				BorderForeground(Border).
				Padding(0, 2)

	// Command palette container
	StylePalette = lipgloss.NewStyle().
			Background(Surface2).
			Border(lipgloss.RoundedBorder()).
			BorderForeground(Blue).
			Width(40).
			Padding(0, 1)

	// Palette selected action
	StylePaletteSelected = lipgloss.NewStyle().
				Background(lipgloss.Color("#0d2244")).
				Foreground(Text)

	// Phase box (pipeline track card) base
	StylePhaseBox = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(Border).
			Padding(0, 2).
			Align(lipgloss.Center)

	StylePhaseBoxDone = StylePhaseBox.
				BorderForeground(Green).
				Background(lipgloss.Color("#051b0d"))

	StylePhaseBoxRunning = StylePhaseBox.
				BorderForeground(Yellow).
				Background(lipgloss.Color("#1a1200"))

	StylePhaseBoxPending = StylePhaseBox.
				Foreground(Dim)

	StylePhaseBoxFailed = StylePhaseBox.
				BorderForeground(Red).
				Background(lipgloss.Color("#1a0000"))

	StylePhaseBoxSkipped = StylePhaseBox.
				Foreground(Blue).
				BorderForeground(Blue)

	// Phase 4 additions — Quiet / Stuck (gate-timeout) / Re-architecting.
	//
	// Wording is "quiet" not "stuck" for the no-output case: a worker
	// doing a large refactor can legitimately run > 10 min, "quiet"
	// communicates "hasn't produced output recently" without implying
	// failure. "Stuck" is reserved for the genuinely-blocked
	// gate-timeout case where action is required.

	StylePhaseBoxQuiet = StylePhaseBox.
				BorderForeground(Yellow).
				Background(lipgloss.Color("#1a1000"))

	StylePhaseBoxStuck = StylePhaseBox.
				BorderForeground(Red).
				Background(lipgloss.Color("#1a0000"))

	StylePhaseBoxReArch = StylePhaseBox.
				BorderForeground(Blue).
				Background(lipgloss.Color("#00051a"))

	// Error / warning messages
	StyleError   = lipgloss.NewStyle().Foreground(Red)
	StyleWarning = lipgloss.NewStyle().Foreground(Yellow)
	StyleSuccess = lipgloss.NewStyle().Foreground(Green)
)
