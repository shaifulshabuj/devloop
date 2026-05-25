package views

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/shaifulshabuj/devloop/devloop-tui/internal/components"
	"github.com/shaifulshabuj/devloop/devloop-tui/internal/stream"
	"github.com/shaifulshabuj/devloop/devloop-tui/internal/theme"
	"github.com/shaifulshabuj/devloop/devloop-tui/internal/uimsg"
)

// ─── Line kinds ───────────────────────────────────────────────────────────────

type lineKind int

const (
	lineInput  lineKind = iota // "> /run …"
	lineOutput                 // dim, indented command output
	lineInfo                   // informational message (help text, etc.)
	lineError                  // error message
)

type chatLine struct {
	Kind  lineKind
	Text  string
	Time  time.Time
	CmdID int // 0 = not associated with a subprocess
}

// ─── Slash command registry ───────────────────────────────────────────────────

// slashCmd describes one slash command for autocomplete and /help.
type slashCmd struct {
	Name string // "/run"
	Args string // "<feature>" — empty if command takes no args
	Hint string // one-line description
}

const maxSuggestions = 5

// allSlashCmds is the canonical list used by autocomplete and /help.
var allSlashCmds = []slashCmd{
	{"/ask", "<question>", "ask a question about the project"},
	{"/run", "<feature>", "full pipeline: architect+work+review"},
	{"/plan", "<feature>", "design a spec (devloop architect)"},
	{"/fix", "[TASK-ID]", "apply fix pass"},
	{"/status", "[TASK-ID]", "show pipeline status inline"},
	{"/diff", "[TASK-ID]", "git diff from baseline"},
	{"/skip", "<phase>", "mark phase as skipped"},
	{"/rollback", "", "git reset to session baseline"},
	{"/mode", "ask|code|auto", "set session mode"},
	{"/help", "", "show available commands"},
	{"/quit", "", "quit the TUI"},
}

// ─── Subprocess messages ──────────────────────────────────────────────────────

type cmdStartedMsg struct {
	id     int
	cancel func()
}

type cmdLineMsg struct {
	id   int
	line string
}

type cmdDoneMsg struct {
	id       int
	exitCode int
}

// ─── Running command tracker ──────────────────────────────────────────────────

type runningCmd struct {
	id     int
	name   string
	cancel func()
	lines  chan string
}

// ─── Options / constructor surface ───────────────────────────────────────────

// ChatOptions configures ChatModel construction.
type ChatOptions struct {
	// NoSubprocess skips actual exec and echoes the command back as output
	// instead. Used in tests.
	NoSubprocess bool
	// StartMode is "ask" | "code" | "auto". Defaults to "auto".
	StartMode string
}

// ChatModel is the slash-command REPL view.
type ChatModel struct {
	projectRoot    string
	opts           ChatOptions
	mode           string
	currentSession string // newest TASK-… ID, "" if none
	scrollback     []chatLine
	scrollOffset   int // lines from the bottom; 0 = pinned to bottom
	input          textinput.Model
	width          int
	height         int
	running        map[int]*runningCmd
	nextCmdID      int
	lastCmdID      int // most recently started command (for ctrl+c)
	suggestionIdx  int // -1 = no selection; index into activeSuggestions()
	// testHook is called with ("run"|"plan"|"fix"|"diff", feature) in NoSubprocess
	// mode so tests can assert on the dispatched command without exec.
	testHook func(command, arg string)

	// two-esc quit tracking
	lastEscAt time.Time
}

// NewChat constructs a live ChatModel.
func NewChat(projectRoot string) ChatModel {
	return NewChatWithOptions(projectRoot, ChatOptions{})
}

