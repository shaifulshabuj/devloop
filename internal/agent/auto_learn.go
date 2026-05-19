package agent

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/shaifulshabuj/devloop/internal/storage"
)

// AutoLearnConfig configures the auto-learning watcher.
type AutoLearnConfig struct {
	LessonsPath  string        // path to lessons.md
	PollInterval time.Duration // how often to check for completed tasks (default 30s)
}

// learnStore is the subset of storage.Store used by AutoLearner.
type learnStore interface {
	ListTasks(limit int) ([]*storage.Task, error)
	GetContext(taskID string) ([]*storage.ContextEntry, error)
}

// AutoLearner watches for completed tasks and extracts lessons automatically.
type AutoLearner struct {
	cfg   AutoLearnConfig
	loop  *LearningLoop
	store learnStore
	seen  map[string]bool
	mu    sync.Mutex
}

// NewAutoLearner creates an AutoLearner. If cfg.PollInterval is zero, it
// defaults to 30s.
func NewAutoLearner(cfg AutoLearnConfig, store learnStore) *AutoLearner {
	if cfg.PollInterval == 0 {
		cfg.PollInterval = 30 * time.Second
	}
	return &AutoLearner{
		cfg:   cfg,
		loop:  NewLearningLoop(cfg.LessonsPath),
		store: store,
		seen:  make(map[string]bool),
	}
}

// ProcessTask extracts and persists lessons for a single task.
// It is idempotent: calling it twice for the same task ID is a no-op (uses
// seen map). When contextEntries is empty, no lessons are written and nil is
// returned.
func (a *AutoLearner) ProcessTask(taskID, taskTitle string, contextEntries []*storage.ContextEntry) error {
	a.mu.Lock()
	if a.seen[taskID] {
		a.mu.Unlock()
		return nil
	}
	a.seen[taskID] = true
	a.mu.Unlock()

	if len(contextEntries) == 0 {
		return nil
	}

	inputs := make([]LessonInput, len(contextEntries))
	for i, e := range contextEntries {
		inputs[i] = LessonInput{Output: e.Content}
	}

	if err := a.loop.ExtractAndPersist(taskID, taskTitle, inputs); err != nil {
		return fmt.Errorf("auto_learn: extracting lessons for task %s: %w", taskID, err)
	}
	return nil
}

// Run starts the polling loop, calling ProcessTask for each newly-completed
// task. Runs until ctx is cancelled.
func (a *AutoLearner) Run(ctx context.Context) error {
	ticker := time.NewTicker(a.cfg.PollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
			a.poll(ctx)
		}
	}
}

// poll fetches all tasks, and for each "done" task that has not yet been
// processed, retrieves its context and calls ProcessTask.
func (a *AutoLearner) poll(ctx context.Context) {
	tasks, err := a.store.ListTasks(100)
	if err != nil {
		return
	}

	for _, t := range tasks {
		if t.Status != "done" {
			continue
		}
		if ctx.Err() != nil {
			return
		}

		entries, err := a.store.GetContext(t.ID)
		if err != nil {
			continue
		}

		_ = a.ProcessTask(t.ID, t.Title, entries)
	}
}
