package orchestrator_test

import (
	"context"
	"testing"

	"github.com/shaifulshabuj/devloop/internal/agent"
	"github.com/shaifulshabuj/devloop/internal/orchestrator"
)

// TestAutonomousRunner_Run_SimpleTask verifies the full pipeline with an
// in-memory store and a nonexistent backend.
//
//   - Plan succeeds and is persisted to the store.
//   - Dispatch fails (backend not found) → DispatchResult has one StepResult
//     with a non-nil Error.
//   - Run returns the DispatchResult (non-nil) and the dispatch error.
func TestAutonomousRunner_Run_SimpleTask(t *testing.T) {
	store := newTestStore(t)
	runner := agent.NewRunner()

	orch := orchestrator.New(store, runner)
	disp := orchestrator.NewDispatcher(store, runner)
	loop := agent.NewLearningLoop(t.TempDir() + "/lessons.md")

	ar := orchestrator.NewAutonomousRunner(orch, disp, nil, loop, t.TempDir())

	const task = "run tests"
	result, err := ar.Run(context.Background(), task)

	// Dispatch will fail (no backend registered) — that is expected.
	if err == nil {
		t.Error("Run: expected a non-nil error from Dispatch (backend not found)")
	}
	if result == nil {
		t.Fatal("Run: returned nil DispatchResult, want non-nil")
	}
	if len(result.Results) == 0 {
		t.Fatal("Run: DispatchResult.Results is empty, want at least one StepResult")
	}
	// The step result must carry the dispatch error.
	if result.Results[0].Error == nil {
		t.Error("DispatchResult.Results[0].Error should be non-nil for nonexistent backend")
	}

	// Verify the plan was created and persisted in the store.
	if result.PlanID == "" {
		t.Fatal("DispatchResult.PlanID is empty")
	}
	storedTask, getErr := store.GetTask(result.PlanID)
	if getErr != nil {
		t.Fatalf("store.GetTask(%q): %v", result.PlanID, getErr)
	}
	if storedTask.Title != task {
		t.Errorf("stored task title = %q, want %q", storedTask.Title, task)
	}
}

// TestAutonomousRunner_Run_NilGit verifies that passing nil as the gitClient
// does not cause a panic or error — the AutoCommit step is simply skipped.
func TestAutonomousRunner_Run_NilGit(t *testing.T) {
	store := newTestStore(t)
	runner := agent.NewRunner()

	orch := orchestrator.New(store, runner)
	disp := orchestrator.NewDispatcher(store, runner)
	loop := agent.NewLearningLoop(t.TempDir() + "/lessons.md")

	// Explicitly pass nil for the git client.
	ar := orchestrator.NewAutonomousRunner(orch, disp, nil, loop, t.TempDir())

	// Should not panic even though gitClient is nil.
	result, _ := ar.Run(context.Background(), "deploy service")

	if result == nil {
		t.Fatal("Run: returned nil DispatchResult with nil gitClient")
	}
}
