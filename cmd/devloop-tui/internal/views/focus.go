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
	"path/filepath"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/shaifulshabuj/devloop/devloop-tui/internal/components"
	"github.com/shaifulshabuj/devloop/devloop-tui/internal/stream"
	"github.com/shaifulshabuj/devloop/devloop-tui/internal/theme"
	"github.com/shaifulshabuj/devloop/devloop-tui/internal/uimsg"
)

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

	err      error
	eventsCh <-chan stream.Event
	errsCh   <-chan error
	cancel   context.CancelFunc
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
		projectRoot: projectRoot,
		opts:        opts,
		idx:         -1,
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
		cmds = append(cmds, m.tickCmd())

	case focusSessionsLoadedMsg:
		if msg.err != nil {
			m.err = msg.err
		} else {
			m.err = nil
			m.sessions = msg.sessions
			m.idx = m.resolveStartIndex()
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
		case "2":
			m.tab = TabSpec
		case "3":
			m.tab = TabDiff
		case "tab":
			m.tab = (m.tab + 1) % 3

		case "left", "h":
			if len(m.sessions) > 0 {
				m.idx = (m.idx - 1 + len(m.sessions)) % len(m.sessions)
			}
		case "right", "l":
			if len(m.sessions) > 0 {
				m.idx = (m.idx + 1) % len(m.sessions)
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
	switch m.tab {
	case TabLog:
		return theme.StyleLogLine.Render("(LOG tab — live event stream lands here in P2-3)")
	case TabSpec:
		return theme.StyleLogLine.Render("(SPEC tab — .devloop/specs/" + s.ID + ".md lands here in P2-3)")
	case TabDiff:
		return theme.StyleLogLine.Render("(DIFF tab — git diff baseline..HEAD lands here in P2-3)")
	}
	return ""
}

func (m FocusModel) renderFooter(w int) string {
	hints := "←/→ task  ·  1/2/3 tab  ·  tab cycle  ·  esc back"
	return lipgloss.NewStyle().
		Width(w).
		Faint(true).
		Foreground(theme.Dim).
		Padding(0, 2).
		Render(hints)
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

// applyStreamEvent merges one Event into the appropriate session entry. The
// scaffold updates session status/phases; richer per-tab updates land in
// P2-3.
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
			}
			return m
		}
	}
	return m
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
