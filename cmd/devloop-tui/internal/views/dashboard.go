// Package views contains the top-level Bubble Tea models for devloop-tui.
package views

import (
	"context"
	"fmt"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/shaifulshabuj/devloop/devloop-tui/internal/components"
	"github.com/shaifulshabuj/devloop/devloop-tui/internal/stream"
)

// ─── Message types ────────────────────────────────────────────────────────────

// sessionsLoadedMsg carries a fresh scan result into the Update loop.
type sessionsLoadedMsg struct {
	sessions []stream.Session
	err      error
}

// streamEventMsg carries one Event from the NDJSON tailer.
type streamEventMsg struct{ event stream.Event }

// streamErrMsg carries a non-fatal tailer error (logged in status bar).
type streamErrMsg struct{ err error }

// tickMsg is emitted every 100 ms to advance the spinner.
type tickMsg struct{}

// ─── Options ──────────────────────────────────────────────────────────────────

// DashboardOptions configures DashboardModel construction.
// The zero value is valid and starts a fully live dashboard.
type DashboardOptions struct {
	// NoStream disables the NDJSON tailer goroutine. Used in tests so that
	// no fsnotify watcher is created and the model is safe to drive manually.
	NoStream bool
}

// ─── Model ────────────────────────────────────────────────────────────────────

// DashboardModel is the split-layout view that owns:
//   - A picker (left pane, ≈30% width)
//   - An active session detail (right pane, ≈70% width)
//   - An optional subscription to the NDJSON tail stream for live refresh
type DashboardModel struct {
	projectRoot string
	opts        DashboardOptions

	picker   components.Picker
	sessions []stream.Session
	active   *stream.Session // highlighted session; nil when list empty

	spinnerTick int
	width       int
	height      int

	err      error // last non-fatal error shown in status bar
	eventsCh <-chan stream.Event
	errsCh   <-chan error
	cancel   context.CancelFunc
}

// NewDashboard constructs a live dashboard. See NewDashboardWithOptions for
// test-friendly construction.
func NewDashboard(projectRoot string) DashboardModel {
	return NewDashboardWithOptions(projectRoot, DashboardOptions{})
}

// NewDashboardWithOptions constructs a DashboardModel with explicit options.
// When opts.NoStream is true, no NDJSON tailer goroutine is started, which is
// safe in unit tests that drive the model entirely via Update() calls.
func NewDashboardWithOptions(projectRoot string, opts DashboardOptions) DashboardModel {
	return DashboardModel{
		projectRoot: projectRoot,
		opts:        opts,
		picker:      components.NewPicker(nil),
	}
}

// ─── Init ─────────────────────────────────────────────────────────────────────

// Init starts the NDJSON tailer (unless NoStream), kicks the 100 ms ticker, and
// emits an initial Scan() result.
func (m DashboardModel) Init() tea.Cmd {
	cmds := []tea.Cmd{
		m.scanCmd(),
		m.tickCmd(),
	}

	if !m.opts.NoStream {
		tailPath := filepath.Join(m.projectRoot, ".devloop", "pipeline.log")
		tailer := &stream.Tailer{Path: tailPath}
		ctx, cancel := context.WithCancel(context.Background())
		m.cancel = cancel

		eventsCh, errsCh, err := tailer.Run(ctx)
		if err == nil {
			m.eventsCh = eventsCh
			m.errsCh = errsCh
			cmds = append(cmds, waitForEvent(eventsCh), waitForErr(errsCh))
		}
		// If the tailer fails to start (e.g., fsnotify unavailable) we silently
		// continue in read-only scan mode — the r key still allows manual refresh.
	}

	return tea.Batch(cmds...)
}

// ─── Update ───────────────────────────────────────────────────────────────────

func (m DashboardModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmds []tea.Cmd

	switch msg := msg.(type) {

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		m = m.resizePanes()

	case tickMsg:
		m.spinnerTick++
		cmds = append(cmds, m.tickCmd())

	case sessionsLoadedMsg:
		if msg.err != nil {
			m.err = msg.err
		} else {
			m.err = nil
			m = m.applySessions(msg.sessions)
		}

	case streamEventMsg:
		m = m.applyStreamEvent(msg.event)
		// Re-arm the listener for the next event.
		if m.eventsCh != nil {
			cmds = append(cmds, waitForEvent(m.eventsCh))
		}

	case streamErrMsg:
		m.err = msg.err
		if m.errsCh != nil {
			cmds = append(cmds, waitForErr(m.errsCh))
		}

	case tea.KeyMsg:
		switch {
		case key.Matches(msg, keyQuit):
			if m.cancel != nil {
				m.cancel()
			}
			return m, tea.Quit

		case key.Matches(msg, keyRefresh):
			cmds = append(cmds, m.scanCmd())

		default:
			// Delegate all other keys (navigation, filter) to the picker.
			var pickerCmd tea.Cmd
			m.picker, pickerCmd = m.picker.Update(msg)
			cmds = append(cmds, pickerCmd)
			m = m.syncActive()
		}
	}

	return m, tea.Batch(cmds...)
}

