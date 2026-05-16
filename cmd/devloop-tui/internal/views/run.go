package views

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/shaifulshabuj/devloop/devloop-tui/internal/components"
	"github.com/shaifulshabuj/devloop/devloop-tui/internal/stream"
)

// ─── Internal message types ───────────────────────────────────────────────────

// runSessionLoadedMsg carries the result of the initial session scan for the
// focused task. It is the RunModel analogue of sessionsLoadedMsg.
type runSessionLoadedMsg struct {
	session *stream.Session // nil if not found
	err     error
}

// runStreamEventMsg carries one Event from the NDJSON tailer (reuses the
// same channel infrastructure as DashboardModel but uses its own type so
// Update dispatch stays clean).
type runStreamEventMsg struct{ event stream.Event }

// runStreamErrMsg carries a non-fatal tailer error.
type runStreamErrMsg struct{ err error }

// runTickMsg is emitted every 100 ms to advance the spinner.
type runTickMsg struct{}

// ─── Pending approval ─────────────────────────────────────────────────────────

// pendingApproval holds the state for an open approval modal.
type pendingApproval struct {
	Gate         string
	Summary      string
	DetailPath   string
	DetailSize   string // raw string from event (bytes)
	DecisionFile string
}

// ─── Options ──────────────────────────────────────────────────────────────────

// RunOptions configures RunModel construction.
type RunOptions struct {
	// TaskID is the TASK-ID this view should focus on. Required; if empty
	// View() renders an error message and all events are ignored.
	TaskID string
	// NoStream disables the NDJSON tailer goroutine. Used in tests.
	NoStream bool
}

// ─── Model ────────────────────────────────────────────────────────────────────

// RunModel is a Bubble Tea model focused on a single devloop session. It shows:
//   - A header with Task ID and feature text
//   - A pipeline_grid for the session's phase states
//   - A rolling log of the last 8 events (dim text)
//   - An approval modal overlay when an approval.request arrives
type RunModel struct {
	projectRoot string
	opts        RunOptions

	session     *stream.Session // nil until loaded
	recentLines []string        // last ≤8 formatted event lines for the log footer

	pendingApproval *pendingApproval // non-nil when modal is visible

	spinnerTick int
	width       int
	height      int

	err      error // last non-fatal error shown in status bar
	eventsCh <-chan stream.Event
	errsCh   <-chan error
	cancel   context.CancelFunc
}

// NewRun constructs a live RunModel for the given task ID.
func NewRun(projectRoot, taskID string) RunModel {
	return NewRunWithOptions(projectRoot, RunOptions{TaskID: taskID})
}

// NewRunWithOptions constructs a RunModel with explicit options.
func NewRunWithOptions(projectRoot string, opts RunOptions) RunModel {
	return RunModel{
		projectRoot: projectRoot,
		opts:        opts,
	}
}

// ─── Init ─────────────────────────────────────────────────────────────────────

func (m RunModel) Init() tea.Cmd {
	if m.opts.TaskID == "" {
		return nil
	}

	cmds := []tea.Cmd{
		m.loadSessionCmd(),
		m.runTickCmd(),
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
			cmds = append(cmds, runWaitForEvent(eventsCh), runWaitForErr(errsCh))
		}
	}

	return tea.Batch(cmds...)
}

// ─── Update ───────────────────────────────────────────────────────────────────

func (m RunModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmds []tea.Cmd

	switch msg := msg.(type) {

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height

	case runTickMsg:
		m.spinnerTick++
		cmds = append(cmds, m.runTickCmd())

	case runSessionLoadedMsg:
		if msg.err != nil {
			m.err = msg.err
		} else {
			m.session = msg.session
		}

	case runStreamEventMsg:
		m = m.applyRunEvent(msg.event)
		if m.eventsCh != nil {
			cmds = append(cmds, runWaitForEvent(m.eventsCh))
		}

	case runStreamErrMsg:
		m.err = msg.err
		if m.errsCh != nil {
			cmds = append(cmds, runWaitForErr(m.errsCh))
		}

	case tea.KeyMsg:
		// Approval modal consumes keys first.
		if m.pendingApproval != nil {
			switch {
			case key.Matches(msg, keyApprove):
				cmd := m.writeDecisionCmd("approve")
				m.pendingApproval = nil
				cmds = append(cmds, cmd)
				return m, tea.Batch(cmds...)

			case key.Matches(msg, keyReject):
				cmd := m.writeDecisionCmd("reject")
				m.pendingApproval = nil
				cmds = append(cmds, cmd)
				return m, tea.Batch(cmds...)

			case key.Matches(msg, keyEdit):
				cmd := m.writeDecisionCmd("edit")
				m.pendingApproval = nil
				cmds = append(cmds, cmd)
				return m, tea.Batch(cmds...)

			case key.Matches(msg, keyEscRun):
				// esc does NOT cancel a pending approval — fall through to quit
				// only when there is no modal open.
				// (We do nothing here; user must explicitly reject.)
				return m, tea.Batch(cmds...)
			}
		}

		// Global keys when no modal (or modal didn't match above).
		switch {
		case key.Matches(msg, keyQuitRun):
			if m.cancel != nil {
				m.cancel()
			}
			return m, tea.Quit
		}
	}

	return m, tea.Batch(cmds...)
}

