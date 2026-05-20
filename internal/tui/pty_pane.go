package tui

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/creack/pty"
)

const maxPaneLines = 500

// stripControlRe removes VT100 control sequences that are NOT color/style codes.
// We keep SGR sequences (\x1b[...m) for colors and strip everything else
// (cursor movement, erase, alternate-screen, etc.).
var stripControlRe = regexp.MustCompile(
	`\x1b(?:\[[\d;]*[ABCDEFGHJKLMPSTfhilnrsu]|\[[\d;]*[Rn]|[()#%!][A-Z0-9]|[78MNOPRQZ\\^_` + "`" + `]|=[0-9;]*[hl]|\][^\a]*\a)`,
)

// PtyPane is a single agent session running in a pseudo-terminal sub-panel.
type PtyPane struct {
	ID      int
	Label   string // e.g. "claude:devloop"
	Backend string // e.g. "claude"

	ptm    *os.File   // PTY master fd (read output, write input)
	cmd    *exec.Cmd
	lines  []string // captured output lines (capped at maxPaneLines)
	mu     sync.Mutex
	vp     viewport.Model
	exited bool
	width  int
	height int
}

// PanePtyLineMsg carries one output line from a running PtyPane.
type PanePtyLineMsg struct {
	PaneID int
	Line   string
}

// PanePtyExitedMsg is sent when the subprocess in a PtyPane exits.
type PanePtyExitedMsg struct{ PaneID int }

// newPtyPane spawns the named binary in a PTY and returns the PtyPane.
// initialInput, if non-empty, is written to the PTY stdin after startup.
func newPtyPane(id int, binary string, args []string, label, backend string, w, h int, initialInput string, send func(tea.Msg)) (*PtyPane, error) {
	if h < 4 {
		h = 24
	}
	if w < 10 {
		w = 80
	}

	//nolint:gosec
	cmd := exec.Command(binary, args...)
	cmd.Env = append(os.Environ(), "TERM=xterm-256color")

	ptm, err := pty.StartWithSize(cmd, &pty.Winsize{
		Rows: uint16(h),
		Cols: uint16(w),
	})
	if err != nil {
		return nil, fmt.Errorf("pty: start %q: %w", binary, err)
	}

	vp := viewport.New(w-2, h-2)
	vp.SetContent("Connecting…")

	p := &PtyPane{
		ID:      id,
		Label:   label,
		Backend: backend,
		ptm:     ptm,
		cmd:     cmd,
		vp:      vp,
		width:   w,
		height:  h,
	}

	// Write initial input after a brief chance for the process to start.
	if initialInput != "" {
		if !strings.HasSuffix(initialInput, "\n") {
			initialInput += "\n"
		}
		go func() { _, _ = io.WriteString(ptm, initialInput) }()
	}

	// Background goroutine: read PTY output, emit PanePtyLineMsg.
	go p.readLoop(send)

	return p, nil
}

// readLoop reads raw PTY output and sends PanePtyLineMsg messages.
func (p *PtyPane) readLoop(send func(tea.Msg)) {
	buf := make([]byte, 4096)
	var partial string

	for {
		n, err := p.ptm.Read(buf)
		if n > 0 {
			raw := partial + string(buf[:n])
			lines := strings.Split(raw, "\n")
			partial = lines[len(lines)-1] // might be incomplete
			for _, line := range lines[:len(lines)-1] {
				clean := cleanPtyLine(line)
				if clean == "" {
					continue
				}
				p.mu.Lock()
				p.lines = append(p.lines, clean)
				if len(p.lines) > maxPaneLines {
					p.lines = p.lines[len(p.lines)-maxPaneLines:]
				}
				p.mu.Unlock()
				send(PanePtyLineMsg{PaneID: p.ID, Line: clean})
			}
		}
		if err != nil {
			break
		}
	}

	// Flush any remaining partial line.
	if partial != "" {
		if clean := cleanPtyLine(partial); clean != "" {
			p.mu.Lock()
			p.lines = append(p.lines, clean)
			p.mu.Unlock()
			send(PanePtyLineMsg{PaneID: p.ID, Line: clean})
		}
	}

	p.mu.Lock()
	p.exited = true
	p.mu.Unlock()
	_ = p.cmd.Wait()
	send(PanePtyExitedMsg{PaneID: p.ID})
}

// cleanPtyLine strips VT100 control sequences that cause display artifacts.
// Color/style codes (SGR) are kept so that agent output retains its colors.
func cleanPtyLine(s string) string {
	// Remove carriage returns (cursor-to-column-1 without LF).
	s = strings.ReplaceAll(s, "\r", "")
	// Strip non-color control sequences.
	s = stripControlRe.ReplaceAllString(s, "")
	// Strip remaining raw ESC characters that weren't matched.
	s = strings.ReplaceAll(s, "\x1b", "")
	return strings.TrimRight(s, " \t")
}

