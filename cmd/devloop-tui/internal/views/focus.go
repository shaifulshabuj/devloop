package views

// FocusModel is the Phase 2 single-task full-screen view. From the dashboard
// the user presses Enter on a highlighted task and the router (handled in
// internal/app) routes uimsg.OpenFocus → ViewFocus here.
//
// Scaffold scope (P2-1): top bar with feature title + TASK-ID + status,
// placeholder phase track and tab strip, footer with keybinds, esc returns
// to the dashboard. P2-2 fills in the phase track via pipeline_grid, P2-3
// wires LOG/SPEC/DIFF tab content, P2-4 adds ←/→ navigation.

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/shaifulshabuj/devloop/devloop-tui/internal/components"
	"github.com/shaifulshabuj/devloop/devloop-tui/internal/permit"
	"github.com/shaifulshabuj/devloop/devloop-tui/internal/stream"
	"github.com/shaifulshabuj/devloop/devloop-tui/internal/theme"
	"github.com/shaifulshabuj/devloop/devloop-tui/internal/uimsg"
)

// focusDiffLoadedMsg carries the result of an async git-diff for Focus Mode.
type focusDiffLoadedMsg struct {
	taskID  string
	content string
	err     error
}

// focusBodyHeight is the rendered viewport height for the per-tab body.
const focusBodyHeight = 14

// focusSessionsLoadedMsg carries the result of the initial session scan.
type focusSessionsLoadedMsg struct {
	sessions []stream.Session
	err      error
}

// focusTickMsg is the spinner tick (≈ 100 ms).
type focusTickMsg struct{}

// FocusOptions configures FocusModel construction.
type FocusOptions struct {
	// StartIndex / StartID identify which session the dashboard handed
	// off to focus mode. StartID wins on conflict (defensive against
	// stale indices after a rescan).
	StartIndex int
	StartID    string

	// NoStream disables the NDJSON tailer goroutine — used in tests.
	NoStream bool
}

// FocusTab identifies which tab is currently selected inside Focus Mode.
type FocusTab int

const (
	TabLog FocusTab = iota
	TabSpec
	TabDiff
	TabPermit // visible only when permit.Count > 0
)

// FocusModel is the Bubble Tea model for ViewFocus.
type FocusModel struct {
	projectRoot string
	opts        FocusOptions

	sessions    []stream.Session
	idx         int // index into sessions; -1 when empty
	tab         FocusTab
	spinnerTick int
	width       int
	height      int

	// Per-tab content. A single viewport is shared across the three tabs;
	// its content is swapped on tab switch (see refreshViewport).
	vp           viewport.Model
	specCache    map[string]string // TASK-ID → spec content
	diffCache    map[string]string // TASK-ID → diff content
	diffLoading  map[string]bool   // TASK-ID → goroutine in flight
	logLines     map[string][]string // TASK-ID → recent log lines

	err      error
	eventsCh <-chan stream.Event
	errsCh   <-chan error
	cancel   context.CancelFunc

	// Permit queue snapshot for the PERMIT tab. Refreshed on every tick
	// via refreshPermits; PERMIT tab is hidden when len==0.
	permitItems  []permit.Item
	permitCursor int

	// Set of session IDs currently mid-re-architect — populated on
	// phase.escalate events and cleared on the next phase.start of the
	// architect phase. Drives the blue ReArch styling + footer text.
	reArchSessions map[string]bool
}

// NewFocus is the live constructor — use NewFocusWithOptions in tests so the
// NDJSON tailer goroutine isn't started.
func NewFocus(projectRoot string, startIdx int, startID string) FocusModel {
	return NewFocusWithOptions(projectRoot, FocusOptions{
		StartIndex: startIdx,
		StartID:    startID,
	})
}

// NewFocusWithOptions constructs a FocusModel without immediately starting
// any goroutines; goroutine startup happens in Init().
func NewFocusWithOptions(projectRoot string, opts FocusOptions) FocusModel {
	return FocusModel{
		projectRoot:    projectRoot,
		opts:           opts,
		idx:            -1,
		vp:             viewport.New(0, focusBodyHeight),
		specCache:      map[string]string{},
		diffCache:      map[string]string{},
		diffLoading:    map[string]bool{},
		logLines:       map[string][]string{},
		reArchSessions: map[string]bool{},
	}
}