// ─── View ─────────────────────────────────────────────────────────────────────

func (m RunModel) View() string {
	if m.opts.TaskID == "" {
		return lipgloss.NewStyle().Faint(true).Render("no task specified")
	}

	w := m.width
	if w <= 0 {
		w = 120
	}

	var lines []string

	// Header
	lines = append(lines, m.renderRunHeader(w))

	// Session content or loading placeholder
	if m.session == nil {
		lines = append(lines, lipgloss.NewStyle().Faint(true).Render("loading session…"))
	} else {
		lines = append(lines, m.renderSessionPane(w))
	}

	// Error bar
	if m.err != nil {
		errLine := lipgloss.NewStyle().Foreground(lipgloss.Color("196")).Render("⚠ " + m.err.Error())
		lines = append(lines, errLine)
	}

	// Recent event log (last 8 lines, dim)
	if len(m.recentLines) > 0 {
		lines = append(lines, "")
		dimStyle := lipgloss.NewStyle().Faint(true).Foreground(lipgloss.Color("240"))
		for _, l := range m.recentLines {
			lines = append(lines, dimStyle.Render(l))
		}
	}

	// Footer hints
	footer := m.renderRunFooter(w)
	lines = append(lines, footer)

	body := strings.Join(lines, "\n")

	// Approval modal overlay on top.
	if m.pendingApproval != nil {
		return m.renderWithModal(body, w)
	}
	return body
}

// ─── Rendering helpers ────────────────────────────────────────────────────────

func (m RunModel) renderRunHeader(w int) string {
	title := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("205")).Render("DevLoop")
	taskPart := ""
	if m.opts.TaskID != "" {
		taskPart = "  ·  " + m.opts.TaskID
	}
	if m.session != nil && m.session.Feature != "" {
		feature := m.session.Feature
		if len(feature) > 60 {
			feature = feature[:59] + "…"
		}
		taskPart += "  ·  " + feature
	}
	content := title + taskPart
	return lipgloss.NewStyle().
		Width(w).
		BorderStyle(lipgloss.NormalBorder()).
		BorderBottom(true).
		BorderForeground(lipgloss.Color("240")).
		Render(content)
}

func (m RunModel) renderRunFooter(w int) string {
	hints := "a approve  ·  r reject  ·  e edit  ·  q quit"
	if m.pendingApproval == nil {
		hints = "q quit"
	}
	return lipgloss.NewStyle().
		Width(w).
		Faint(true).
		Foreground(lipgloss.Color("240")).
		Render(hints)
}

func (m RunModel) renderSessionPane(w int) string {
	s := m.session
	bold := lipgloss.NewStyle().Bold(true)

	var lines []string
	lines = append(lines, bold.Render("Task:    ")+s.ID)
	lines = append(lines, bold.Render("Feature: ")+wordWrap(s.Feature, w-12))
	lines = append(lines, bold.Render("Status:  ")+colorStatus(s.Status))
	lines = append(lines, "")
	lines = append(lines, bold.Render("Phases:"))

	phases := buildPhases(s)
	grid := components.Render(phases, components.GridOptions{
		Width:       w - 4,
		Compact:     false,
		SpinnerTick: m.spinnerTick,
	})
	for _, gl := range strings.Split(grid, "\n") {
		lines = append(lines, "  "+gl)
	}

	return strings.Join(lines, "\n")
}

