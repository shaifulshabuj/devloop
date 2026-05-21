// Package uimsg defines tea.Msg types passed between sibling packages
// (views, components) and the root app router. Living in its own leaf
// package means dashboard.go can emit a message that app.go consumes
// without creating an import cycle between `internal/views` and
// `internal/app`.
//
// As of Phase 1 only the Focus-Mode transition messages live here.
// SwitchViewMsg stays in `internal/app` because nothing outside the
// router needs to type-check it. New cross-cutting message types
// should be added here rather than in `views`.
package uimsg

// OpenFocus requests transition to Focus Mode for a specific task. The
// dashboard emits this on `enter`. The app router (P2-5) will switch to
// ViewFocus and pass through the index/ID. Phase 1 emits but no receiver
// exists yet — until P2-5 lands the router drops it harmlessly.
type OpenFocus struct {
	// SessionIdx is the position in the dashboard's session slice at the
	// moment Enter was pressed.
	SessionIdx int
	// SessionID is the resolved TASK-ID, included so the receiver doesn't
	// have to re-scan the session list to translate index → ID.
	SessionID string
}

// CloseFocus requests transition back from Focus Mode to Dashboard. Phase 2
// (P2-5) emits this on `esc` from Focus Mode.
type CloseFocus struct{}