// Init kicks off the initial session scan + spinner tick. When NoStream is
// false it also starts an NDJSON tailer so the phase track updates live.
func (m FocusModel) Init() tea.Cmd {
	cmds := []tea.Cmd{
		m.scanCmd(),
		m.tickCmd(),
	}

	if !m.opts.NoStream {
		tailPath := filepath.Join(m.projectRoot, ".devloop", "events.ndjson")
		tailer := &stream.Tailer{Path: tailPath}
		ctx, cancel := context.WithCancel(context.Background())
		m.cancel = cancel

		evCh, errCh, err := tailer.Run(ctx)
		if err == nil {
			m.eventsCh = evCh
			m.errsCh = errCh
			cmds = append(cmds, waitForFocusEvent(evCh), waitForFocusErr(errCh))
		}
	}

	return tea.Batch(cmds...)
}

// Update is the message switch. The scaffold handles: window resize, tick,
// sessions-loaded, esc → CloseFocus.  Tab switching keys (1/2/3/tab) and
// ←/→ navigation are wired in P2-3 / P2-4.
func (m FocusModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmds []tea.Cmd

	switch msg := msg.(type) {

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height

	case focusTickMsg:
		m.spinnerTick++
		// Refresh permit queue every 5 ticks (≈ 500ms) — cheap dirent scan.
		if m.spinnerTick%5 == 0 {
			m.permitItems, _ = permit.Read(m.projectRoot)
			// Auto-show PERMIT tab when an item appears; auto-hide when
			// none remain and the user is on it.
			if m.tab == TabPermit && len(m.permitItems) == 0 {
				m.tab = TabLog
				m = m.refreshViewport()
			}
		}
		cmds = append(cmds, m.tickCmd())

	case focusSessionsLoadedMsg:
		if msg.err != nil {
			m.err = msg.err
		} else {
			m.err = nil
			m.sessions = msg.sessions
			m.idx = m.resolveStartIndex()
			m = m.refreshViewport()
			if m.idx >= 0 {
				cmds = append(cmds, m.maybeDispatchDiff()...)
			}
		}

	case focusDiffLoadedMsg:
		delete(m.diffLoading, msg.taskID)
		m.diffCache[msg.taskID] = msg.content
		if m.idx >= 0 && msg.taskID == m.sessions[m.idx].ID && m.tab == TabDiff {
			m = m.refreshViewport()
		}

	case permitRefreshedMsg:
		m.permitItems = msg.items
		if m.permitCursor >= len(m.permitItems) {
			m.permitCursor = 0
		}
		if m.tab == TabPermit && len(m.permitItems) == 0 {
			m.tab = TabLog
			m = m.refreshViewport()
		}

	case focusStreamEventMsg:
		m = m.applyStreamEvent(msg.event)
		if m.eventsCh != nil {
			cmds = append(cmds, waitForFocusEvent(m.eventsCh))
		}

	case focusStreamErrMsg:
		m.err = msg.err
		if m.errsCh != nil {
			cmds = append(cmds, waitForFocusErr(m.errsCh))
		}

	case tea.KeyMsg:
		switch msg.String() {
		case "esc", "q":
			if m.cancel != nil {
				m.cancel()
			}
			return m, func() tea.Msg { return uimsg.CloseFocus{} }

		case "1":
			m.tab = TabLog
			m = m.refreshViewport()
		case "2":
			m.tab = TabSpec
			m = m.refreshViewport()
		case "3":
			m.tab = TabDiff
			m = m.refreshViewport()
			cmds = append(cmds, m.maybeDispatchDiff()...)
		case "4":
			if len(m.permitItems) > 0 {
				m.tab = TabPermit
				m.permitCursor = 0
			}
		case "tab":
			// Cycle 3 tabs, or 4 when the PERMIT tab is visible.
			tabs := 3
			if len(m.permitItems) > 0 {
				tabs = 4
			}
			m.tab = FocusTab((int(m.tab) + 1) % tabs)
			m = m.refreshViewport()
			if m.tab == TabDiff {
				cmds = append(cmds, m.maybeDispatchDiff()...)
			}

		case "up", "k":
			if m.tab == TabPermit && m.permitCursor > 0 {
				m.permitCursor--
			}
		case "down", "j":
			if m.tab == TabPermit && m.permitCursor < len(m.permitItems)-1 {
				m.permitCursor++
			}

		case "g":
			// Grant the highlighted permit request.
			if m.tab == TabPermit && m.permitCursor < len(m.permitItems) {
				id := m.permitItems[m.permitCursor].ID
				cmds = append(cmds, m.dispatchPermit("grant", id))
			}
		case "x":
			if m.tab == TabPermit && m.permitCursor < len(m.permitItems) {
				id := m.permitItems[m.permitCursor].ID
				cmds = append(cmds, m.dispatchPermit("deny", id))
			}

		case "left", "h":
			if len(m.sessions) > 0 {
				m.idx = (m.idx - 1 + len(m.sessions)) % len(m.sessions)
				m = m.refreshViewport()
				cmds = append(cmds, m.maybeDispatchDiff()...)
			}
		case "right", "l":
			if len(m.sessions) > 0 {
				m.idx = (m.idx + 1) % len(m.sessions)
				m = m.refreshViewport()
				cmds = append(cmds, m.maybeDispatchDiff()...)
			}

		default:
			// Forward scroll keys to the active viewport.
			if isScrollKey(msg.String()) {
				var vpCmd tea.Cmd
				m.vp, vpCmd = m.vp.Update(msg)
				cmds = append(cmds, vpCmd)
			}
		}
	}

	return m, tea.Batch(cmds...)
}

