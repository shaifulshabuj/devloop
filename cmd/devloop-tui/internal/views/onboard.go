package views

// OnboardModel is the Phase 3 first-run wizard. It streams `devloop init`
// then `devloop doctor --json`, renders the results as structured rows,
// and finally shows a "READY" box. The wizard auto-launches when no
// devloop.config.sh is present in the working directory.
//
// Subprocesses are dispatched via the same goroutine+chan pattern used by
// chat.dispatchShell — see runShellCmd in chat.go for the live runner
// (test mode short-circuits to canned output).

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/shaifulshabuj/devloop/devloop-tui/internal/theme"
)

// OnboardPhase identifies which step of the wizard is currently active.
type OnboardPhase int

const (
	PhaseInit OnboardPhase = iota
	PhaseDoctor
	PhaseDone
)

// initLineMsg carries one line of `devloop init` stdout.
type initLineMsg struct{ line string }

// initDoneMsg signals that `devloop init` finished. ExitCode == 0 indicates
// success and triggers the doctor phase.
type initDoneMsg struct {
	exitCode int
	err      error
}

// doctorDoneMsg carries the parsed `devloop doctor --json` payload.
type doctorDoneMsg struct {
	pass   int
	fail   int
	checks []DoctorCheck
	raw    string // full JSON for error reporting
	err    error
}

// DoctorCheck mirrors one entry in `devloop doctor --json`'s checks array.
type DoctorCheck struct {
	Check   string `json:"check"`
	Status  string `json:"status"`  // "pass" | "fail"
	Message string `json:"message"` // hint when failed
}

// OnboardOptions configures OnboardModel construction.
type OnboardOptions struct {
	// NoSubprocess short-circuits init/doctor with canned data — used in tests.
	NoSubprocess bool
}

// OnboardModel is the Bubble Tea model for the wizard view.
type OnboardModel struct {
	projectRoot string
	opts        OnboardOptions

	phase    OnboardPhase
	initOK   bool
	initBuf  []string // collected init output lines, structured by line kind
	doctor   []DoctorCheck
	doctorPF [2]int // pass, fail
	err      error

	width  int
	height int
}

// NewOnboard constructs a live OnboardModel.
func NewOnboard(projectRoot string) OnboardModel {
	return NewOnboardWithOptions(projectRoot, OnboardOptions{})
}

// NewOnboardWithOptions is the test-friendly constructor.
func NewOnboardWithOptions(projectRoot string, opts OnboardOptions) OnboardModel {
	return OnboardModel{
		projectRoot: projectRoot,
		opts:        opts,
		phase:       PhaseInit,
	}
}

// Init kicks off the `devloop init` subprocess (or canned output in tests).
func (m OnboardModel) Init() tea.Cmd {
	if m.opts.NoSubprocess {
		return cannedOnboard()
	}
	return m.runInit()
}

// Update is the message switch.
func (m OnboardModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height

	case initLineMsg:
		m.initBuf = append(m.initBuf, msg.line)

	case initDoneMsg:
		if msg.err != nil || msg.exitCode != 0 {
			m.err = fmt.Errorf("devloop init failed (exit %d): %v", msg.exitCode, msg.err)
			return m, nil
		}
		m.initOK = true
		m.phase = PhaseDoctor
		if m.opts.NoSubprocess {
			// Tests skip the doctor subprocess; emit a canned doctor done.
			return m, func() tea.Msg {
				return doctorDoneMsg{
					pass: 2, fail: 0,
					checks: []DoctorCheck{
						{Check: "claude installed", Status: "pass"},
						{Check: "git installed", Status: "pass"},
					},
				}
			}
		}
		return m, m.runDoctor()

	case initBatchMsg:
		m = m.applyInitBatch(msg)
		return m, func() tea.Msg {
			return initDoneMsg{exitCode: msg.exitCode, err: msg.err}
		}

	case doctorDoneMsg:
		if msg.err != nil {
			m.err = msg.err
			return m, nil
		}
		m.doctor = msg.checks
		m.doctorPF = [2]int{msg.pass, msg.fail}
		m.phase = PhaseDone

	case tea.KeyMsg:
		switch msg.String() {
		case "esc", "q", "ctrl+c":
			return m, tea.Quit
		case "enter":
			if m.phase == PhaseDone && m.doctorPF[1] == 0 {
				// Caller (main.go) detects program exit and launches
				// the dashboard. Easier than wiring a router into the
				// onboarding-as-standalone entry point.
				return m, tea.Quit
			}
		}
	}

	return m, nil
}