// ─── View ─────────────────────────────────────────────────────────────────────

func (m DashboardModel) View() string {
	w := m.width
	if w <= 0 {
		w = 120
	}
	h := m.height
	if h <= 0 {
		h = 30
	}

	leftW, rightW := splitWidth(w)
	bodyH := h - 2 // subtract header + footer lines

	header := m.renderHeader(w)
	footer := m.renderFooter(w)

	left := m.renderLeft(leftW, bodyH)
	right := m.renderRight(rightW, bodyH)
	body := lipgloss.JoinHorizontal(lipgloss.Top, left, right)

	return lipgloss.JoinVertical(lipgloss.Left, header, body, footer)
}

// ─── Rendering helpers ────────────────────────────────────────────────────────

func (m DashboardModel) renderHeader(w int) string {
	total := len(m.sessions)
	active := 0
	for _, s := range m.sessions {
		if s.Status == "running" {
			active++
		}
	}

	title := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("205")).Render("DevLoop")

	info := lipgloss.NewStyle().Faint(true).Render(
		fmt.Sprintf("·  %d session%s  ·  %d active", total, plural(total), active),
	)

	var status string
	if m.err != nil {
		status = lipgloss.NewStyle().Foreground(lipgloss.Color("196")).Render(
			"  ⚠ " + m.err.Error(),
		)
	}

	content := title + "  " + info + status
	return lipgloss.NewStyle().
		Width(w).
		BorderStyle(lipgloss.NormalBorder()).
		BorderBottom(true).
		BorderForeground(lipgloss.Color("240")).
		Render(content)
}

func (m DashboardModel) renderFooter(w int) string {
	hints := "↑/↓ move  ·  / filter  ·  enter view  ·  r refresh  ·  q quit"
	return lipgloss.NewStyle().
		Width(w).
		Faint(true).
		Foreground(lipgloss.Color("240")).
		Render(hints)
}

func (m DashboardModel) renderLeft(w, h int) string {
	p := m.picker.SetSize(w, h)
	return lipgloss.NewStyle().Width(w).Height(h).Render(p.View())
}

func (m DashboardModel) renderRight(w, h int) string {
	divider := lipgloss.NewStyle().Foreground(lipgloss.Color("240")).Render("│")

	var content string
	if m.active == nil {
		content = lipgloss.NewStyle().Faint(true).Render(
			"no session selected — start one with `devloop run …`",
		)
	} else {
		content = m.renderSessionDetail(m.active, w-2) // -2 for divider + space
	}

	pane := lipgloss.NewStyle().
		Width(w - 1). // leave 1 col for divider
		Height(h).
		PaddingLeft(1).
		Render(content)

	return lipgloss.JoinHorizontal(lipgloss.Top, divider, pane)
}

func (m DashboardModel) renderSessionDetail(s *stream.Session, w int) string {
	bold := lipgloss.NewStyle().Bold(true)
	dim := lipgloss.NewStyle().Faint(true)

	var lines []string

	lines = append(lines, bold.Render("Task:   ")+s.ID)
	lines = append(lines, bold.Render("Feature:")+"  "+wordWrap(s.Feature, w-10))
	lines = append(lines, bold.Render("Status: ")+colorStatus(s.Status))

	lines = append(lines, "")
	lines = append(lines, bold.Render("Phases:"))

	phases := buildPhases(s)
	grid := components.Render(phases, components.GridOptions{
		Width:       w - 2,
		Compact:     false,
		SpinnerTick: m.spinnerTick,
	})
	// Indent each grid line by 2 spaces.
	for _, gl := range strings.Split(grid, "\n") {
		lines = append(lines, "  "+gl)
	}

	lines = append(lines, "")

	if !s.StartedAt.IsZero() {
		lines = append(lines, dim.Render("Started:  ")+s.StartedAt.Format("02 Jan 15:04"))
	}
	if !s.FinishedAt.IsZero() {
		dur := s.FinishedAt.Sub(s.StartedAt)
		lines = append(lines,
			dim.Render("Finished: ")+s.FinishedAt.Format("02 Jan 15:04")+
				dim.Render(fmt.Sprintf("  (duration: %dm %ds)",
					int(dur.Minutes()), int(dur.Seconds())%60)),
		)
	}

	return strings.Join(lines, "\n")
}

// ─── Key bindings ─────────────────────────────────────────────────────────────