// View renders the Focus Mode layout. The scaffold uses placeholder tab
// content; P2-3 will wire the real LOG/SPEC/DIFF viewports.
func (m FocusModel) View() string {
	w := m.width
	if w <= 0 {
		w = 120
	}

	if len(m.sessions) == 0 {
		return lipgloss.NewStyle().Width(w).Align(lipgloss.Center).Render(
			theme.StyleMeta.Render("no sessions yet  ·  press esc to return to dashboard"),
		)
	}

	s := m.sessions[m.idx]

	header := m.renderHeader(w, s)
	phases := m.renderPhases(w, s)
	tabs := m.renderTabs(w)
	body := m.renderTabBody(w, s)
	footer := m.renderFooter(w)

	return lipgloss.JoinVertical(lipgloss.Left,
		header,
		phases,
		tabs,
		body,
		footer,
	)
}

func (m FocusModel) renderHeader(w int, s stream.Session) string {
	title := theme.StyleFeatureTitle.Render(`"` + s.Feature + `"`)
	id := theme.StyleMeta.Render(fmt.Sprintf("  %s  ·  task %d of %d", s.ID, m.idx+1, len(m.sessions)))
	status := lipgloss.NewStyle().Foreground(theme.StatusColor(s.Status)).
		Render("  " + theme.StatusIcon(s.Status) + " " + s.Status)
	return lipgloss.NewStyle().
		Width(w).
		Border(lipgloss.NormalBorder(), false, false, true, false).
		BorderForeground(theme.Dim).
		Padding(0, 2).
		Render(title + id + status)
}

func (m FocusModel) renderPhases(w int, s stream.Session) string {
	phases := buildPhases(&s) // reuse helper from dashboard.go
	return components.Render(phases, components.GridOptions{
		Width:       w - 4,
		Compact:     false,
		SpinnerTick: m.spinnerTick,
	})
}

