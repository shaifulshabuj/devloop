package orchestrator

import (
	"context"
	"log"

	"github.com/shaifulshabuj/devloop/internal/agent"
	"github.com/shaifulshabuj/devloop/internal/git"
)

// AutonomousRunner runs the full devloop pipeline without human review.
type AutonomousRunner struct {
	orchestrator *Orchestrator
	dispatcher   *Dispatcher
	gitClient    *git.Client
	learningLoop *agent.LearningLoop
	repoDir      string
}

// NewAutonomousRunner constructs an AutonomousRunner.
// gitClient may be nil; when nil the AutoCommit step is skipped.
func NewAutonomousRunner(
	orch *Orchestrator,
	disp *Dispatcher,
	gitClient *git.Client,
	loop *agent.LearningLoop,
	repoDir string,
) *AutonomousRunner {
	return &AutonomousRunner{
		orchestrator: orch,
		dispatcher:   disp,
		gitClient:    gitClient,
		learningLoop: loop,
		repoDir:      repoDir,
	}
}

// Run executes the full pipeline for a task:
//  1. orch.Plan(ctx, task) → plan
//  2. disp.Dispatch(ctx, plan) → result
//  3. For each step result, build LessonInput from output+error
//  4. loop.ExtractAndPersist(plan.ID, plan.Title, inputs)
//  5. gitClient.AutoCommit(plan.Title) — only if gitClient is non-nil
//
// Returns the DispatchResult and any error from planning or dispatching.
// Git errors are logged but not returned; learning errors are similarly non-fatal.
func (a *AutonomousRunner) Run(ctx context.Context, task string) (*DispatchResult, error) {
	// Step 1: Plan.
	plan, err := a.orchestrator.Plan(ctx, task)
	if err != nil {
		return nil, err
	}

	// Step 2: Dispatch.
	result, dispErr := a.dispatcher.Dispatch(ctx, plan)

	// Step 3: Build lesson inputs from step results.
	inputs := make([]agent.LessonInput, len(result.Results))
	for i, sr := range result.Results {
		inputs[i] = agent.LessonInput{
			Output: sr.Output,
			Err:    sr.Error,
		}
	}

	// Step 4: Extract and persist lessons (non-fatal).
	if err := a.learningLoop.ExtractAndPersist(plan.ID, plan.Title, inputs); err != nil {
		log.Printf("autonomous: learning loop error for plan %s: %v", plan.ID, err)
	}

	// Step 5: Auto-commit if a git client is available (non-fatal).
	if a.gitClient != nil {
		if err := a.gitClient.AutoCommit(plan.Title); err != nil {
			log.Printf("autonomous: git auto-commit error for plan %s: %v", plan.ID, err)
		}
	}

	return result, dispErr
}