// NewChatWithOptions constructs a ChatModel with explicit options.
func NewChatWithOptions(projectRoot string, opts ChatOptions) ChatModel {
	mode := opts.StartMode
	if mode == "" {
		mode = "auto"
	}

	ti := textinput.New()
	ti.Placeholder = "type a command or natural-language feature…"
	ti.Prompt = "❯ "
	ti.PromptStyle = lipgloss.NewStyle().Foreground(theme.Purple)
	ti.Focus()

	m := ChatModel{
		projectRoot:   projectRoot,
		opts:          opts,
		mode:          mode,
		input:         ti,
		running:       make(map[int]*runningCmd),
		nextCmdID:     1,
		suggestionIdx: -1,
	}

	// Find the newest session on disk.
	m.currentSession = m.resolveNewestSession("")
	return m
}

// ─── Init ─────────────────────────────────────────────────────────────────────

func (m ChatModel) Init() tea.Cmd {
	return textinput.Blink
}

// ─── Update ───────────────────────────────────────────────────────────────────

func (m ChatModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmds []tea.Cmd

	switch msg := msg.(type) {

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height

	case uimsg.PaletteRun:
		// Command palette handed off a devloop subcommand. Run it through
		// the existing dispatchShell so output streams into the scrollback
		// like any other slash-command invocation.
		var batch []tea.Cmd
		m, batch = m.dispatchShell(msg.Command, msg.Arg)
		return m, tea.Batch(batch...)

	case tea.KeyMsg:
		// ctrl+c cancels the most-recent running command but does NOT quit.
		if msg.Type == tea.KeyCtrlC {
			if rc, ok := m.running[m.lastCmdID]; ok {
				rc.cancel()
				m = m.appendLine(lineInfo, fmt.Sprintf("[#%d] cancelled", m.lastCmdID), 0)
			}
			return m, nil
		}

		// Two-esc-in-succession quits.
		if msg.Type == tea.KeyEsc {
			now := time.Now()
			if now.Sub(m.lastEscAt) < 600*time.Millisecond {
				return m, tea.Quit
			}
			m.lastEscAt = now
			m.suggestionIdx = -1
			if m.scrollOffset > 0 {
				m.scrollOffset = 0
			}
			return m, nil
		}

		// PageUp / PageDown scroll the scrollback.
		if msg.Type == tea.KeyPgUp {
			pageSize := m.pageSize()
			m.scrollOffset += pageSize
			maxOff := m.maxScrollOffset()
			if m.scrollOffset > maxOff {
				m.scrollOffset = maxOff
			}
			return m, nil
		}
		if msg.Type == tea.KeyPgDown {
			m.scrollOffset -= m.pageSize()
			if m.scrollOffset < 0 {
				m.scrollOffset = 0
			}
			return m, nil
		}

		// Suggestion navigation: intercept ↑ ↓ Tab before normal key handling.
		if suggs := m.activeSuggestions(); len(suggs) > 0 {
			switch msg.Type {
			case tea.KeyUp:
				m.suggestionIdx--
				if m.suggestionIdx < -1 {
					m.suggestionIdx = len(suggs) - 1
				}
				return m, nil
			case tea.KeyDown:
				m.suggestionIdx++
				if m.suggestionIdx >= len(suggs) {
					m.suggestionIdx = -1
				}
				return m, nil
			case tea.KeyTab:
				idx := m.suggestionIdx
				if idx < 0 {
					idx = 0
				}
				if idx < len(suggs) {
					s := suggs[idx]
					if s.Args != "" {
						m.input.SetValue(s.Name + " ")
					} else {
						m.input.SetValue(s.Name)
					}
					m.input.CursorEnd()
					m.suggestionIdx = -1
				}
				return m, nil
			}
		}

		// Any other key while scrolled back: snap to bottom.
		if m.scrollOffset > 0 && msg.Type != tea.KeyEnter {
			m.scrollOffset = 0
		}

		if msg.Type == tea.KeyEnter {
			// If a suggestion is highlighted, complete it first.
			if m.suggestionIdx >= 0 {
				if suggs := m.activeSuggestions(); m.suggestionIdx < len(suggs) {
					s := suggs[m.suggestionIdx]
					m.suggestionIdx = -1
					if s.Args != "" {
						// Command needs an arg — fill the name and let the user type.
						m.input.SetValue(s.Name + " ")
						m.input.CursorEnd()
						return m, nil
					}
					// No args — fall through with the completed command.
					m.input.SetValue(s.Name)
				}
			}

			m.scrollOffset = 0
			text := strings.TrimSpace(m.input.Value())
			m.input.SetValue("")
			m.suggestionIdx = -1
			if text == "" {
				return m, nil
			}
			// Echo input.
			m = m.appendLine(lineInput, "> "+text, 0)
			// Dispatch.
			newM, dispatchCmds := m.dispatch(text)
			m = newM
			cmds = append(cmds, dispatchCmds...)
			return m, tea.Batch(cmds...)
		}

		// Delegate everything else to the textinput.
		var tiCmd tea.Cmd
		m.input, tiCmd = m.input.Update(msg)
		cmds = append(cmds, tiCmd)
		// Reset suggestion selection whenever the input text changes.
		m.suggestionIdx = -1

	// ── Subprocess messages ────────────────────────────────────────────────

	case cmdStartedMsg:
		_ = msg

	case cmdLineMsg:
		prefix := fmt.Sprintf("[#%d] ", msg.id)
		m = m.appendLine(lineOutput, prefix+msg.line, msg.id)
		if rc, ok := m.running[msg.id]; ok {
			cmds = append(cmds, readNextLine(rc))
		}

	case cmdDoneMsg:
		if msg.exitCode != 0 {
			m = m.appendLine(lineError,
				fmt.Sprintf("[#%d] exited with code %d", msg.id, msg.exitCode), msg.id)
		} else {
			m = m.appendLine(lineInfo,
				fmt.Sprintf("[#%d] done", msg.id), msg.id)
		}
		delete(m.running, msg.id)
		m.currentSession = m.resolveNewestSession(m.currentSession)
	}

	return m, tea.Batch(cmds...)
}