func (m FocusModel) renderTabs(w int) string {
	labels := []string{"LOG", "SPEC", "DIFF"}
	if len(m.permitItems) > 0 {
		labels = append(labels, fmt.Sprintf("PERMIT (%d)", len(m.permitItems)))
	}
	out := make([]string, len(labels))
	for i, lab := range labels {
		style := theme.StyleTabInactive
		if FocusTab(i) == m.tab {
			style = theme.StyleTabActive
		}
		out[i] = style.Padding(0, 2).Render(lab)
	}
	return lipgloss.NewStyle().
		Width(w).
		Border(lipgloss.NormalBorder(), false, false, true, false).
		BorderForeground(theme.Dim).
		Padding(0, 2).
		Render(strings.Join(out, " "))
}

func (m FocusModel) renderTabBody(w int, s stream.Session) string {
	if m.tab == TabPermit {
		return m.renderPermitTab(w)
	}
	if w-4 > 0 {
		m.vp.Width = w - 4
	}
	return lipgloss.NewStyle().Padding(0, 2).Render(m.vp.View())
}

// renderPermitTab shows the pending permit queue with a cursor and per-row
// command / tool / relative time.
func (m FocusModel) renderPermitTab(w int) string {
	if len(m.permitItems) == 0 {
		return theme.StyleMeta.Padding(0, 4).Render("(no pending permission requests)")
	}
	now := time.Now()
	var rows []string
	rows = append(rows, theme.StyleSectionLabel.Padding(0, 2).Render(
		fmt.Sprintf("PERMIT QUEUE  ·  %d pending", len(m.permitItems)),
	))
	for i, it := range m.permitItems {
		// Truncate commands so they fit in narrow terminals.
		cmd := it.Command
		if len(cmd) > w-20 && w > 20 {
			cmd = cmd[:w-20] + "…"
		}
		cursor := "  "
		style := lipgloss.NewStyle().Foreground(theme.Text)
		if i == m.permitCursor {
			cursor = "▸ "
			style = theme.StylePaletteSelected
		}
		row := fmt.Sprintf("%s%-3d %s",
			cursor,
			i+1,
			cmd,
		)
		meta := theme.StyleMeta.Render(fmt.Sprintf("      %s  ·  %s  ·  %s",
			it.Tool, it.RelativeTime(now), it.ShortID()))
		rows = append(rows, style.Render(row), meta)
	}
	rows = append(rows, "",
		theme.StyleFooter.Padding(0, 2).Render(
			"g grant  ·  x deny  ·  ↑/↓ select  ·  esc back"),
	)
	return strings.Join(rows, "\n")
}

// dispatchPermit spawns `bash devloop.sh permit grant|deny <ID>` and on
// completion refreshes the queue snapshot. The output of the subprocess
// itself is discarded — the response file appearing is what unblocks
// devloop's gate.
func (m FocusModel) dispatchPermit(action, id string) tea.Cmd {
	root := m.projectRoot
	return func() tea.Msg {
		cmd := exec.Command("bash", filepath.Join(root, "devloop.sh"), "permit", action, id)
		cmd.Dir = root
		_ = cmd.Run() // errors surface implicitly via the queue refresh
		items, _ := permit.Read(root)
		return permitRefreshedMsg{items: items}
	}
}

// permitRefreshedMsg carries an updated permit queue snapshot.
type permitRefreshedMsg struct{ items []permit.Item }

func (m FocusModel) renderFooter(w int) string {
	hints := m.contextualFooterHint()
	return lipgloss.NewStyle().
		Width(w).
		Faint(true).
		Foreground(theme.Dim).
		Padding(0, 2).
		Render(hints)
}

