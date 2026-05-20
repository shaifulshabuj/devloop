package tui

// SubmitMsg is emitted when the user presses Enter with non-empty text.
type SubmitMsg struct{ Text string }

// OutputLineMsg carries a single agent output line to the TUI.
type OutputLineMsg struct{ Line string }

// taskResultMsg is the internal message returned when plan+dispatch completes.
type taskResultMsg struct {
	lines []string
	err   error
}