// Write sends raw bytes to the PTY stdin (keyboard input forwarding).
func (p *PtyPane) Write(data []byte) {
	if p.ptm != nil && !p.exited {
		_, _ = p.ptm.Write(data)
	}
}

// WriteString sends a string to the PTY stdin.
func (p *PtyPane) WriteString(s string) {
	p.Write([]byte(s))
}

// Resize updates the PTY window size and viewport dimensions.
func (p *PtyPane) Resize(w, h int) {
	p.width = w
	p.height = h
	if p.ptm != nil && !p.exited {
		_ = pty.Setsize(p.ptm, &pty.Winsize{
			Rows: uint16(h),
			Cols: uint16(w),
		})
	}
	vpW := w - 2
	vpH := h - 2
	if vpW < 1 {
		vpW = 1
	}
	if vpH < 1 {
		vpH = 1
	}
	p.vp.Width = vpW
	p.vp.Height = vpH
}

// RefreshViewport rebuilds the viewport content from the current line buffer.
func (p *PtyPane) RefreshViewport() {
	p.mu.Lock()
	content := strings.Join(p.lines, "\n")
	p.mu.Unlock()
	if content == "" {
		content = "Waiting for output…"
	}
	p.vp.SetContent(content)
	p.vp.GotoBottom()
}

// Close terminates the underlying process and closes the PTY.
func (p *PtyPane) Close() {
	if p.cmd != nil && p.cmd.Process != nil {
		_ = p.cmd.Process.Kill()
	}
	if p.ptm != nil {
		_ = p.ptm.Close()
	}
}

// View renders the pane in a bordered box.
func (p *PtyPane) View(focused bool) string {
	borderColor := lipgloss.Color("#444444")
	if focused {
		borderColor = lipgloss.Color("#7c7cff")
	}

	label := p.Label
	if p.exited {
		label += " [done]"
	}

	labelStyle := lipgloss.NewStyle().Bold(true).Foreground(borderColor)
	header := labelStyle.Render("▸ " + label)

	paneStyle := lipgloss.NewStyle().
		Width(p.width).
		Height(p.height).
		BorderStyle(lipgloss.NormalBorder()).
		BorderForeground(borderColor)

	return paneStyle.Render(header + "\n" + p.vp.View())
}

// keyToBytes converts a Bubble Tea KeyMsg to the raw byte sequence for that
// key, so we can forward it to the PTY stdin.
func keyToBytes(msg tea.KeyMsg) []byte {
	switch msg.Type {
	case tea.KeyEnter:
		return []byte("\r")
	case tea.KeyBackspace:
		return []byte("\x7f")
	case tea.KeyDelete:
		return []byte("\x1b[3~")
	case tea.KeyUp:
		return []byte("\x1b[A")
	case tea.KeyDown:
		return []byte("\x1b[B")
	case tea.KeyRight:
		return []byte("\x1b[C")
	case tea.KeyLeft:
		return []byte("\x1b[D")
	case tea.KeyHome:
		return []byte("\x1b[H")
	case tea.KeyEnd:
		return []byte("\x1b[F")
	case tea.KeyPgUp:
		return []byte("\x1b[5~")
	case tea.KeyPgDown:
		return []byte("\x1b[6~")
	case tea.KeyTab:
		return []byte("\t")
	case tea.KeyEsc:
		return []byte("\x1b")
	case tea.KeyCtrlA:
		return []byte{0x01}
	case tea.KeyCtrlB:
		return []byte{0x02}
	case tea.KeyCtrlC:
		return []byte{0x03}
	case tea.KeyCtrlD:
		return []byte{0x04}
	case tea.KeyCtrlE:
		return []byte{0x05}
	case tea.KeyCtrlF:
		return []byte{0x06}
	case tea.KeyCtrlK:
		return []byte{0x0b}
	case tea.KeyCtrlL:
		return []byte{0x0c}
	case tea.KeyCtrlN:
		return []byte{0x0e}
	case tea.KeyCtrlP:
		return []byte{0x10}
	case tea.KeyCtrlR:
		return []byte{0x12}
	case tea.KeyCtrlU:
		return []byte{0x15}
	case tea.KeyCtrlW:
		return []byte{0x17}
	case tea.KeyRunes:
		return []byte(string(msg.Runes))
	case tea.KeySpace:
		return []byte(" ")
	default:
		if msg.Alt && len(msg.Runes) == 1 {
			return append([]byte{0x1b}, []byte(string(msg.Runes))...)
		}
		return []byte(msg.String())
	}
}