// contextualFooterHint chooses the footer copy based on the active session's
// state. Spec corrections baked in:
//
//   - "stuck" → use "quiet" for no-output state (slow worker, not failure)
//   - gate timeout (`timed-out-at-*` in session status) → distinct footer
//     pointing at the PERMIT tab, not a generic resume hint
//   - phase.escalate detected → "re-architecting…" footer until next
//     phase.start fires for the session
func (m FocusModel) contextualFooterHint() string {
	const base = "←/→ task  ·  1/2/3 tab  ·  tab cycle  ·  space actions  ·  esc back"
	if m.idx < 0 || m.idx >= len(m.sessions) {
		return base
	}
	id := m.sessions[m.idx].ID

	// Highest-priority: in the middle of a respec escalation.
	if m.reArchSessions[id] {
		return lipgloss.NewStyle().Foreground(theme.Blue).Render(
			"⟳ re-architecting after retries exhausted  ·  waiting for new spec…",
		) + "  ·  esc back"
	}

	status, cmd, ok := readSessionStatus(m.projectRoot, id)
	if ok && strings.HasPrefix(status, "timed-out-at-") {
		// Gate-timeout footer: surface the offending command so the user
		// knows WHAT to approve in the PERMIT tab.
		hint := "⚠ approval timed out"
		if cmd != "" {
			hint += ": " + truncate(cmd, 40)
		}
		permitHint := "tab 4 permit"
		if len(m.permitItems) == 0 {
			permitHint = "tab 4 permit (queue empty)"
		}
		return theme.StyleError.Render(hint) + "  ·  " + permitHint + "  ·  esc back"
	}

	// "Quiet" worker — running phase with no output for > threshold.
	for name, ps := range m.sessions[m.idx].PhaseStates {
		if ps.Status == "running" && time.Since(ps.Time) > stuckThreshold() {
			d := time.Since(ps.Time)
			hint := fmt.Sprintf("⚠ %s quiet %s", name, humanizeDuration(d))
			return theme.StyleWarning.Render(hint) + "  ·  Z resume  ·  esc back"
		}
	}

	return base
}

// readSessionStatus reads .devloop/sessions/<TASK-ID>/status. Returns
// (status, command-that-triggered-gate, ok=true). The command comes from
// the last `approval.request` event in the per-session events.ndjson, since
// devloop.sh's status file doesn't carry that info. Best-effort: if the
// command can't be reconstructed, returns status + empty cmd + ok=true.
//
// Spec correction: brief originally referenced a `worker.state` file that
// doesn't exist. Real source-of-truth file is `status` (no extension).
func readSessionStatus(projectRoot, taskID string) (status, cmd string, ok bool) {
	if taskID == "" {
		return "", "", false
	}
	dir := filepath.Join(projectRoot, ".devloop", "sessions", taskID)
	b, err := os.ReadFile(filepath.Join(dir, "status"))
	if err != nil {
		return "", "", false
	}
	status = strings.TrimSpace(string(b))
	if status == "" {
		return "", "", false
	}
	cmd = lastApprovalRequestCommand(filepath.Join(dir, "events.ndjson"))
	return status, cmd, true
}

// lastApprovalRequestCommand reads the per-session events.ndjson and
// returns the `summary` (or `detail_path`) of the most-recent
// approval.request event. Returns "" on any failure.
func lastApprovalRequestCommand(eventsFile string) string {
	b, err := os.ReadFile(eventsFile)
	if err != nil {
		return ""
	}
	var last string
	for _, line := range strings.Split(string(b), "\n") {
		if !strings.Contains(line, `"kind":"approval.request"`) {
			continue
		}
		// Cheap field extraction without full JSON parse: find "summary":"…"
		// or fall back to "gate":"…". Keeps this hot path allocation-light.
		if v := extractJSONString(line, "summary"); v != "" {
			last = v
			continue
		}
		if v := extractJSONString(line, "gate"); v != "" {
			last = v
		}
	}
	return last
}

