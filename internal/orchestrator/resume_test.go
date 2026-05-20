package orchestrator_test

import (
	"context"
	"testing"

	"github.com/shaifulshabuj/devloop/v6/internal/agent"
	"github.com/shaifulshabuj/devloop/v6/internal/orchestrator"
)

func TestResumable_Empty(t *testing.T) {
	store := newTestStore(t)
	runner := agent.NewRunner()
	d := orchestrator.NewDispatcher(store, runner)
	r := orchestrator.NewResumer(store, d)

	tasks, err := r.Resumable()
	if err != nil {
		t.Fatalf("Resumable() error: %v", err)
	}
	if len(tasks) != 0 {
		t.Errorf("Resumable() = %d tasks, want 0", len(tasks))
	}
}

func TestResumable_WithTasks(t *testing.T) {
	store := newTestStore(t)
	runner := agent.NewRunner()
	d := orchestrator.NewDispatcher(store, runner)
	r := orchestrator.NewResumer(store, d)

	type fixture struct {
		id     string
		title  string
		status string
	}
	fixtures := []fixture{
		{"task-pending", "Pending Task", "pending"},
		{"task-running", "Running Task", "running"},
		{"task-failed", "Failed Task", "failed"},
		{"task-done", "Done Task", "done"},
	}

	for _, f := range fixtures {
		if err := store.CreateTask(f.id, f.title); err != nil {
			t.Fatalf("CreateTask(%q): %v", f.id, err)
		}
		if f.status != "pending" {
			if err := store.UpdateTaskStatus(f.id, f.status); err != nil {
				t.Fatalf("UpdateTaskStatus(%q, %q): %v", f.id, f.status, err)
			}
		}
	}

	resumable, err := r.Resumable()
	if err != nil {
		t.Fatalf("Resumable() error: %v", err)
	}
	if len(resumable) != 2 {
		t.Fatalf("Resumable() = %d tasks, want 2 (running + failed)", len(resumable))
	}

	ids := make(map[string]bool, len(resumable))
	for _, task := range resumable {
		ids[task.ID] = true
	}
	if !ids["task-running"] {
		t.Error("Resumable() missing task-running")
	}
	if !ids["task-failed"] {
		t.Error("Resumable() missing task-failed")
	}
}

func TestResume_NotFound(t *testing.T) {
	store := newTestStore(t)
	runner := agent.NewRunner()
	d := orchestrator.NewDispatcher(store, runner)
	r := orchestrator.NewResumer(store, d)

	_, err := r.Resume(context.Background(), "nonexistent-task-id")
	if err == nil {
		t.Error("Resume(nonexistent): expected error, got nil")
	}
}

func TestResume_BadStatus(t *testing.T) {
	store := newTestStore(t)
	runner := agent.NewRunner()
	d := orchestrator.NewDispatcher(store, runner)
	r := orchestrator.NewResumer(store, d)

	if err := store.CreateTask("task-done", "Done Task"); err != nil {
		t.Fatalf("CreateTask: %v", err)
	}
	if err := store.UpdateTaskStatus("task-done", "done"); err != nil {
		t.Fatalf("UpdateTaskStatus: %v", err)
	}

	_, err := r.Resume(context.Background(), "task-done")
	if err == nil {
		t.Error("Resume(done task): expected error, got nil")
	}
}