// ─── View ─────────────────────────────────────────────────────────────────────

var (
	styleHeader = lipgloss.NewStyle().
			Bold(true).
			Foreground(theme.Purple).
			BorderStyle(lipgloss.NormalBorder()).
			BorderBottom(true).
			BorderForeground(theme.Dim)

	styleInputLine = lipgloss.NewStyle().
			BorderStyle(lipgloss.NormalBorder()).
			BorderTop(true).
			BorderForeground(theme.Dim)

	styleLineInput  = lipgloss.NewStyle().Foreground(theme.Text).Bold(true)
	styleLineOutput = lipgloss.NewStyle().Faint(true).PaddingLeft(2)
	styleLineInfo   = lipgloss.NewStyle().Faint(true).Foreground(theme.Blue)
	styleLineError  = lipgloss.NewStyle().Foreground(theme.Red)

	// Suggestion popup styles.
	styleSuggestCmd = lipgloss.NewStyle().Foreground(theme.Purple)
	styleSuggestDim = lipgloss.NewStyle().Foreground(theme.Dim)
	styleSuggestSel = lipgloss.NewStyle().
			Background(lipgloss.Color("#0d2244")).
			Foreground(theme.Text)
)

func (m ChatModel) View() string {
	w := m.width
	if w <= 0 {
		w = 120
	}
	h := m.height
	if h <= 0 {
		h = 30
	}

	sessionLabel := m.currentSession
	if sessionLabel == "" {
		sessionLabel = "—"
	}

	header := styleHeader.Width(w).Render(
		fmt.Sprintf("Chat  ·  mode: %s  ·  session: %s", m.mode, sessionLabel),
	)
	inputArea := styleInputLine.Width(w).Render(m.input.View())

	// Suggestion popup: rendered between scrollback and input.
	suggs := m.activeSuggestions()
	suggestView := m.renderSuggestions(suggs, w)
	suggestH := len(suggs)
	if suggestH > maxSuggestions {
		suggestH = maxSuggestions
	}

	headerH := 2
	inputH := 2
	scrollH := h - headerH - inputH - suggestH
	if scrollH < 1 {
		scrollH = 1
	}

	scrollView := m.renderScrollback(w, scrollH)

	parts := []string{header, scrollView}
	if suggestView != "" {
		parts = append(parts, suggestView)
	}
	parts = append(parts, inputArea)
	return lipgloss.JoinVertical(lipgloss.Left, parts...)
}

