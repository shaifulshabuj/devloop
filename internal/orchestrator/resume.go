package orchestrator

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/shaifulshabuj/devloop/internal/storage"
)

// resumableStatuses are the task statuses eligible for resume.
var resumableStatuses = map[string]bool{
	"running": true,
	"failed":  true,
}

// Resumer re-dispatches interrupted tasks.
type Resumer struct {
	store      *storage.Store
	dispatcher *Dispatcher
}

// NewResumer returns a Resumer backed by the given store and dispatcher.
func NewResumer(store *storage.Store, dispatcher *Dispatcher) *Resumer {
	return &Resumer{store: store, dispatcher: dispatcher}
}

// Resumable returns all tasks with status "running" or "failed".
func (r *Resumer) Resumable() ([]*storage.Task, error) {
	all, err := r.store.ListTasks(1000)
	if err != nil {
		return nil, fmt.Errorf("listing tasks: %w", err)
	}

	var out []*storage.Task
	for _, t := range all {
		if resumableStatuses[t.Status] {
			out = append(out, t)
		}
	}
	return out, nil
}

// Resume looks up the task by ID, verifies it is in a resumable state
// ("running" or "failed"), rebuilds a single-step Plan from the task's
// stored title, and calls Dispatcher.Dispatch with that plan.
//
// Returns an error if the task is not found or not in a resumable state.
func (r *Resumer) Resume(ctx context.Context, taskID string) (*DispatchResult, error) {
	task, err := r.store.GetTask(taskID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, fmt.Errorf("task %q not found", taskID)
		}
		return nil, fmt.Errorf("getting task %q: %w", taskID, err)
	}

	if !resumableStatuses[task.Status] {
		return nil, fmt.Errorf(
			"task %q has status %q: only \"running\" or \"failed\" tasks can be resumed",
			taskID, task.Status,
		)
	}

	plan := &Plan{
		ID:    task.ID,
		Title: task.Title,
		Steps: []Step{
			{
				Number:      1,
				Description: task.Title,
				Backend:     "claude",
				Model:       "claude-sonnet-4-5",
				Status:      "pending",
			},
		},
	}

	return r.dispatcher.Dispatch(ctx, plan)
}
