package tui

import "github.com/shaifulshabuj/devloop/v6/internal/orchestrator"

// SubmitMsg is emitted when the user presses Enter with non-empty text.
type SubmitMsg struct{ Text string }

// PlanReviewMsg is emitted after Plan() succeeds so the user can review steps.
type PlanReviewMsg struct{ Plan *orchestrator.Plan }

// OutputLineMsg carries a single agent output line to the TUI.
type OutputLineMsg struct{ Line string }

// taskResultMsg is the internal message returned when dispatch completes or errors.
type taskResultMsg struct {
	err error
}