// activeSuggestions returns the filtered slash commands matching the current
// input. Returns nil when the input is not a slash prefix or is already a
// complete unambiguous command.
func (m ChatModel) activeSuggestions() []slashCmd {
	val := m.input.Value()
	if !strings.HasPrefix(val, "/") || strings.ContainsRune(val, ' ') {
		return nil
	}
	q := strings.ToLower(val)
	var out []slashCmd
	for _, c := range allSlashCmds {
		if strings.HasPrefix(c.Name, q) {
			out = append(out, c)
		}
	}
	// Hide when the input is already an exact unambiguous command.
	if len(out) == 1 && out[0].Name == q {
		return nil
	}
	if len(out) > maxSuggestions {
		out = out[:maxSuggestions]
	}
	return out
}

// renderSuggestions renders the autocomplete popup. Selected row gets a blue
// highlight; others show the command name in purple and hint in dim.
func (m ChatModel) renderSuggestions(suggs []slashCmd, w int) string {
	if len(suggs) == 0 {
		return ""
	}
	var rows []string
	for i, s := range suggs {
		if i == m.suggestionIdx {
			text := "  " + s.Name
			if s.Args != "" {
				text += " " + s.Args
			}
			text += "  " + s.Hint
			rows = append(rows, styleSuggestSel.Width(w).Render(text))
		} else {
			name := styleSuggestCmd.Render("  " + s.Name)
			rest := ""
			if s.Args != "" {
				rest += styleSuggestDim.Render(" " + s.Args)
			}
			rest += styleSuggestDim.Render("  " + s.Hint)
			rows = append(rows, name+rest)
		}
	}
	return strings.Join(rows, "\n")
}

// renderScrollback renders the scrollback region clipped to scrollH lines.
func (m ChatModel) renderScrollback(w, scrollH int) string {
	var rendered []string
	for _, cl := range m.scrollback {
		rendered = append(rendered, m.renderLine(cl, w))
	}

	total := len(rendered)
	if total == 0 {
		hint := lipgloss.NewStyle().Faint(true).Render("type / to see commands, or describe a feature")
		return lipgloss.NewStyle().Width(w).Height(scrollH).Render(hint)
	}

	maxOff := total - scrollH
	if maxOff < 0 {
		maxOff = 0
	}
	off := m.scrollOffset
	if off > maxOff {
		off = maxOff
	}

	end := total - off
	start := end - scrollH
	if start < 0 {
		start = 0
	}
	window := rendered[start:end]

	for len(window) < scrollH {
		window = append([]string{""}, window...)
	}

	return lipgloss.NewStyle().Width(w).Height(scrollH).Render(
		strings.Join(window, "\n"),
	)
}

func (m ChatModel) renderLine(cl chatLine, w int) string {
	switch cl.Kind {
	case lineInput:
		return styleLineInput.Width(w).Render(cl.Text)
	case lineOutput:
		return styleLineOutput.Width(w).Render(cl.Text)
	case lineInfo:
		return styleLineInfo.Width(w).Render(cl.Text)
	case lineError:
		return styleLineError.Width(w).Render(cl.Text)
	}
	return cl.Text
}

// ─── Command dispatch ─────────────────────────────────────────────────────────

