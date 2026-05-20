// Package orchestrator implements the DevLoop task orchestration engine.
package orchestrator

import (
	"context"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/shaifulshabuj/devloop/v6/internal/agent"
	"github.com/shaifulshabuj/devloop/v6/internal/storage"
)

// complexityKeywords are the trigger words used to classify a task as complex.
var complexityKeywords = []string{
	"and", "then", "also", "with", "plus",
	"implement", "add", "create", "update", "fix", "integrate",
}

// splitKeywords are the words used to split a complex task into steps.
var splitKeywords = []string{"and", "then", "also"}

// Step describes a single unit of work within a Plan.
type Step struct {
	Number      int
	Description string
	Backend     string
	Model       string
	Status      string
}

// Plan is the orchestrated execution plan for a task.
type Plan struct {
	ID            string
	Title         string
	Steps         []Step
	EstimatedTime time.Duration
	CreatedAt     time.Time
}

// Orchestrator coordinates task planning and execution.
type Orchestrator struct {
	store  *storage.Store
	runner *agent.Runner
}

// New returns a new Orchestrator backed by the given store and runner.
func New(store *storage.Store, runner *agent.Runner) *Orchestrator {
	return &Orchestrator{store: store, runner: runner}
}

// Plan classifies the task, generates steps, persists the task, and returns
// the resulting Plan. No LLM call is made — classification and step
// generation are fully deterministic heuristics.
func (o *Orchestrator) Plan(_ context.Context, task string) (*Plan, error) {
	steps := generateSteps(task)

	plan := &Plan{
		ID:            uuid.New().String(),
		Title:         task,
		Steps:         steps,
		EstimatedTime: time.Duration(len(steps)) * 5 * time.Minute,
		CreatedAt:     time.Now(),
	}

	if err := o.store.CreateTask(plan.ID, plan.Title); err != nil {
		return nil, err
	}

	return plan, nil
}

// isComplex returns true when the task exceeds the word-count threshold or
// contains at least one complexity keyword.
func isComplex(task string) bool {
	words := strings.Fields(task)
	if len(words) > 5 {
		return true
	}
	lower := strings.ToLower(task)
	for _, kw := range complexityKeywords {
		// Match whole words only by surrounding with spaces or boundary checks.
		if containsWord(lower, kw) {
			return true
		}
	}
	return false
}

// containsWord reports whether s contains kw as a whole word (space-delimited).
func containsWord(s, kw string) bool {
	for _, w := range strings.Fields(s) {
		if w == kw {
			return true
		}
	}
	return false
}

// generateSteps produces the step list for a task using pure heuristics.
func generateSteps(task string) []Step {
	if !isComplex(task) {
		return []Step{
			{
				Number:      1,
				Description: task,
				Backend:     "claude",
				Model:       "claude-sonnet-4-5",
				Status:      "pending",
			},
		}
	}

	// Try splitting on split keywords.
	parts := splitOnKeywords(task)
	if len(parts) < 2 {
		// No natural splits: use the canonical three-step breakdown.
		return []Step{
			{Number: 1, Description: "Analyse: " + task, Backend: "claude", Model: "claude-sonnet-4-5", Status: "pending"},
			{Number: 2, Description: "Implement: " + task, Backend: "claude", Model: "claude-sonnet-4-5", Status: "pending"},
			{Number: 3, Description: "Verify: " + task, Backend: "claude", Model: "claude-sonnet-4-5", Status: "pending"},
		}
	}

	// Cap at 4 steps.
	if len(parts) > 4 {
		parts = parts[:4]
	}

	steps := make([]Step, len(parts))
	for i, p := range parts {
		steps[i] = Step{
			Number:      i + 1,
			Description: strings.TrimSpace(p),
			Backend:     "claude",
			Model:       "claude-sonnet-4-5",
			Status:      "pending",
		}
	}
	return steps
}

// splitOnKeywords splits the task string on any of the split keywords,
// returning the non-empty fragments.
func splitOnKeywords(task string) []string {
	// Build a simple splitter: scan word by word, emitting a new fragment
	// each time a split keyword is encountered.
	words := strings.Fields(task)
	var parts []string
	var current []string

	for _, w := range words {
		isSplit := false
		for _, kw := range splitKeywords {
			if strings.ToLower(w) == kw {
				isSplit = true
				break
			}
		}
		if isSplit {
			if len(current) > 0 {
				parts = append(parts, strings.Join(current, " "))
				current = current[:0]
			}
		} else {
			current = append(current, w)
		}
	}
	if len(current) > 0 {
		parts = append(parts, strings.Join(current, " "))
	}

	return parts
}
