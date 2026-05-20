package orchestrator_test

import (
	"context"
	"testing"

	"github.com/shaifulshabuj/devloop/v6/internal/agent"
	"github.com/shaifulshabuj/devloop/v6/internal/orchestrator"
)

// TestParallelDispatch_ZeroWorkers verifies that maxWorkers=0 falls back to the
// default (4) and that a 2-step plan with a nonexistent backend returns 2 errors.
func TestParallelDispatch_ZeroWorkers(t *testing.T) {
	store := newTestStore(t)
	runner := agent.NewRunner()
	// maxWorkers = 0 → should default to 4 internally.
	pd := orchestrator.NewParallelDispatcher(store, runner, 0)

	plan := &orchestrator.Plan{
		ID:    "parallel-zero-workers",
		Title: "Zero Workers Plan",
		Steps: []orchestrator.Step{
			{Number: 1, Description: "Step one", Backend: "nonexistent-backend-xyz", Status: "pending"},
			{Number: 2, Description: "Step two", Backend: "nonexistent-backend-xyz", Status: "pending"},
		},
	}

	result, err := pd.Dispatch(context.Background(), plan)

	if err == nil {
		t.Error("Dispatch: expected non-nil error for nonexistent backend")
	}
	if result == nil {
		t.Fatal("Dispatch: returned nil DispatchResult")
	}
	if result.PlanID != plan.ID {
		t.Errorf("DispatchResult.PlanID = %q, want %q", result.PlanID, plan.ID)
	}
	if len(result.Results) != 2 {
		t.Fatalf("len(Results) = %d, want 2", len(result.Results))
	}
	for i, r := range result.Results {
		if r.Error == nil {
			t.Errorf("Results[%d].Error: want non-nil error", i)
		}
	}
}

// TestParallelDispatch_ContextCancel verifies that cancelling ctx before calling
// Dispatch causes the call to return promptly with a context-related error.
func TestParallelDispatch_ContextCancel(t *testing.T) {
	store := newTestStore(t)
	runner := agent.NewRunner()
	pd := orchestrator.NewParallelDispatcher(store, runner, 4)

	plan := &orchestrator.Plan{
		ID:    "parallel-ctx-cancel",
		Title: "Context Cancel Plan",
		Steps: []orchestrator.Step{
			{Number: 1, Description: "Step one", Backend: "nonexistent-backend-xyz", Status: "pending"},
		},
	}

	ctx, cancel := context.WithCancel(context.Background())
	// Cancel before dispatching so goroutines see a done context immediately.
	cancel()

	result, err := pd.Dispatch(ctx, plan)

	if err == nil {
		t.Error("Dispatch: expected non-nil error when ctx is pre-cancelled")
	}
	if result == nil {
		t.Fatal("Dispatch: returned nil DispatchResult")
	}
	// Results slice must have the same length as plan.Steps.
	if len(result.Results) != len(plan.Steps) {
		t.Errorf("len(Results) = %d, want %d", len(result.Results), len(plan.Steps))
	}
}

// TestParallelDispatch_ResultOrder verifies that a 3-step plan always returns
// results in step order (index 0, 1, 2) regardless of goroutine completion order.
func TestParallelDispatch_ResultOrder(t *testing.T) {
	store := newTestStore(t)
	runner := agent.NewRunner()
	pd := orchestrator.NewParallelDispatcher(store, runner, 4)

	plan := &orchestrator.Plan{
		ID:    "parallel-result-order",
		Title: "Result Order Plan",
		Steps: []orchestrator.Step{
			{Number: 1, Description: "Alpha", Backend: "nonexistent-backend-xyz", Status: "pending"},
			{Number: 2, Description: "Beta", Backend: "nonexistent-backend-xyz", Status: "pending"},
			{Number: 3, Description: "Gamma", Backend: "nonexistent-backend-xyz", Status: "pending"},
		},
	}

	result, _ := pd.Dispatch(context.Background(), plan)

	if result == nil {
		t.Fatal("Dispatch: returned nil DispatchResult")
	}
	if len(result.Results) != 3 {
		t.Fatalf("len(Results) = %d, want 3", len(result.Results))
	}
	// Each entry must correspond to its original step (by step number).
	for i, r := range result.Results {
		want := plan.Steps[i].Number
		if r.Step.Number != want {
			t.Errorf("Results[%d].Step.Number = %d, want %d", i, r.Step.Number, want)
		}
	}
}
