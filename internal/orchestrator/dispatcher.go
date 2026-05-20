package orchestrator

import (
	"context"
	"strings"

	"github.com/shaifulshabuj/devloop/v6/internal/agent"
	"github.com/shaifulshabuj/devloop/v6/internal/storage"
)

// StepResult holds the output of one executed step.
type StepResult struct {
	Step   Step
	Output string
	Error  error
}

// DispatchResult holds the accumulated results of all steps.
type DispatchResult struct {
	PlanID  string
	Results []StepResult
}

// Dispatcher executes plan steps sequentially via the agent runner.
type Dispatcher struct {
	store  *storage.Store
	runner *agent.Runner
}

// NewDispatcher returns a Dispatcher backed by the given store and runner.
func NewDispatcher(store *storage.Store, runner *agent.Runner) *Dispatcher {
	return &Dispatcher{store: store, runner: runner}
}

// Dispatch executes each step in plan.Steps sequentially.
//
// For each step:
//  1. Build input: step.Description + "\n\nContext:\n" + accumulated prior outputs
//  2. Call runner.Spawn(ctx, step.Backend, SpawnOpts{InputText: input})
//  3. Collect all Session.Lines as the step output
//  4. Update store task status to "running" for first step, "done" or "failed" at end
//  5. On ctx cancellation, stop and return partial DispatchResult + ctx error
//
// Returns DispatchResult with all results (partial on error), plus the first
// non-nil error encountered (or nil on full success).
func (d *Dispatcher) Dispatch(ctx context.Context, plan *Plan) (*DispatchResult, error) {
	result := &DispatchResult{PlanID: plan.ID}

	var firstErr error
	var accumulated []string // prior step outputs

	for i, step := range plan.Steps {
		// Update task status to "running" before the first step executes.
		if i == 0 {
			_ = d.store.UpdateTaskStatus(plan.ID, "running")
		}

		// Build input: step description, optionally prefixed with prior context.
		input := step.Description
		if len(accumulated) > 0 {
			input += "\n\nContext:\n" + strings.Join(accumulated, "\n")
		}

		// Spawn the backend for this step.
		sess, err := d.runner.Spawn(ctx, step.Backend, agent.SpawnOpts{InputText: input})

		// Collect output lines from the session.
		var output string
		if sess != nil && len(sess.Lines) > 0 {
			output = strings.Join(sess.Lines, "\n")
		}

		result.Results = append(result.Results, StepResult{
			Step:   step,
			Output: output,
			Error:  err,
		})

		if err != nil {
			if firstErr == nil {
				firstErr = err
			}
			// On context cancellation stop immediately and return partial results.
			if ctx.Err() != nil {
				return result, firstErr
			}
		}

		// Accumulate this step's output so the next step receives it as context.
		if output != "" {
			accumulated = append(accumulated, output)
		}
	}

	// Record the final task status in the store.
	finalStatus := "done"
	if firstErr != nil {
		finalStatus = "failed"
	}
	_ = d.store.UpdateTaskStatus(plan.ID, finalStatus)

	return result, firstErr
}