// renderWithModal overlays the approval modal on top of the body string.
// The modal is rendered as a centred box.
func (m RunModel) renderWithModal(body string, w int) string {
	pa := m.pendingApproval

	modalW := w - 8
	if modalW < 40 {
		modalW = 40
	}
	if modalW > 72 {
		modalW = 72
	}

	titleStr := fmt.Sprintf("Approval needed · gate=%s", pa.Gate)
	summaryLines := wrapText(pa.Summary, modalW-4)

	var detailLine string
	if pa.DetailPath != "" {
		detailLine = fmt.Sprintf("Detail: %s", pa.DetailPath)
		if pa.DetailSize != "" && pa.DetailSize != "0" {
			detailLine += fmt.Sprintf("  (%s bytes)", pa.DetailSize)
		}
	}

	titleStyle := lipgloss.NewStyle().Bold(true)
	dimStyle := lipgloss.NewStyle().Faint(true)
	keyStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("220"))

	var innerLines []string
	innerLines = append(innerLines, titleStyle.Render(titleStr))
	innerLines = append(innerLines, "")
	innerLines = append(innerLines, "Summary:")
	for _, sl := range summaryLines {
		innerLines = append(innerLines, "  "+sl)
	}
	if detailLine != "" {
		innerLines = append(innerLines, "")
		innerLines = append(innerLines, dimStyle.Render(detailLine))
	}
	innerLines = append(innerLines, "")
	innerLines = append(innerLines,
		keyStyle.Render("[a]pprove")+"   "+
			keyStyle.Render("[r]eject")+"   "+
			keyStyle.Render("[e]dit"),
	)

	inner := strings.Join(innerLines, "\n")

	modal := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(lipgloss.Color("220")).
		Padding(1, 2).
		Width(modalW).
		Render(inner)

	// Place modal below the body (simple append — no true overlay positioning
	// without full screen-buffer manipulation).
	return body + "\n\n" + modal
}

// wrapText naively wraps text to maxWidth characters.
func wrapText(text string, maxWidth int) []string {
	if maxWidth <= 0 {
		maxWidth = 60
	}
	var out []string
	for _, rawLine := range strings.Split(text, "\n") {
		if len(rawLine) <= maxWidth {
			out = append(out, rawLine)
			continue
		}
		words := strings.Fields(rawLine)
		var cur strings.Builder
		for _, w := range words {
			if cur.Len() == 0 {
				cur.WriteString(w)
			} else if cur.Len()+1+len(w) <= maxWidth {
				cur.WriteByte(' ')
				cur.WriteString(w)
			} else {
				out = append(out, cur.String())
				cur.Reset()
				cur.WriteString(w)
			}
		}
		if cur.Len() > 0 {
			out = append(out, cur.String())
		}
	}
	if len(out) == 0 {
		out = []string{""}
	}
	return out
}

// ─── Key bindings ─────────────────────────────────────────────────────────────

var (
	keyApprove = key.NewBinding(key.WithKeys("a", "y"))
	keyReject  = key.NewBinding(key.WithKeys("r", "n"))
	keyEdit    = key.NewBinding(key.WithKeys("e"))
	keyQuitRun = key.NewBinding(key.WithKeys("q", "ctrl+c", "esc"))
	keyEscRun  = key.NewBinding(key.WithKeys("esc"))
)

// ─── Commands ─────────────────────────────────────────────────────────────────

func (m RunModel) loadSessionCmd() tea.Cmd {
	root := m.projectRoot
	taskID := m.opts.TaskID
	return func() tea.Msg {
		sessions, err := stream.Scan(root)
		if err != nil {
			return runSessionLoadedMsg{err: err}
		}
		for i := range sessions {
			if sessions[i].ID == taskID {
				return runSessionLoadedMsg{session: &sessions[i]}
			}
		}
		return runSessionLoadedMsg{session: nil}
	}
}

func (m RunModel) runTickCmd() tea.Cmd {
	return tea.Tick(100*time.Millisecond, func(time.Time) tea.Msg {
		return runTickMsg{}
	})
}

func runWaitForEvent(ch <-chan stream.Event) tea.Cmd {
	return func() tea.Msg {
		ev, ok := <-ch
		if !ok {
			return nil
		}
		return runStreamEventMsg{event: ev}
	}
}

func runWaitForErr(ch <-chan error) tea.Cmd {
	return func() tea.Msg {
		err, ok := <-ch
		if !ok {
			return nil
		}
		return runStreamErrMsg{err: err}
	}
}

