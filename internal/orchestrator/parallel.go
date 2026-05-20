package orchestrator

import (
	"context"
	"strings"
	"sync"

	"github.com/shaifulshabuj/devloop/v6/internal/agent"
	"github.com/shaifulshabuj/devloop/v6/internal/storage"
)

const defaultMaxWorkers = 4

// ParallelDispatcher executes independent plan steps concurrently.
type ParallelDispatcher struct {
	store      *storage.Store
	runner     *agent.Runner
	maxWorkers int // max concurrent goroutines
}

// NewParallelDispatcher returns a ParallelDispatcher backed by the given store
// and runner. If maxWorkers is <= 0, the default of 4 is used.
func NewParallelDispatcher(store *storage.Store, runner *agent.Runner, maxWorkers int) *ParallelDispatcher {
	if maxWorkers <= 0 {
		maxWorkers = defaultMaxWorkers
	}
	return &ParallelDispatcher{
		store:      store,
		runner:     runner,
		maxWorkers: maxWorkers,
	}
}

// ParallelOpts configures optional behaviour for DispatchOpts.
type ParallelOpts struct {
	// StepOutput, when provided, receives live stdout lines from each running step.
	// Each element corresponds to plan.Steps[i].  Channels are closed by
	// DispatchOpts when the corresponding step finishes so that consumers can
	// range over them.  Length must be >= len(plan.Steps).
	StepOutput []chan<- string
}

// DispatchOpts is like Dispatch but accepts optional opts for live output streaming.
func (p *ParallelDispatcher) DispatchOpts(ctx context.Context, plan *Plan, opts ParallelOpts) (*DispatchResult, error) {
	n := len(plan.Steps)
	results := make([]StepResult, n)

	// Semaphore: a buffered channel caps the number of concurrent goroutines.
	sem := make(chan struct{}, p.maxWorkers)

	var wg sync.WaitGroup
	wg.Add(n)

	for i, step := range plan.Steps {
		i, step := i, step // capture loop vars
		go func() {
			defer wg.Done()

			// Resolve and defer-close the per-step output channel immediately so
			// forwarder goroutines always drain, even on early cancellation exits.
			var out chan<- string
			if i < len(opts.StepOutput) {
				out = opts.StepOutput[i]
			}
			if out != nil {
				defer close(out)
			}

			// Acquire semaphore slot before running.
			select {
			case sem <- struct{}{}:
				defer func() { <-sem }()
			case <-ctx.Done():
				// Context cancelled before we could acquire the slot.
				results[i] = StepResult{Step: step, Error: ctx.Err()}
				return
			}

			sess, usedBackend, err := p.runner.SpawnWithFailover(ctx, step.Backend, agent.SpawnOpts{
				InputText: step.Description,
				OutputCh:  out,
			})
			if usedBackend != step.Backend {
				step.Backend = usedBackend
			}

			var output string
			if sess != nil && len(sess.Lines) > 0 {
				output = strings.Join(sess.Lines, "\n")
			}

			results[i] = StepResult{Step: step, Output: output, Error: err}
		}()
	}

	wg.Wait()

	dr := &DispatchResult{PlanID: plan.ID, Results: results}

	// Find the first non-nil error in step order.
	var firstErr error
	for _, r := range results {
		if r.Error != nil {
			firstErr = r.Error
			break
		}
	}

	return dr, firstErr
}

// Dispatch executes all steps in plan.Steps concurrently (up to maxWorkers at a
// time). Each step receives only its own Description as input — since steps run
// in parallel, there is no prior-context accumulation.
//
// Results are collected and returned in step order (not completion order). If ctx
// is cancelled, in-flight goroutines are stopped via the shared context. Returns
// DispatchResult with all results (partial on cancellation), plus the first
// non-nil error in step order.
func (p *ParallelDispatcher) Dispatch(ctx context.Context, plan *Plan) (*DispatchResult, error) {
	return p.DispatchOpts(ctx, plan, ParallelOpts{})
}