// extractJSONString returns the value of `key` in a JSON line, or "". Only
// handles plain string values without escaped quotes — sufficient for the
// `summary`/`gate` fields devloop.sh writes.
func extractJSONString(line, key string) string {
	needle := `"` + key + `":"`
	i := strings.Index(line, needle)
	if i < 0 {
		return ""
	}
	rest := line[i+len(needle):]
	j := strings.IndexByte(rest, '"')
	if j < 0 {
		return ""
	}
	return rest[:j]
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

func (m FocusModel) scanCmd() tea.Cmd {
	root := m.projectRoot
	return func() tea.Msg {
		ss, err := stream.Scan(root)
		return focusSessionsLoadedMsg{sessions: ss, err: err}
	}
}

func (m FocusModel) tickCmd() tea.Cmd {
	return tea.Tick(100*time.Millisecond, func(time.Time) tea.Msg {
		return focusTickMsg{}
	})
}

// refreshViewport swaps the shared viewport's content to match the current
// (idx, tab) combination. Spec content is cached; diff is filled in by
// focusDiffLoadedMsg; log content is the per-session line buffer.
func (m FocusModel) refreshViewport() FocusModel {
	if m.idx < 0 || m.idx >= len(m.sessions) {
		m.vp.SetContent("")
		return m
	}
	id := m.sessions[m.idx].ID
	var body string
	switch m.tab {
	case TabLog:
		lines := m.logLines[id]
		if len(lines) == 0 {
			body = "(no events yet for " + id + " — waiting on stream)"
		} else {
			body = strings.Join(lines, "\n")
		}
	case TabSpec:
		if cached, ok := m.specCache[id]; ok {
			body = cached
		} else {
			body = m.loadSpecForTab(id)
			m.specCache[id] = body
		}
	case TabDiff:
		if cached, ok := m.diffCache[id]; ok {
			body = cached
		} else if m.diffLoading[id] {
			body = "loading diff…"
		} else {
			body = "(press 3 or tab to focus the DIFF tab to load)"
		}
	}
	m.vp.SetContent(body)
	m.vp.GotoTop()
	return m
}

// loadSpecForTab reads .devloop/specs/<TASK-ID>.md or a placeholder.
func (m FocusModel) loadSpecForTab(taskID string) string {
	path := filepath.Join(m.projectRoot, ".devloop", "specs", taskID+".md")
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "(no spec yet for " + taskID + " — run `devloop architect …`)"
		}
		return fmt.Sprintf("(error reading spec: %v)", err)
	}
	return string(b)
}

// maybeDispatchDiff returns a tea.Cmd that kicks off an async git-diff for
// the current task when the DIFF tab is active and the result is not yet
// cached. Returns nothing if already cached or in flight.
func (m FocusModel) maybeDispatchDiff() []tea.Cmd {
	if m.idx < 0 || m.tab != TabDiff {
		return nil
	}
	id := m.sessions[m.idx].ID
	if _, ok := m.diffCache[id]; ok {
		return nil
	}
	if m.diffLoading[id] {
		return nil
	}
	m.diffLoading[id] = true
	return []tea.Cmd{m.dispatchFocusDiff(id)}
}

