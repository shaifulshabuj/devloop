package orchestrator_test

import (
	"context"
	"testing"

	"github.com/shaifulshabuj/devloop/v6/internal/agent"
	"github.com/shaifulshabuj/devloop/v6/internal/orchestrator"
)

// TestDispatch_SingleStep verifies that Dispatch handles a single-step plan
// where the backend does not exist: it should return a DispatchResult with
// exactly one StepResult carrying a non-nil Error.
func TestDispatch_SingleStep(t *testing.T) {
	store := newTestStore(t)
	runner := agent.NewRunner()
	d := orchestrator.NewDispatcher(store, runner)

	plan := &orchestrator.Plan{
		ID:    "dispatch-single-plan",
		Title: "Single Step Plan",
		Steps: []orchestrator.Step{
			{
				Number:      1,
				Description: "Do something",
				Backend:     "nonexistent-backend-xyz",
				Model:       "test-model",
				Status:      "pending",
			},
		},
	}

	// Ensure the task exists in the store so UpdateTaskStatus has a row to update.
	if err := store.CreateTask(plan.ID, plan.Title); err != nil {
		t.Fatalf("CreateTask: %v", err)
	}

	result, err := d.Dispatch(context.Background(), plan)

	if err == nil {
		t.Error("Dispatch: expected a non-nil error for nonexistent backend")
	}
	if result == nil {
		t.Fatal("Dispatch: returned nil DispatchResult, want non-nil")
	}
	if result.PlanID != plan.ID {
		t.Errorf("DispatchResult.PlanID = %q, want %q", result.PlanID, plan.ID)
	}
	if len(result.Results) != 1 {
		t.Fatalf("len(DispatchResult.Results) = %d, want 1", len(result.Results))
	}
	if result.Results[0].Error == nil {
		t.Error("StepResult.Error should be non-nil for failed backend spawn")
	}
	if result.Results[0].Step.Number != 1 {
		t.Errorf("StepResult.Step.Number = %d, want 1", result.Results[0].Step.Number)
	}
}

// TestDispatch_ContextAccumulation verifies that Dispatch continues executing
// subsequent steps even after earlier steps fail, and that both steps produce
// a StepResult. This exercises the context-accumulation path: the second step
// would receive the first step's output as context if it were available.
func TestDispatch_ContextAccumulation(t *testing.T) {
	store := newTestStore(t)
	runner := agent.NewRunner()
	d := orchestrator.NewDispatcher(store, runner)

	plan := &orchestrator.Plan{
		ID:    "dispatch-context-plan",
		Title: "Multi-Step Context Plan",
		Steps: []orchestrator.Step{
			{
				Number:      1,
				Description: "First step",
				Backend:     "nonexistent-backend-xyz",
				Model:       "test-model",
				Status:      "pending",
			},
			{
				Number:      2,
				Description: "Second step",
				Backend:     "nonexistent-backend-xyz",
				Model:       "test-model",
				Status:      "pending",
			},
		},
	}

	if err := store.CreateTask(plan.ID, plan.Title); err != nil {
		t.Fatalf("CreateTask: %v", err)
	}

	result, err := d.Dispatch(context.Background(), plan)

	if err == nil {
		t.Error("Dispatch: expected a non-nil error for nonexistent backend")
	}
	if result == nil {
		t.Fatal("Dispatch: returned nil DispatchResult, want non-nil")
	}
	// Both steps must have been attempted — context accumulation requires both to run.
	if len(result.Results) != 2 {
		t.Fatalf("len(DispatchResult.Results) = %d, want 2 (both steps attempted)", len(result.Results))
	}
	if result.Results[0].Error == nil {
		t.Error("StepResult[0].Error should be non-nil")
	}
	if result.Results[1].Error == nil {
		t.Error("StepResult[1].Error should be non-nil")
	}
	// Confirm step identity is preserved in the results.
	if result.Results[0].Step.Number != 1 {
		t.Errorf("Results[0].Step.Number = %d, want 1", result.Results[0].Step.Number)
	}
	if result.Results[1].Step.Number != 2 {
		t.Errorf("Results[1].Step.Number = %d, want 2", result.Results[1].Step.Number)
	}
	if result.PlanID != plan.ID {
		t.Errorf("DispatchResult.PlanID = %q, want %q", result.PlanID, plan.ID)
	}
}