var (
	keyQuit = key.NewBinding(
		key.WithKeys("q", "ctrl+c", "esc"),
	)
	keyRefresh = key.NewBinding(
		key.WithKeys("r"),
	)
)

// ─── Commands ─────────────────────────────────────────────────────────────────

func (m DashboardModel) scanCmd() tea.Cmd {
	root := m.projectRoot
	return func() tea.Msg {
		sessions, err := stream.Scan(root)
		return sessionsLoadedMsg{sessions: sessions, err: err}
	}
}

func (m DashboardModel) tickCmd() tea.Cmd {
	return tea.Tick(100*time.Millisecond, func(time.Time) tea.Msg {
		return tickMsg{}
	})
}

// waitForEvent returns a Cmd that blocks until one Event arrives on ch, then
// returns it as a streamEventMsg. If the channel is closed it returns nil.
func waitForEvent(ch <-chan stream.Event) tea.Cmd {
	return func() tea.Msg {
		ev, ok := <-ch
		if !ok {
			return nil
		}
		return streamEventMsg{event: ev}
	}
}

// waitForErr returns a Cmd that blocks until one error arrives on ch.
func waitForErr(ch <-chan error) tea.Cmd {
	return func() tea.Msg {
		err, ok := <-ch
		if !ok {
			return nil
		}
		return streamErrMsg{err: err}
	}
}

// ─── State helpers ────────────────────────────────────────────────────────────

// applySessions replaces m.sessions, rebuilds the picker items, and preserves
// the current selection by ID (falls back to first).
func (m DashboardModel) applySessions(sessions []stream.Session) DashboardModel {
	// Remember the currently selected ID so we can restore it.
	var selectedID string
	if item, ok := m.picker.Selected(); ok {
		selectedID = item.ID
	}

	m.sessions = sessions
	items := make([]components.Item, len(sessions))
	for i, s := range sessions {
		items[i] = sessionToItem(s)
	}
	m.picker = m.picker.SetItems(items)

	// Try to restore previous selection.
	if selectedID != "" {
		for _, s := range sessions {
			if s.ID == selectedID {
				// The picker's bubbles/list doesn't expose a "select by ID" API,
				// so we rely on the list order matching sessions order and accept
				// that the highlight may reset to 0 after filter changes.
				break
			}
		}
	}

	return m.syncActive()
}

// applyStreamEvent mutates the in-memory session list for phase events, or
// triggers a re-scan for session start/end events.
func (m DashboardModel) applyStreamEvent(ev stream.Event) DashboardModel {
	switch ev.Kind {
	case "session.start", "session.end":
		// Re-scan from disk to get accurate session state.
		// We return a command via the outer Update; here we just trigger it
		// by re-using scanCmd inline — but we can't return a Cmd from a helper.
		// Instead, we store a flag-like approach: we mark err as nil and let
		// the re-scan happen through the returned cmds in Update.
		// The simplest approach: we just patch the sessions slice by re-scanning
		// synchronously here (acceptable since it's a quick disk read).
		sessions, err := stream.Scan(m.projectRoot)
		if err == nil {
			m = m.applySessions(sessions)
		}

	case "phase.start":
		m = m.patchPhaseState(ev.Session, ev.Phase, stream.PhaseState{
			Status: "running",
			Time:   ev.TS,
		})

	case "phase.end":
		status := ev.Status
		if status == "" {
			status = "done"
		}
		m = m.patchPhaseState(ev.Session, ev.Phase, stream.PhaseState{
			Status: status,
			Time:   ev.TS,
		})
	}

	return m
}

// patchPhaseState updates a phase in the matching session in m.sessions.
func (m DashboardModel) patchPhaseState(sessionID, phase string, ps stream.PhaseState) DashboardModel {
	for i, s := range m.sessions {
		if s.ID == sessionID {
			if m.sessions[i].PhaseStates == nil {
				m.sessions[i].PhaseStates = make(map[string]stream.PhaseState)
			}
			m.sessions[i].PhaseStates[phase] = ps
			// Refresh active pointer if this is the active session.
			if m.active != nil && m.active.ID == sessionID {
				m.active = &m.sessions[i]
			}
			return m
		}
	}
	return m
}

// syncActive aligns m.active with the picker's current selection.
func (m DashboardModel) syncActive() DashboardModel {
	item, ok := m.picker.Selected()
	if !ok {
		m.active = nil
		return m
	}
	for i := range m.sessions {
		if m.sessions[i].ID == item.ID {
			m.active = &m.sessions[i]
			return m
		}
	}
	m.active = nil
	return m
}

