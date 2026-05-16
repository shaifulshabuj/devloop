package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/shaifulshabuj/devloop/devloop-tui/internal/app"
)

const Version = "0.1.0"

func main() {
	args := os.Args[1:]

	// Handle flags before subcommand dispatch so that e.g.
	// "devloop-tui dashboard --version" still works.
	for _, a := range args {
		switch a {
		case "-v", "--version":
			fmt.Printf("devloop-tui v%s\n", Version)
			os.Exit(0)
		case "-h", "--help":
			printUsage()
			os.Exit(0)
		}
	}

	// Determine subcommand.  The default is "dashboard".
	sub := "dashboard"
	if len(args) > 0 && args[0] != "" && args[0][0] != '-' {
		sub = args[0]
	}

	switch sub {
	case "dashboard":
		runDashboard()
	case "chat":
		runChat(args[1:])
	case "status":
		runStatus(args[1:])
	default:
		fmt.Fprintf(os.Stderr, "unknown subcommand: %s\n", sub)
		fmt.Fprintf(os.Stderr, "Run 'devloop-tui --help' for usage.\n")
		os.Exit(2)
	}
}

// runDashboard resolves the project root and starts the dashboard in an
// alternate screen.
func runDashboard() {
	root, err := resolveProjectRoot()
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
	m := app.NewApp(app.Options{
		ProjectRoot: root,
		Start:       app.ViewDashboard,
	})
	p := tea.NewProgram(m, tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

// runChat launches the chat REPL view.
// Flags: --mode ask|code|auto (default "auto")
func runChat(args []string) {
	mode := "auto"
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--mode":
			if i+1 < len(args) {
				mode = args[i+1]
				i++
			}
		}
	}

	root, err := resolveProjectRoot()
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}

	m := app.NewApp(app.Options{
		ProjectRoot: root,
		Start:       app.ViewChat,
		ChatMode:    mode,
	})
	p := tea.NewProgram(m, tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

// runStatus launches the run-view focused on a single session.
// Positional arg: TASK-ID. If omitted, picks the newest session from .devloop/sessions/.
func runStatus(args []string) {
	root, err := resolveProjectRoot()
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}

	taskID := ""
	for _, a := range args {
		if a == "" || a[0] == '-' {
			continue
		}
		taskID = a
		break
	}
	if taskID == "" {
		taskID = newestSession(root) // returns "" if none
	}
	if taskID == "" {
		fmt.Fprintln(os.Stderr, "no sessions found under .devloop/sessions/")
		os.Exit(1)
	}

	m := app.NewApp(app.Options{
		ProjectRoot: root,
		Start:       app.ViewRun,
		RunTaskID:   taskID,
	})
	p := tea.NewProgram(m, tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

// newestSession returns the newest TASK-* directory name under root/.devloop/sessions/,
// or empty string if none exist. Sort by name (TASK-IDs are timestamp-based, so name
// sort == chronological).
func newestSession(root string) string {
	entries, err := os.ReadDir(filepath.Join(root, ".devloop", "sessions"))
	if err != nil {
		return ""
	}
	var newest string
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.HasPrefix(name, "TASK-") {
			continue
		}
		if name > newest {
			newest = name
		}
	}
	return newest
}

// resolveProjectRoot walks upward from the working directory looking for a
// .devloop/ directory or devloop.config.sh — the same heuristic the bash
// engine uses via find_project_root.  If the DEVLOOP_ROOT environment variable
// is set it wins unconditionally.  Falls back to cwd if nothing is found.
func resolveProjectRoot() (string, error) {
	if env := os.Getenv("DEVLOOP_ROOT"); env != "" {
		return filepath.Abs(env)
	}
	cwd, err := os.Getwd()
	if err != nil {
		return "", err
	}
	dir := cwd
	for {
		if _, err := os.Stat(filepath.Join(dir, ".devloop")); err == nil {
			return dir, nil
		}
		if _, err := os.Stat(filepath.Join(dir, "devloop.config.sh")); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			// Reached filesystem root without finding a marker.
			return cwd, nil
		}
		dir = parent
	}
}

func printUsage() {
	fmt.Printf(`devloop-tui v%s

A terminal dashboard for the devloop multi-agent pipeline.

Usage:
  devloop-tui [subcommand] [flags]

Subcommands:
  dashboard   Open the session dashboard (default when no subcommand given)
  chat        Open the slash-command REPL
                Flags: --mode ask|code|auto
  status      Open the live single-session view
                Positional: [TASK-ID]  (defaults to newest session)

Flags:
  -v, --version   Print version and exit
  -h, --help      Print this help and exit

Examples:
  devloop-tui                    # launch the dashboard
  devloop-tui dashboard          # same as above
  devloop-tui chat               # open chat REPL (mode: auto)
  devloop-tui chat --mode ask    # open chat in ask mode
  devloop-tui status             # open run view for newest session
  devloop-tui status TASK-001    # open run view for a specific task
  devloop-tui --version          # print version
`, Version)
}
