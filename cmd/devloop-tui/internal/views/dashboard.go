// Package views contains the top-level Bubble Tea models for devloop-tui.
package views

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/shaifulshabuj/devloop/devloop-tui/internal/components"
	"github.com/shaifulshabuj/devloop/devloop-tui/internal/health"
	"github.com/shaifulshabuj/devloop/devloop-tui/internal/stream"
	"github.com/shaifulshabuj/devloop/devloop-tui/internal/theme"
	"github.com/shaifulshabuj/devloop/devloop-tui/internal/uimsg"
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

// diffLoadedMsg carries the result of an async git-diff invocation triggered
// by toggling the DIFF panel open. taskID identifies which task the diff
// belongs to so a delayed result can be discarded if the user moved on.
type diffLoadedMsg struct {
	taskID  string
	content string
	err     error
}

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

	// Cached provider-failover snapshot for the top bar; refreshed on a
	// slower cadence than the spinner (see refreshHealth + healthTicker).
	health           health.ProviderHealth
	daemonPID        int  // 0 if not running / pidfile missing
	daemonOK         bool // last kill -0 result
	daemonRestarts   int  // recent auto-restart count from daemon.log
	daemonMaxReached bool // true once "Max restarts (...) reached" line is logged

	// Collapsible SPEC panel — shows .devloop/specs/<TASK-ID>.md for the
	// currently active task. Toggled with the `s` key.
	specPanel        components.Panel
	specLoadedForID  string // the TASK-ID whose spec content is in the panel

	// Collapsible DIFF panel — shows `git diff <baseline>..HEAD` for the
	// currently active task. Baseline hash lives in
	// .devloop/specs/<TASK-ID>.pre-commit. Toggled with the `d` key.
	diffPanel       components.Panel
	diffLoadedForID string
	diffLoading     bool // a goroutine is currently producing diff output

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
		specPanel:   components.NewPanel(components.PanelOptions{Label: "SPEC", ExpandedHeight: 10}),
		diffPanel:   components.NewPanel(components.PanelOptions{Label: "DIFF", ExpandedHeight: 12}),
	}
}

// ─── Init ─────────────────────────────────────────────────────────────────────