// dispatch parses text and returns an updated model + commands to run.
func (m ChatModel) dispatch(text string) (ChatModel, []tea.Cmd) {
	// Natural-language → /run
	if !strings.HasPrefix(text, "/") {
		return m.dispatchShell("run", text)
	}

	parts := strings.Fields(text)
	cmd := strings.ToLower(parts[0])
	rest := ""
	if len(parts) > 1 {
		rest = strings.Join(parts[1:], " ")
	}

	switch cmd {
	case "/help":
		return m.doHelp(), nil

	case "/quit", "/exit":
		return m, []tea.Cmd{tea.Quit}

	case "/ask":
		if rest == "" {
			m = m.appendLine(lineError, "usage: /ask <question>", 0)
			return m, nil
		}
		return m.dispatchShell("ask", rest)

	case "/plan":
		if rest == "" {
			m = m.appendLine(lineError, "usage: /plan <feature>", 0)
			return m, nil
		}
		return m.dispatchShell("architect", rest)

	case "/run":
		if rest == "" {
			m = m.appendLine(lineError, "usage: /run <feature>", 0)
			return m, nil
		}
		return m.dispatchShell("run", rest)

	case "/fix":
		return m.dispatchShell("fix", rest)

	case "/status":
		return m.doStatus(rest), nil

	case "/diff":
		return m.dispatchShell("diff", rest)

	case "/skip":
		if rest == "" {
			m = m.appendLine(lineError, "usage: /skip <phase>", 0)
			return m, nil
		}
		return m.doSkip(rest)

	case "/rollback":
		return m.doRollback()

	case "/inbox":
		m = m.appendLine(lineInfo,
			`inbox view lands in Phase 4 — use "devloop inbox" in the terminal for now`, 0)
		return m, nil

	case "/mode":
		return m.doMode(rest), nil

	default:
		m = m.appendLine(lineError, fmt.Sprintf("unknown command %q — type / to see commands", cmd), 0)
		return m, nil
	}
}

// ─── /help ────────────────────────────────────────────────────────────────────

func (m ChatModel) doHelp() ChatModel {
	m = m.appendLine(lineInfo, "Available commands:", 0)
	for _, c := range allSlashCmds {
		line := fmt.Sprintf("  %-22s — %s", c.Name+" "+c.Args, c.Hint)
		m = m.appendLine(lineInfo, line, 0)
	}
	m = m.appendLine(lineInfo, "", 0)
	m = m.appendLine(lineInfo, "  Bare text is treated as /run <text>.", 0)
	m = m.appendLine(lineInfo, "  Type / and use ↑↓ Tab to navigate commands.", 0)
	return m
}

// ─── /status ──────────────────────────────────────────────────────────────────

func (m ChatModel) doStatus(arg string) ChatModel {
	id := m.resolveID(arg)
	if id == "" {
		m = m.appendLine(lineError, "no sessions found", 0)
		return m
	}
	sessions, err := stream.Scan(m.projectRoot)
	if err != nil {
		m = m.appendLine(lineError, "scan error: "+err.Error(), 0)
		return m
	}
	var sess *stream.Session
	for i := range sessions {
		if sessions[i].ID == id {
			sess = &sessions[i]
			break
		}
	}
	if sess == nil {
		m = m.appendLine(lineError, "session not found: "+id, 0)
		return m
	}

	m.currentSession = id

	phases := buildPhases(sess)
	grid := components.Render(phases, components.GridOptions{
		Width:   m.width - 4,
		Compact: false,
	})

	m = m.appendLine(lineInfo, fmt.Sprintf("Status for %s  [%s]", sess.Feature, id), 0)
	for _, l := range strings.Split(grid, "\n") {
		m = m.appendLine(lineOutput, "  "+l, 0)
	}
	return m
}

// ─── /mode ────────────────────────────────────────────────────────────────────

func (m ChatModel) doMode(arg string) ChatModel {
	switch arg {
	case "ask", "code", "auto":
		m.mode = arg
		if id := m.resolveNewestSession(m.currentSession); id != "" {
			sessionDir := filepath.Join(m.projectRoot, ".devloop", "sessions", id)
			_ = os.MkdirAll(sessionDir, 0o755)
			_ = os.WriteFile(filepath.Join(sessionDir, "mode"), []byte(arg+"\n"), 0o644)
		}
		m = m.appendLine(lineInfo, "mode set to "+arg, 0)
	case "":
		m = m.appendLine(lineError, "usage: /mode ask|code|auto", 0)
	default:
		m = m.appendLine(lineError, fmt.Sprintf("unknown mode %q — use ask, code, or auto", arg), 0)
	}
	return m
}