// writeDecisionCmd returns a Cmd that writes a TUI decision to the pending
// approval's decision_file. It is safe to call with a nil pendingApproval
// (returns nil cmd) — but callers always have a non-nil pendingApproval before
// calling.
func (m RunModel) writeDecisionCmd(decision string) tea.Cmd {
	pa := m.pendingApproval
	if pa == nil || pa.DecisionFile == "" {
		return nil
	}
	gate := pa.Gate
	decisionFile := pa.DecisionFile
	return func() tea.Msg {
		writeApprovalDecision(decisionFile, gate, decision)
		return nil
	}
}

// writeApprovalDecision writes the TUI decision JSON to decisionFile.
// Errors are silently ignored (the approval gate will time out and fall through
// to the TTY prompt as a safe fallback).
func writeApprovalDecision(decisionFile, gate, decision string) {
	ts := time.Now().UTC().Format(time.RFC3339)
	payload := map[string]string{
		"ts":       ts,
		"gate":     gate,
		"decision": decision,
		"source":   "tui",
	}
	data, err := json.Marshal(payload)
	if err != nil {
		return
	}
	// Ensure the directory exists.
	_ = os.MkdirAll(filepath.Dir(decisionFile), 0o700)
	_ = os.WriteFile(decisionFile, data, 0o600)
}

// ─── State helpers ────────────────────────────────────────────────────────────

// applyRunEvent applies a single stream event to the RunModel state.
func (m RunModel) applyRunEvent(ev stream.Event) RunModel {
	// Only process events for our session (or events with no session yet).
	if m.opts.TaskID != "" && ev.Session != "" && ev.Session != m.opts.TaskID {
		return m
	}

	// Append to recent log.
	line := formatEventLine(ev)
	m.recentLines = append(m.recentLines, line)
	if len(m.recentLines) > 8 {
		m.recentLines = m.recentLines[len(m.recentLines)-8:]
	}

	switch ev.Kind {
	case "session.start":
		// Refresh the session from disk.
		sessions, err := stream.Scan(m.projectRoot)
		if err == nil {
			for i := range sessions {
				if sessions[i].ID == m.opts.TaskID {
					m.session = &sessions[i]
					break
				}
			}
		}

	case "session.end":
		if m.session != nil {
			m.session.Status = ev.Status
		}

	case "phase.start":
		m = m.patchRunPhase(ev.Session, ev.Phase, stream.PhaseState{
			Status: "running",
			Time:   ev.TS,
		})

	case "phase.end":
		status := ev.Status
		if status == "" {
			status = "done"
		}
		m = m.patchRunPhase(ev.Session, ev.Phase, stream.PhaseState{
			Status: status,
			Time:   ev.TS,
		})

	case "approval.request":
		if ev.Session == m.opts.TaskID {
			m.pendingApproval = &pendingApproval{
				Gate:         ev.Gate,
				Summary:      ev.Summary,
				DetailPath:   ev.DetailPath,
				DetailSize:   ev.DetailSize,
				DecisionFile: ev.DecisionFile,
			}
		}

	case "approval.decision":
		// Authoritative dismiss: clear modal regardless of source.
		if ev.Session == m.opts.TaskID {
			m.pendingApproval = nil
		}
	}

	return m
}

// patchRunPhase updates a phase state in the focused session.
func (m RunModel) patchRunPhase(sessionID, phase string, ps stream.PhaseState) RunModel {
	if m.session == nil || m.session.ID != sessionID {
		return m
	}
	if m.session.PhaseStates == nil {
		m.session.PhaseStates = make(map[string]stream.PhaseState)
	}
	m.session.PhaseStates[phase] = ps
	return m
}

// formatEventLine formats a stream.Event as a short one-line log entry.
func formatEventLine(ev stream.Event) string {
	ts := ev.TS.Format("15:04:05")
	switch ev.Kind {
	case "phase.start":
		return fmt.Sprintf("%s  phase.start  %s", ts, ev.Phase)
	case "phase.end":
		return fmt.Sprintf("%s  phase.end    %s  status=%s  dur=%sms", ts, ev.Phase, ev.Status, ev.DurationMs)
	case "approval.request":
		return fmt.Sprintf("%s  approval.request  gate=%s", ts, ev.Gate)
	case "approval.decision":
		return fmt.Sprintf("%s  approval.decision  gate=%s  decision=%s  source=%s", ts, ev.Gate, ev.Decision, ev.Source)
	case "session.start":
		return fmt.Sprintf("%s  session.start", ts)
	case "session.end":
		return fmt.Sprintf("%s  session.end  status=%s", ts, ev.Status)
	default:
		return fmt.Sprintf("%s  %s", ts, ev.Kind)
	}
}