// Init starts the NDJSON tailer (unless NoStream), kicks the 100 ms ticker, and
// emits an initial Scan() result.
func (m DashboardModel) Init() tea.Cmd {
	// Health snapshot is populated on the first tickMsg (Init can't mutate
	// the framework-held model, only spawn Cmds). The dashboard renders
	// healthy by default until the first refresh completes (~100 ms).
	cmds := []tea.Cmd{
		m.scanCmd(),
		m.tickCmd(),
	}

	if !m.opts.NoStream {
		tailPath := filepath.Join(m.projectRoot, ".devloop", "events.ndjson")
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
		// Refresh provider-health + daemon liveness on the first tick
		// and then every ~5 ticks (≈ 500 ms): cheap (one stat + small
		// file read) but not per-frame, which would dominate file I/O.
		if m.spinnerTick%5 == 0 {
			m = m.refreshHealth()
		}
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

	case diffLoadedMsg:
		m.diffLoading = false
		// Late results for a task the user has moved away from get
		// dropped — the panel content already reflects the current
		// active task (or is empty).
		if m.active != nil && msg.taskID == m.active.ID {
			m.diffPanel = m.diffPanel.SetContent(msg.content)
			m.diffLoadedForID = msg.taskID
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

		case msg.String() == "s" && !m.picker.FilterFocused():
			// Toggle the SPEC panel. Content is loaded lazily by
			// syncActive whenever the highlighted task changes, so the
			// first 's' press always has fresh content for the visible
			// task.
			m.specPanel = m.specPanel.Toggle()

		case msg.String() == "d" && !m.picker.FilterFocused():
			// Toggle the DIFF panel. On open, lazy-load via a goroutine
			// (git diff can be slow on large repos — never block the UI).
			m.diffPanel = m.diffPanel.Toggle()
			if m.diffPanel.IsOpen() && m.active != nil &&
				m.diffLoadedForID != m.active.ID && !m.diffLoading {
				m.diffPanel = m.diffPanel.SetContent("loading diff…")
				m.diffLoading = true
				cmds = append(cmds, m.dispatchDiffLoad(m.active.ID))
			}

		case m.specPanel.IsOpen() && !m.picker.FilterFocused() &&
			isScrollKey(msg.String()):
			// While the panel is open, scroll keys (↑/↓/pgup/pgdn) go to
			// the panel's viewport instead of the picker.
			var panelCmd tea.Cmd
			m.specPanel, panelCmd = m.specPanel.Update(msg)
			cmds = append(cmds, panelCmd)

		case m.diffPanel.IsOpen() && !m.picker.FilterFocused() &&
			isScrollKey(msg.String()):
			var panelCmd tea.Cmd
			m.diffPanel, panelCmd = m.diffPanel.Update(msg)
			cmds = append(cmds, panelCmd)

		case msg.String() == "enter" && !m.picker.FilterFocused() && len(m.sessions) > 0:
			// Enter on a highlighted task opens Focus Mode (Phase 2
			// wires the receiver). When the picker's filter input is
			// focused, enter still goes to the picker so it can confirm
			// the filter — picker handles that internally.
			idx := m.picker.SelectedIndex()
			if idx >= 0 && idx < len(m.sessions) {
				id := m.sessions[idx].ID
				cmds = append(cmds, func() tea.Msg {
					return uimsg.OpenFocus{SessionIdx: idx, SessionID: id}
				})
			}

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

	title := lipgloss.NewStyle().Bold(true).Foreground(theme.Purple).Render("DevLoop")

	info := lipgloss.NewStyle().Faint(true).Render(
		fmt.Sprintf("·  %d session%s  ·  %d active", total, plural(total), active),
	)

	var status string
	if m.err != nil {
		status = lipgloss.NewStyle().Foreground(theme.Red).Render(
			"  ⚠ " + m.err.Error(),
		)
	}

	left := title + "  " + info + status
	right := m.renderTopBar()

	// Right-justify the top bar within the available width.
	pad := w - lipgloss.Width(left) - lipgloss.Width(right)
	if pad < 1 {
		pad = 1
	}
	content := left + strings.Repeat(" ", pad) + right

	return lipgloss.NewStyle().
		Width(w).
		BorderStyle(lipgloss.NormalBorder()).
		BorderBottom(true).
		BorderForeground(theme.Dim).
		Render(content)
}

// renderTopBar formats the provider/daemon health chips:
//
//	main ✓  ·  worker ✓  ·  daemon ✓
//
// When a side is on a fallback provider the chip becomes
//
//	main ✗→copilot
//
// (i.e., the active fallback is named so the user knows what they're
// actually running). The daemon chip flips to red ✗ when the pidfile is
// stale or absent.
func (m DashboardModel) renderTopBar() string {
	parts := []string{
		formatHealthChip("main", m.health.Main),
		formatHealthChip("worker", m.health.Worker),
		formatDaemonChip(m.daemonOK, m.daemonRestarts, m.daemonMaxReached),
	}
	sep := lipgloss.NewStyle().Foreground(theme.Dim).Render(" · ")
	return strings.Join(parts, sep)
}

func formatHealthChip(label string, s health.State) string {
	if !s.Limited() {
		ok := lipgloss.NewStyle().Foreground(theme.Green).Render("✓")
		return label + " " + ok
	}
	mark := lipgloss.NewStyle().Foreground(theme.Yellow).Render("✗")
	fb := s.Override
	if fb == "" {
		fb = "fallback"
	}
	arrow := lipgloss.NewStyle().Foreground(theme.Dim).Render("→")
	name := lipgloss.NewStyle().Foreground(theme.Yellow).Render(fb)
	return label + " " + mark + arrow + name
}

// formatDaemonChip renders one of four daemon states:
//
//	daemon ✓                — running, 0 recent restarts (green)
//	daemon ✓ ×N             — running, N recent restarts (yellow)
//	daemon ⊘ ×N max         — exhausted max-restart budget (red)
//	daemon ✗                — not running (red)
func formatDaemonChip(running bool, restarts int, maxReached bool) string {
	switch {
	case !running:
		return "daemon " + lipgloss.NewStyle().Foreground(theme.Red).Render("✗")
	case maxReached:
		count := lipgloss.NewStyle().Foreground(theme.Red).Render(fmt.Sprintf("×%d max", restarts))
		mark := lipgloss.NewStyle().Foreground(theme.Red).Render("⊘")
		return "daemon " + mark + " " + count
	case restarts > 0:
		mark := lipgloss.NewStyle().Foreground(theme.Yellow).Render("✓")
		count := lipgloss.NewStyle().Foreground(theme.Yellow).Render(fmt.Sprintf("×%d", restarts))
		return "daemon " + mark + " " + count
	default:
		return "daemon " + lipgloss.NewStyle().Foreground(theme.Green).Render("✓")
	}
}

// refreshHealth re-reads provider-health.sh and re-checks the daemon pidfile
// + daemon.log. Cheap enough to call from the 100ms tick; if it ever becomes
// a hot path, gate behind a slower cadence.
func (m DashboardModel) refreshHealth() DashboardModel {
	m.health = health.Load(m.projectRoot)
	m.daemonPID, m.daemonOK = readDaemonPID(m.projectRoot)
	m.daemonRestarts, m.daemonMaxReached = readDaemonRestarts(m.projectRoot)
	return m
}

// isScrollKey identifies the keystrokes a viewport-backed panel needs.
// Kept narrow on purpose so navigation keys (j/k/up/down) still go to the
// picker by default; only the explicit scroll keys are routed to the panel.
func isScrollKey(s string) bool {
	switch s {
	case "pgup", "pgdown", "ctrl+u", "ctrl+d", "home", "end":
		return true
	}
	return false
}

// dispatchDiffLoad returns a tea.Cmd that runs `git diff <baseline>..HEAD`
// for the given task in a goroutine and emits diffLoadedMsg when done.
// Baseline hash comes from .devloop/specs/<TASK-ID>.pre-commit; when that
// file is absent, falls back to `git diff HEAD` (uncommitted changes).
func (m DashboardModel) dispatchDiffLoad(taskID string) tea.Cmd {
	root := m.projectRoot
	return func() tea.Msg {
		baselinePath := filepath.Join(root, ".devloop", "specs", taskID+".pre-commit")
		baseline := ""
		if b, err := os.ReadFile(baselinePath); err == nil {
			baseline = strings.TrimSpace(string(b))
		}

		args := []string{"-C", root, "--no-pager", "diff", "--no-color"}
		if baseline != "" {
			args = append(args, baseline+"..HEAD")
		} else {
			args = append(args, "HEAD")
		}
		out, err := exec.Command("git", args...).CombinedOutput()
		if err != nil {
			return diffLoadedMsg{
				taskID:  taskID,
				content: fmt.Sprintf("(git diff failed: %v)\n%s", err, out),
				err:     err,
			}
		}
		content := string(out)
		if strings.TrimSpace(content) == "" {
			if baseline == "" {
				content = "(no baseline recorded — run `devloop work` to capture one)"
			} else {
				content = fmt.Sprintf("(no diff vs baseline %s)", baseline[:min(len(baseline), 7)])
			}
		} else {
			content = colourisedDiff(content)
		}
		return diffLoadedMsg{taskID: taskID, content: content}
	}
}

// colourisedDiff wraps each +/- line of unified-diff output in lipgloss
// styles so the panel reads at a glance. Hunk headers (@@) get the dim
// accent. Everything else passes through unchanged.
func colourisedDiff(raw string) string {
	addStyle := lipgloss.NewStyle().Foreground(theme.Green)
	delStyle := lipgloss.NewStyle().Foreground(theme.Red)
	hunkStyle := lipgloss.NewStyle().Foreground(theme.Blue)

	var b strings.Builder
	for _, line := range strings.Split(raw, "\n") {
		switch {
		case strings.HasPrefix(line, "+++") || strings.HasPrefix(line, "---"):
			// File headers — leave plain so paths remain readable.
			b.WriteString(line)
		case strings.HasPrefix(line, "+"):
			b.WriteString(addStyle.Render(line))
		case strings.HasPrefix(line, "-"):
			b.WriteString(delStyle.Render(line))
		case strings.HasPrefix(line, "@@"):
			b.WriteString(hunkStyle.Render(line))
		default:
			b.WriteString(line)
		}
		b.WriteByte('\n')
	}
	return b.String()
}

// loadSpecContent reads .devloop/specs/<TASK-ID>.md and returns either the
// content or a friendly placeholder when the spec hasn't been written yet.
// Errors other than missing-file are surfaced verbatim so the user can
// see what's wrong.
func (m DashboardModel) loadSpecContent(taskID string) string {
	if taskID == "" {
		return "(no task selected — pick one in the list)"
	}
	path := filepath.Join(m.projectRoot, ".devloop", "specs", taskID+".md")
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Sprintf("(no spec yet for %s — run `devloop architect …`)", taskID)
		}
		return fmt.Sprintf("(error reading spec: %v)", err)
	}
	return string(b)
}