// resizePanes updates the picker geometry after a window resize.
func (m DashboardModel) resizePanes() DashboardModel {
	leftW, _ := splitWidth(m.width)
	bodyH := m.height - 2
	if bodyH < 1 {
		bodyH = 1
	}
	m.picker = m.picker.SetSize(leftW, bodyH)
	return m
}

// ─── Conversion helpers ───────────────────────────────────────────────────────

// sessionToItem converts a Session to a picker Item.
func sessionToItem(s stream.Session) components.Item {
	badge := statusBadge(s.Status)
	rel := humanizeRel(s.StartedAt)
	sub := badge + "  " + rel
	return components.Item{
		ID:       s.ID,
		Title:    s.Feature,
		Subtitle: sub,
	}
}

// statusBadge returns a short glyph + word for the session status.
func statusBadge(status string) string {
	switch status {
	case "running":
		return "⠙ running"
	case "done", "approved":
		return "✓ done"
	case "failed", "rejected":
		return "✗ failed"
	case "needs-work":
		return "⚑ needs-work"
	case "skipped":
		return "→ skipped"
	default:
		if status == "" {
			return "· pending"
		}
		return "· " + status
	}
}

// humanizeRel returns a human-friendly relative time string for display in the
// picker subtitle. The zero time returns "".
func humanizeRel(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	d := time.Since(t)
	if d < 0 {
		d = -d
	}
	switch {
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		mins := int(d.Minutes())
		return fmt.Sprintf("%dm ago", mins)
	case d < 24*time.Hour:
		hrs := int(d.Hours())
		return fmt.Sprintf("%dh ago", hrs)
	default:
		days := int(d.Hours() / 24)
		return fmt.Sprintf("%dd ago", days)
	}
}

// buildPhases converts a Session's PhaseStates into an ordered []Phase for
// pipeline_grid.Render. Order: architect, worker, reviewer, fix-1, fix-2, …
func buildPhases(s *stream.Session) []components.Phase {
	canonicalOrder := []string{"architect", "worker", "reviewer"}

	// Collect fix-N keys.
	var fixKeys []string
	for k := range s.PhaseStates {
		if strings.HasPrefix(k, "fix-") {
			fixKeys = append(fixKeys, k)
		}
	}
	sort.Slice(fixKeys, func(i, j int) bool {
		ni := fixNum(fixKeys[i])
		nj := fixNum(fixKeys[j])
		return ni < nj
	})

	allKeys := append(canonicalOrder, fixKeys...)

	var phases []components.Phase
	for _, name := range allKeys {
		ps, exists := s.PhaseStates[name]
		var status components.PhaseStatus
		if !exists {
			status = components.PhasePending
		} else {
			status = mapPhaseStatus(ps.Status)
		}
		phases = append(phases, components.Phase{
			Name:   name,
			Status: status,
		})
	}
	return phases
}

// mapPhaseStatus converts a PhaseState.Status string to a PhaseStatus constant.
func mapPhaseStatus(s string) components.PhaseStatus {
	switch s {
	case "running":
		return components.PhaseRunning
	case "done", "approved":
		return components.PhaseDone
	case "failed", "rejected":
		return components.PhaseFailed
	case "skipped":
		return components.PhaseSkipped
	default:
		return components.PhasePending
	}
}

// fixNum extracts the integer suffix from a "fix-N" string.
func fixNum(k string) int {
	s := strings.TrimPrefix(k, "fix-")
	n, _ := strconv.Atoi(s)
	return n
}

// colorStatus returns an ANSI-styled status string.
func colorStatus(status string) string {
	var style lipgloss.Style
	switch status {
	case "done", "approved":
		style = lipgloss.NewStyle().Foreground(lipgloss.Color("82"))
	case "running":
		style = lipgloss.NewStyle().Foreground(lipgloss.Color("220"))
	case "failed", "rejected":
		style = lipgloss.NewStyle().Foreground(lipgloss.Color("196"))
	default:
		style = lipgloss.NewStyle().Faint(true)
	}
	return style.Render(status)
}

// splitWidth returns (leftWidth, rightWidth) for the split layout.
// Left pane is fixed at min(34, 30% of total).
func splitWidth(total int) (int, int) {
	leftW := total * 30 / 100
	if leftW < 20 {
		leftW = 20
	}
	if leftW > 34 {
		leftW = 34
	}
	if leftW >= total {
		leftW = total / 2
	}
	rightW := total - leftW
	return leftW, rightW
}

// plural returns "s" when n != 1.
func plural(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}

// wordWrap wraps text to width characters (naïve, space-split).
// Returns the first line only for simplicity — the detail pane is narrow.
func wordWrap(text string, width int) string {
	if width <= 0 || len(text) <= width {
		return text
	}
	// Return just the first wrapped line with an ellipsis.
	return text[:width-1] + "…"
}