// View renders the wizard.
func (m OnboardModel) View() string {
	w := m.width
	if w <= 0 {
		w = 80
	}

	title := theme.StyleLogo.Render("DevLoop Setup")

	var sections []string
	sections = append(sections, lipgloss.NewStyle().Padding(1, 2).Render(title))

	if m.err != nil {
		sections = append(sections, theme.StyleError.Padding(0, 2).Render("⚠ "+m.err.Error()))
		return lipgloss.JoinVertical(lipgloss.Left, sections...)
	}

	sections = append(sections, m.renderInitSection())
	if m.phase >= PhaseDoctor || m.initOK {
		sections = append(sections, m.renderDoctorSection())
	}
	if m.phase == PhaseDone {
		sections = append(sections, m.renderReadyBox(w))
	} else {
		sections = append(sections, m.renderFooter())
	}

	return lipgloss.JoinVertical(lipgloss.Left, sections...)
}

func (m OnboardModel) renderInitSection() string {
	header := theme.StyleSectionLabel.Padding(0, 2).Render("INITIALIZE  ·  devloop init")

	var rows []string
	for _, ln := range m.initBuf {
		rows = append(rows, formatInitLine(ln))
	}
	if len(rows) == 0 {
		rows = []string{theme.StyleMeta.Padding(0, 4).Render("(running…)")}
	}

	return lipgloss.JoinVertical(lipgloss.Left,
		header,
		strings.Join(rows, "\n"),
		"",
	)
}

// formatInitLine extracts the `✔ Created:` / `✔ Updated:` markers from one
// line of `devloop init` output and renders a structured row. Unknown lines
// pass through dimmed.
func formatInitLine(line string) string {
	trim := strings.TrimSpace(line)
	switch {
	case strings.Contains(trim, "Created:"):
		idx := strings.Index(trim, "Created:")
		path := strings.TrimSpace(trim[idx+len("Created:"):])
		return lipgloss.NewStyle().Padding(0, 4).Render(
			theme.StyleSuccess.Render("✓ created  ") + path,
		)
	case strings.Contains(trim, "Updated:"):
		idx := strings.Index(trim, "Updated:")
		path := strings.TrimSpace(trim[idx+len("Updated:"):])
		return lipgloss.NewStyle().Padding(0, 4).Render(
			theme.StyleSuccess.Render("✓ updated  ") + path,
		)
	case strings.Contains(trim, "Auto-configured"):
		return lipgloss.NewStyle().Padding(0, 4).Render(
			theme.StyleWarning.Render("⚙ ") + theme.StyleMeta.Render(trim),
		)
	default:
		return lipgloss.NewStyle().Padding(0, 4).Render(theme.StyleMeta.Render(trim))
	}
}

func (m OnboardModel) renderDoctorSection() string {
	header := theme.StyleSectionLabel.Padding(0, 2).Render("CHECK  ·  devloop doctor")
	if m.phase == PhaseDoctor && len(m.doctor) == 0 {
		return lipgloss.JoinVertical(lipgloss.Left,
			header,
			theme.StyleMeta.Padding(0, 4).Render("(running…)"),
			"",
		)
	}

	rows := make([]string, 0, len(m.doctor))
	for _, c := range m.doctor {
		icon := theme.StyleSuccess.Render("✓")
		if c.Status == "fail" {
			icon = theme.StyleError.Render("✗")
		}
		rows = append(rows, lipgloss.NewStyle().Padding(0, 4).Render(
			fmt.Sprintf("%s  %-50s  %s", icon, c.Check, theme.StyleMeta.Render(c.Message)),
		))
	}

	summary := lipgloss.NewStyle().Padding(0, 4).Render(
		fmt.Sprintf("%s %d passed  ·  %s %d failed",
			theme.StyleSuccess.Render("✓"), m.doctorPF[0],
			theme.StyleError.Render("✗"), m.doctorPF[1],
		),
	)

	return lipgloss.JoinVertical(lipgloss.Left,
		header,
		strings.Join(rows, "\n"),
		"",
		summary,
		"",
	)
}

func (m OnboardModel) renderReadyBox(w int) string {
	msg := "READY  ·  press enter to open the dashboard, or run `devloop start`"
	if m.doctorPF[1] > 0 {
		msg = fmt.Sprintf("%d failing check(s) above — fix and re-run `devloop-tui onboard`", m.doctorPF[1])
		return lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(theme.Yellow).
			Padding(0, 2).
			Margin(1, 2).
			Width(w - 4).
			Render(theme.StyleWarning.Render(msg))
	}
	return lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(theme.Green).
		Padding(0, 2).
		Margin(1, 2).
		Width(w - 4).
		Render(theme.StyleSuccess.Render(msg))
}

func (m OnboardModel) renderFooter() string {
	return theme.StyleFooter.Padding(0, 2).Render("esc / q to abort")
}