// readDaemonRestarts counts occurrences of the auto-restart marker emitted by
// devloop.sh inside the most recent 50 lines of daemon.log. The result is the
// "recent restart count" — not lifetime — which is what the top bar should
// surface: a daemon flapping right now is far more interesting than one that
// recovered 200 restarts ago. The second return is true once any
// "Max restarts (...) reached" line has been logged, signalling the daemon
// gave up.
func readDaemonRestarts(projectRoot string) (int, bool) {
	const tailLines = 50
	const restartMarker = "Restarting in"
	const maxMarker = "Max restarts"

	b, err := os.ReadFile(filepath.Join(projectRoot, ".devloop", "daemon.log"))
	if err != nil {
		return 0, false
	}
	lines := strings.Split(string(b), "\n")
	if len(lines) > tailLines {
		lines = lines[len(lines)-tailLines:]
	}
	count := 0
	maxed := false
	for _, ln := range lines {
		if strings.Contains(ln, restartMarker) {
			count++
		}
		if strings.Contains(ln, maxMarker) {
			maxed = true
		}
	}
	return count, maxed
}

// readDaemonPID returns (pid, alive) by reading .devloop/daemon.pid and
// sending signal 0. A missing or stale pidfile reports (0, false).
func readDaemonPID(projectRoot string) (int, bool) {
	b, err := os.ReadFile(filepath.Join(projectRoot, ".devloop", "daemon.pid"))
	if err != nil {
		return 0, false
	}
	pidStr := strings.TrimSpace(string(b))
	pid, err := strconv.Atoi(pidStr)
	if err != nil || pid <= 0 {
		return 0, false
	}
	p, err := os.FindProcess(pid)
	if err != nil {
		return pid, false
	}
	// signal 0: existence check, no actual signal delivered.
	if err := p.Signal(syscall.Signal(0)); err != nil {
		return pid, false
	}
	return pid, true
}