// ─── /skip ────────────────────────────────────────────────────────────────────

func (m ChatModel) doSkip(phase string) (ChatModel, []tea.Cmd) {
	id := m.resolveNewestSession(m.currentSession)
	if id == "" {
		m = m.appendLine(lineError, "no active session to skip phase in", 0)
		return m, nil
	}
	sessionDir := filepath.Join(m.projectRoot, ".devloop", "sessions", id)
	ts := time.Now().Format("2006-01-02T15:04:05")
	stateContent := "skipped:" + ts
	stateFile := filepath.Join(sessionDir, phase+".state")
	if err := os.WriteFile(stateFile, []byte(stateContent), 0o644); err != nil {
		m = m.appendLine(lineError, "failed to write state: "+err.Error(), 0)
		return m, nil
	}

	event := map[string]string{
		"ts":      time.Now().UTC().Format(time.RFC3339),
		"kind":    "phase.end",
		"session": id,
		"phase":   phase,
		"status":  "skipped",
	}
	if b, err := json.Marshal(event); err == nil {
		eventsFile := filepath.Join(m.projectRoot, ".devloop", "events.ndjson")
		f, ferr := os.OpenFile(eventsFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if ferr == nil {
			_, _ = fmt.Fprintf(f, "%s\n", b)
			_ = f.Close()
		}
	}

	m = m.appendLine(lineInfo, fmt.Sprintf("phase %q marked as skipped", phase), 0)
	return m, nil
}

// ─── /rollback ────────────────────────────────────────────────────────────────

func (m ChatModel) doRollback() (ChatModel, []tea.Cmd) {
	id := m.resolveNewestSession(m.currentSession)
	if id == "" {
		m = m.appendLine(lineError, "no active session to roll back", 0)
		return m, nil
	}
	specsPath := filepath.Join(m.projectRoot, ".devloop", "specs")
	baselineFile := filepath.Join(specsPath, id+".pre-commit")
	hashBytes, err := os.ReadFile(baselineFile)
	if err != nil {
		m = m.appendLine(lineError, "no baseline file found for "+id+" — refusing rollback", 0)
		return m, nil
	}
	hash := strings.TrimSpace(string(hashBytes))
	if hash == "" {
		m = m.appendLine(lineError, "baseline file is empty — refusing rollback", 0)
		return m, nil
	}
	return m.dispatchShell("_rollback", hash)
}

// ─── Shell dispatch ───────────────────────────────────────────────────────────

func (m ChatModel) dispatchShell(command, arg string) (ChatModel, []tea.Cmd) {
	if m.opts.NoSubprocess {
		id := m.nextCmdID
		m.nextCmdID++
		m.lastCmdID = id
		if m.testHook != nil {
			m.testHook(command, arg)
		}
		fakeCmd := func() tea.Msg {
			return cmdLineMsg{id: id, line: fmt.Sprintf("(no-subprocess) %s %s", command, arg)}
		}
		fakeCmd2 := func() tea.Msg {
			return cmdLineMsg{id: id, line: "(no-subprocess) output line 2"}
		}
		fakeDone := func() tea.Msg {
			return cmdDoneMsg{id: id, exitCode: 0}
		}
		return m, []tea.Cmd{fakeCmd, fakeCmd2, fakeDone}
	}

	argv := m.buildArgv(command, arg)
	id := m.nextCmdID
	m.nextCmdID++
	m.lastCmdID = id

	rc := &runningCmd{id: id, name: command}
	m.running[id] = rc

	label := command
	if arg != "" {
		label += " " + arg
	}
	m = m.appendLine(lineInfo, fmt.Sprintf("[#%d] running: %s", id, label), id)

	startCmd := runShellCmd(id, argv, m.projectRoot, rc)
	return m, []tea.Cmd{startCmd}
}

func (m ChatModel) buildArgv(command, arg string) []string {
	dl := func(sub ...string) []string { return devloopInvocation(m.projectRoot, sub...) }
	switch command {
	case "architect":
		return dl("architect", arg)
	case "run":
		return dl("run", arg)
	case "ask":
		return dl("ask", arg)
	case "fix":
		if arg != "" {
			return dl("fix", arg)
		}
		return dl("fix")
	case "diff":
		id := m.resolveID(arg)
		specsPath := filepath.Join(m.projectRoot, ".devloop", "specs")
		baselineFile := filepath.Join(specsPath, id+".pre-commit")
		if hashBytes, err := os.ReadFile(baselineFile); err == nil {
			hash := strings.TrimSpace(string(hashBytes))
			if hash != "" {
				return []string{"git", "-C", m.projectRoot, "diff", hash}
			}
		}
		return []string{"git", "-C", m.projectRoot, "diff", "HEAD"}
	case "_rollback":
		return []string{"git", "-C", m.projectRoot, "reset", "--hard", arg}
	default:
		parts := strings.Fields(command)
		if arg != "" {
			parts = append(parts, arg)
		}
		return dl(parts...)
	}
}

// ─── Subprocess streaming ─────────────────────────────────────────────────────

func runShellCmd(id int, argv []string, cwd string, rc *runningCmd) tea.Cmd {
	return func() tea.Msg {
		cmd := exec.Command(argv[0], argv[1:]...)
		cmd.Dir = cwd
		cmd.Env = os.Environ()

		stdout, err := cmd.StdoutPipe()
		if err != nil {
			return cmdDoneMsg{id: id, exitCode: 1}
		}
		cmd.Stderr = cmd.Stdout

		if err := cmd.Start(); err != nil {
			return cmdDoneMsg{id: id, exitCode: 1}
		}

		lines := make(chan string, 64)
		rc.lines = lines
		rc.cancel = func() {
			if cmd.Process != nil {
				_ = cmd.Process.Signal(os.Interrupt)
			}
		}

		go func() {
			sc := bufio.NewScanner(stdout)
			for sc.Scan() {
				lines <- sc.Text()
			}
			_ = cmd.Wait()
			close(lines)
		}()

		return readNextLine(rc)()
	}
}

func readNextLine(rc *runningCmd) tea.Cmd {
	id := rc.id
	ch := rc.lines
	return func() tea.Msg {
		line, ok := <-ch
		if !ok {
			return cmdDoneMsg{id: id, exitCode: exitCodeFromClosed(ch)}
		}
		return cmdLineMsg{id: id, line: line}
	}
}

func exitCodeFromClosed(_ chan string) int { return 0 }

// ─── Session helpers ──────────────────────────────────────────────────────────

func (m ChatModel) resolveNewestSession(prefer string) string {
	sessions, err := stream.Scan(m.projectRoot)
	if err != nil || len(sessions) == 0 {
		return ""
	}
	if prefer != "" {
		for _, s := range sessions {
			if s.ID == prefer {
				return prefer
			}
		}
	}
	return sessions[0].ID
}

func (m ChatModel) resolveID(arg string) string {
	if strings.HasPrefix(arg, "TASK-") {
		return arg
	}
	if m.currentSession != "" {
		return m.currentSession
	}
	return m.resolveNewestSession("")
}

// ─── Scrollback helpers ───────────────────────────────────────────────────────

func (m ChatModel) appendLine(kind lineKind, text string, cmdID int) ChatModel {
	m.scrollback = append(m.scrollback, chatLine{
		Kind:  kind,
		Text:  text,
		Time:  time.Now(),
		CmdID: cmdID,
	})
	return m
}

func (m ChatModel) pageSize() int {
	ps := m.height - 4
	if ps < 1 {
		ps = 5
	}
	return ps
}

func (m ChatModel) maxScrollOffset() int {
	scrollH := m.height - 4
	if scrollH < 1 {
		scrollH = 1
	}
	n := len(m.scrollback) - scrollH
	if n < 0 {
		return 0
	}
	return n
}

var _syncMapSentinel sync.Map
