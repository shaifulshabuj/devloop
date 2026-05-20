package tui

import (
	"github.com/shaifulshabuj/devloop/v6/internal/agent"
	"github.com/shaifulshabuj/devloop/v6/internal/config"
	"github.com/shaifulshabuj/devloop/v6/internal/orchestrator"
	"github.com/shaifulshabuj/devloop/v6/internal/storage"
)

// SubmitMsg is emitted when the user presses Enter with non-empty text.
type SubmitMsg struct{ Text string }

// PlanReviewMsg is emitted after Plan() succeeds so the user can review steps.
type PlanReviewMsg struct{ Plan *orchestrator.Plan }

// SkillsLoadedMsg is emitted after skills have been loaded from disk.
type SkillsLoadedMsg struct{ Skills []agent.Skill }

// ProjectsLoadedMsg is emitted after the project registry has been loaded.
type ProjectsLoadedMsg struct{ Projects []config.ProjectEntry }

// ProjectSwitchMsg is emitted when the user selects a project from the sidebar.
type ProjectSwitchMsg struct{ Path string }

// PersonasLoadedMsg is emitted after personas have been loaded.
type PersonasLoadedMsg struct{ Personas []agent.Persona }

// CostSummaryMsg is emitted after cost data has been computed from the store.
type CostSummaryMsg struct{ Costs []storage.TaskCost }

// SplitViewMsg signals that parallel dispatch is starting with N steps.
type SplitViewMsg struct{ Steps []orchestrator.Step }

// PaneOutputMsg delivers a completed step result to a specific parallel pane.
type PaneOutputMsg struct {
	PaneIndex int
	Line      string
}

// OutputLineMsg carries a single agent output line to the TUI.
type OutputLineMsg struct{ Line string }

// taskResultMsg is the internal message returned when dispatch completes or errors.
type taskResultMsg struct {
	err error
}