func (m DashboardModel) renderFooter(w int) string {
	hints := "↑/↓ move  ·  / filter  ·  s spec  ·  d diff  ·  enter focus  ·  r refresh  ·  q quit"
	return lipgloss.NewStyle().
		Width(w).
		Faint(true).
		Foreground(theme.Dim).
		Render(hints)
}

func (m DashboardModel) renderLeft(w, h int) string {
	p := m.picker.SetSize(w, h)
	return lipgloss.NewStyle().Width(w).Height(h).Render(p.View())
}

func (m DashboardModel) renderRight(w, h int) string {
	divider := lipgloss.NewStyle().Foreground(theme.Dim).Render("│")

	var content string
	if m.active == nil {
		content = lipgloss.NewStyle().Faint(true).Render(
			"no session selected — start one with `devloop run …`",
		)
	} else {
		content = m.renderSessionDetail(m.active, w-2) // -2 for divider + space
	}

	// Append the SPEC and DIFF panels (collapsed = 1 line each, open ≈ 11/13).
	specView := m.specPanel.SetSize(w - 2).View()
	diffView := m.diffPanel.SetSize(w - 2).View()
	content = lipgloss.JoinVertical(lipgloss.Left, content, specView, diffView)

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

// syncActive aligns m.active with the picker's current selection and refreshes
// any panels whose content depends on which task is active.
func (m DashboardModel) syncActive() DashboardModel {
	item, ok := m.picker.Selected()
	if !ok {
		m.active = nil
		// Clear the spec/diff panels so stale content isn't shown.
		if m.specLoadedForID != "" {
			m.specPanel = m.specPanel.SetContent("")
			m.specLoadedForID = ""
		}
		if m.diffLoadedForID != "" {
			m.diffPanel = m.diffPanel.SetContent("")
			m.diffLoadedForID = ""
		}
		return m
	}
	for i := range m.sessions {
		if m.sessions[i].ID == item.ID {
			m.active = &m.sessions[i]
			// Refresh the spec panel content if the active task changed.
			if m.specLoadedForID != item.ID {
				m.specPanel = m.specPanel.SetContent(m.loadSpecContent(item.ID))
				m.specLoadedForID = item.ID
			}
			// Invalidate any stale diff so the next 'd' toggle reloads.
			if m.diffLoadedForID != item.ID {
				m.diffPanel = m.diffPanel.SetContent("")
				m.diffLoadedForID = ""
			}
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
		style = lipgloss.NewStyle().Foreground(theme.Green)
	case "running":
		style = lipgloss.NewStyle().Foreground(theme.Yellow)
	case "failed", "rejected":
		style = lipgloss.NewStyle().Foreground(theme.Red)
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