// dispatchFocusDiff is the goroutine-backed git-diff worker. Mirrors
// dashboard's dispatchDiffLoad but emits focusDiffLoadedMsg so the two
// views' message graphs stay independent.
func (m FocusModel) dispatchFocusDiff(taskID string) tea.Cmd {
	root := m.projectRoot
	return func() tea.Msg {
		baselinePath := filepath.Join(root, ".devloop", "specs", taskID+".pre-commit")
		baseline := ""
		if b, err := os.ReadFile(baselinePath); err == nil {
			baseline = strings.TrimSpace(string(b))
		}
		// Reuse dashboard.go's dispatchDiffLoad return path by wrapping
		// the same helper inline. Keeping this separate from the
		// dashboard's diff so each view can evolve its caching strategy.
		args := []string{"-C", root, "--no-pager", "diff", "--no-color"}
		if baseline != "" {
			args = append(args, baseline+"..HEAD")
		} else {
			args = append(args, "HEAD")
		}
		out, err := exec.Command("git", args...).CombinedOutput()
		if err != nil {
			return focusDiffLoadedMsg{
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
		return focusDiffLoadedMsg{taskID: taskID, content: content}
	}
}

// resolveStartIndex translates the (idx, id) handoff into a valid index
// inside the freshly-scanned session list. id wins on conflict — indices
// can be stale after a rescan.
func (m FocusModel) resolveStartIndex() int {
	if m.opts.StartID != "" {
		for i, s := range m.sessions {
			if s.ID == m.opts.StartID {
				return i
			}
		}
	}
	if m.opts.StartIndex >= 0 && m.opts.StartIndex < len(m.sessions) {
		return m.opts.StartIndex
	}
	return 0
}

// applyStreamEvent merges one Event into the appropriate session entry and
// appends a human-readable line into that session's log buffer for the LOG
// tab.
func (m FocusModel) applyStreamEvent(ev stream.Event) FocusModel {
	if ev.Session == "" {
		return m
	}
	for i := range m.sessions {
		if m.sessions[i].ID == ev.Session {
			switch ev.Kind {
			case "session.end":
				m.sessions[i].Status = ev.Status
				m.sessions[i].FinishedAt = ev.TS
			case "phase.start", "phase.end":
				if m.sessions[i].PhaseStates == nil {
					m.sessions[i].PhaseStates = map[string]stream.PhaseState{}
				}
				ps := m.sessions[i].PhaseStates[ev.Phase]
				ps.Status = ev.Status
				ps.Time = ev.TS
				m.sessions[i].PhaseStates[ev.Phase] = ps
				// phase.start clears any pending re-arch flag for this
				// session — the new phase has begun, so we're no longer
				// "waiting on respec".
				if ev.Kind == "phase.start" {
					delete(m.reArchSessions, ev.Session)
				}
			case "phase.escalate":
				// Worker exhausted retries; devloop is about to enter the
				// respec phase. Track this so the phase card flips to
				// blue (ReArch) and the footer surfaces the message.
				m.reArchSessions[ev.Session] = true
			}
			// Append a log line, keeping at most 200 per session to bound
			// memory for long-running pipelines.
			line := formatFocusEventLine(ev)
			lines := append(m.logLines[ev.Session], line)
			if len(lines) > 200 {
				lines = lines[len(lines)-200:]
			}
			m.logLines[ev.Session] = lines

			// If the LOG tab is showing this session, refresh viewport.
			if m.idx >= 0 && m.sessions[m.idx].ID == ev.Session && m.tab == TabLog {
				m = m.refreshViewport()
				m.vp.GotoBottom()
			}
			return m
		}
	}
	return m
}

// formatFocusEventLine renders one NDJSON event as a single log line for the
// Focus Mode LOG tab. Distinct from run.go's formatEventLine so the two
// views' formatting can evolve independently.
func formatFocusEventLine(ev stream.Event) string {
	ts := ev.TS.Format("15:04:05")
	switch ev.Kind {
	case "phase.start":
		return fmt.Sprintf("%s  %-12s  ▶ start", ts, ev.Phase)
	case "phase.end":
		return fmt.Sprintf("%s  %-12s  ■ %s", ts, ev.Phase, ev.Status)
	case "session.start":
		return fmt.Sprintf("%s  session       ▶ start", ts)
	case "session.end":
		return fmt.Sprintf("%s  session       ■ %s", ts, ev.Status)
	case "session.resume":
		return fmt.Sprintf("%s  session       ↻ resume", ts)
	case "phase.escalate":
		return fmt.Sprintf("%s  escalate      ⟳ re-architect (retries exhausted)", ts)
	case "approval.request":
		return fmt.Sprintf("%s  approval      ? request", ts)
	case "approval.decision":
		return fmt.Sprintf("%s  approval      ✓ %s", ts, ev.Status)
	default:
		return fmt.Sprintf("%s  %s  %s", ts, ev.Kind, ev.Status)
	}
}

// ── Stream message glue ───────────────────────────────────────────────────────

type focusStreamEventMsg struct{ event stream.Event }
type focusStreamErrMsg struct{ err error }

func waitForFocusEvent(ch <-chan stream.Event) tea.Cmd {
	return func() tea.Msg {
		ev, ok := <-ch
		if !ok {
			return focusStreamErrMsg{err: fmt.Errorf("focus event channel closed")}
		}
		return focusStreamEventMsg{event: ev}
	}
}

func waitForFocusErr(ch <-chan error) tea.Cmd {
	return func() tea.Msg {
		err, ok := <-ch
		if !ok {
			return nil
		}
		return focusStreamErrMsg{err: err}
	}
}