// ─── Subprocess runners ───────────────────────────────────────────────────────

// runInit streams `bash devloop.sh init` line-by-line. Each line is sent as
// an initLineMsg; on EOF/exit, an initDoneMsg.
func (m OnboardModel) runInit() tea.Cmd {
	return m.streamScript([]string{"init"}, func(line string) tea.Msg {
		return initLineMsg{line: line}
	}, func(exit int, err error) tea.Msg {
		return initDoneMsg{exitCode: exit, err: err}
	})
}

// runDoctor runs `bash devloop.sh doctor --json` and parses the trailing
// JSON line into a doctorDoneMsg. Doctor still emits human output before
// the JSON (the --json flag is additive, not exclusive), so we capture all
// stdout and pick the last line that parses as JSON.
func (m OnboardModel) runDoctor() tea.Cmd {
	root := m.projectRoot
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, "bash",
			filepath.Join(root, "devloop.sh"), "doctor", "--json")
		cmd.Dir = root
		out, err := cmd.Output()
		// doctor returns non-zero when any check fails — that's not a
		// failure of the wizard, just data we want to display.
		if err != nil && len(out) == 0 {
			return doctorDoneMsg{err: fmt.Errorf("devloop doctor: %w", err)}
		}

		// Find the last JSON line in the output.
		var lastJSONLine string
		for _, ln := range strings.Split(string(out), "\n") {
			tl := strings.TrimSpace(ln)
			if strings.HasPrefix(tl, "{") && strings.HasSuffix(tl, "}") {
				lastJSONLine = tl
			}
		}
		if lastJSONLine == "" {
			return doctorDoneMsg{
				err: fmt.Errorf("devloop doctor --json: no JSON found in output"),
				raw: string(out),
			}
		}

		var parsed struct {
			Pass   int           `json:"pass"`
			Fail   int           `json:"fail"`
			Checks []DoctorCheck `json:"checks"`
		}
		if err := json.Unmarshal([]byte(lastJSONLine), &parsed); err != nil {
			return doctorDoneMsg{err: fmt.Errorf("parse doctor JSON: %w", err), raw: lastJSONLine}
		}
		return doctorDoneMsg{
			pass:   parsed.Pass,
			fail:   parsed.Fail,
			checks: parsed.Checks,
			raw:    lastJSONLine,
		}
	}
}

// streamScript runs `bash devloop.sh <args...>` and emits onLine for each
// stdout line and onDone when the subprocess exits. Stderr is folded into
// stdout so wizard users see warnings inline.
func (m OnboardModel) streamScript(devArgs []string, onLine func(string) tea.Msg, onDone func(int, error) tea.Msg) tea.Cmd {
	root := m.projectRoot
	return func() tea.Msg {
		args := append([]string{filepath.Join(root, "devloop.sh")}, devArgs...)
		cmd := exec.Command("bash", args...)
		cmd.Dir = root
		var buf bytes.Buffer
		cmd.Stdout = &buf
		cmd.Stderr = &buf
		err := cmd.Run()
		exit := 0
		if cmd.ProcessState != nil {
			exit = cmd.ProcessState.ExitCode()
		}
		// We collected the entire output; emit synthetic messages by
		// returning a tea.Cmd that produces a batch of initLineMsg + done.
		// Since tea.Msg is single-shot, return done with err — callers
		// expecting line-by-line streaming should use a richer pipeline
		// (mirroring chat's runShellCmd). For wizard scope this is fine:
		// init runs quickly and the user just sees the final outcome.
		scanner := bufio.NewScanner(&buf)
		var lines []string
		for scanner.Scan() {
			lines = append(lines, scanner.Text())
		}
		// Send as a single message that carries all lines. Update will
		// flatten them into m.initBuf.
		return initBatchMsg{lines: lines, exitCode: exit, err: err, onLine: onLine, onDone: onDone}
	}
}

// initBatchMsg is the simplified single-shot result for init streaming.
type initBatchMsg struct {
	lines    []string
	exitCode int
	err      error
	onLine   func(string) tea.Msg
	onDone   func(int, error) tea.Msg
}

// Apply applies the batch to the model. Called via Update.
func (m OnboardModel) applyInitBatch(b initBatchMsg) OnboardModel {
	m.initBuf = append(m.initBuf, b.lines...)
	return m
}

// cannedOnboard short-circuits subprocess execution for tests by emitting
// fake init lines + done + doctor done immediately.
func cannedOnboard() tea.Cmd {
	return func() tea.Msg {
		return initBatchMsg{
			lines: []string{
				"✔ Created: devloop.config.sh",
				"✔ Created: CLAUDE.md",
			},
			exitCode: 0,
		}
	}
}
