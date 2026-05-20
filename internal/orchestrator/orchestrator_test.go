package orchestrator_test

import (
	"context"
	"testing"

	"github.com/shaifulshabuj/devloop/v6/internal/agent"
	"github.com/shaifulshabuj/devloop/v6/internal/orchestrator"
	"github.com/shaifulshabuj/devloop/v6/internal/storage"
)

func newTestStore(t *testing.T) *storage.Store {
	t.Helper()
	store, err := storage.Open(":memory:")
	if err != nil {
		t.Fatalf("storage.Open: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	return store
}

func TestPlan_SimpleTask(t *testing.T) {
	store := newTestStore(t)
	runner := agent.NewRunner()
	o := orchestrator.New(store, runner)

	// "run tests" is 2 words with no complexity keywords → simple (1 step).
	const task = "run tests"
	plan, err := o.Plan(context.Background(), task)
	if err != nil {
		t.Fatalf("Plan() error: %v", err)
	}

	if plan.ID == "" {
		t.Error("plan.ID must not be empty")
	}
	if plan.Title != task {
		t.Errorf("plan.Title = %q, want %q", plan.Title, task)
	}
	if len(plan.Steps) != 1 {
		t.Fatalf("simple task: got %d steps, want 1", len(plan.Steps))
	}
	step := plan.Steps[0]
	if step.Number != 1 {
		t.Errorf("step.Number = %d, want 1", step.Number)
	}
	if step.Description != task {
		t.Errorf("step.Description = %q, want %q", step.Description, task)
	}
	if step.Backend != "claude" {
		t.Errorf("step.Backend = %q, want %q", step.Backend, "claude")
	}
	if step.Model != "claude-sonnet-4-5" {
		t.Errorf("step.Model = %q, want %q", step.Model, "claude-sonnet-4-5")
	}
	if step.Status != "pending" {
		t.Errorf("step.Status = %q, want %q", step.Status, "pending")
	}
	if plan.EstimatedTime != 5*60*1e9 { // 5 minutes in nanoseconds
		t.Errorf("EstimatedTime = %v, want 5m0s", plan.EstimatedTime)
	}
}

func TestPlan_ComplexTask(t *testing.T) {
	store := newTestStore(t)
	runner := agent.NewRunner()
	o := orchestrator.New(store, runner)

	plan, err := o.Plan(context.Background(), "implement login and setup dashboard")
	if err != nil {
		t.Fatalf("Plan() error: %v", err)
	}

	if plan.ID == "" {
		t.Error("plan.ID must not be empty")
	}
	if plan.Title != "implement login and setup dashboard" {
		t.Errorf("plan.Title = %q", plan.Title)
	}
	if len(plan.Steps) < 2 {
		t.Fatalf("complex task: got %d steps, want >= 2", len(plan.Steps))
	}
	if len(plan.Steps) > 4 {
		t.Fatalf("complex task: got %d steps, want <= 4 (cap)", len(plan.Steps))
	}
	// Estimated time should match step count × 5 min.
	wantDur := int64(len(plan.Steps)) * 5 * 60 * 1e9
	if int64(plan.EstimatedTime) != wantDur {
		t.Errorf("EstimatedTime = %v, want %v steps × 5m", plan.EstimatedTime, len(plan.Steps))
	}
	// Every step must have a non-empty description and be pending.
	for i, s := range plan.Steps {
		if s.Description == "" {
			t.Errorf("step[%d].Description is empty", i)
		}
		if s.Status != "pending" {
			t.Errorf("step[%d].Status = %q, want pending", i, s.Status)
		}
		if s.Number != i+1 {
			t.Errorf("step[%d].Number = %d, want %d", i, s.Number, i+1)
		}
	}
}

func TestPlan_PersistsTask(t *testing.T) {
	store := newTestStore(t)
	runner := agent.NewRunner()
	o := orchestrator.New(store, runner)

	plan, err := o.Plan(context.Background(), "add feature")
	if err != nil {
		t.Fatalf("Plan() error: %v", err)
	}

	task, err := store.GetTask(plan.ID)
	if err != nil {
		t.Fatalf("GetTask(%q): %v", plan.ID, err)
	}
	if task.Title != "add feature" {
		t.Errorf("persisted title = %q, want %q", task.Title, "add feature")
	}
	if task.Status != "pending" {
		t.Errorf("persisted status = %q, want pending", task.Status)
	}
}
