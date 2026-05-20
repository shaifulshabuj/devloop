package orchestrator

import (
	"strings"

	"github.com/shaifulshabuj/devloop/v6/internal/agent"
	"github.com/shaifulshabuj/devloop/v6/internal/config"
)

// TaskType classifies the nature of a task step.
type TaskType string

const (
	TaskTypeCode    TaskType = "code"    // writing or modifying code
	TaskTypeReview  TaskType = "review"  // reviewing or analysing
	TaskTypeTest    TaskType = "test"    // writing or running tests
	TaskTypeDoc     TaskType = "doc"     // documentation
	TaskTypeGeneral TaskType = "general" // everything else
)

// RouteResult holds the selected backend and model for a step.
type RouteResult struct {
	Backend  string
	Model    string
	TaskType TaskType
}

// Router selects backend and model for task steps.
type Router struct {
	cfg    *config.Config // for model overrides from config
	runner *agent.Runner  // to check which backends are available
}

// NewRouter creates a new Router with the given config and runner.
func NewRouter(cfg *config.Config, runner *agent.Runner) *Router {
	return &Router{cfg: cfg, runner: runner}
}

// Classify returns the TaskType for a step description.
// Uses keyword matching (no LLM):
//   - "test", "spec", "coverage" → TaskTypeTest
//   - "review", "analyse", "check", "audit" → TaskTypeReview
//   - "document", "readme", "comment" → TaskTypeDoc
//   - "implement", "add", "create", "fix", "update", "refactor", "write" → TaskTypeCode
//   - everything else → TaskTypeGeneral
func (r *Router) Classify(description string) TaskType {
	lower := strings.ToLower(description)

	testKeywords := []string{"test", "spec", "coverage"}
	for _, kw := range testKeywords {
		if strings.Contains(lower, kw) {
			return TaskTypeTest
		}
	}

	reviewKeywords := []string{"review", "analyse", "check", "audit"}
	for _, kw := range reviewKeywords {
		if strings.Contains(lower, kw) {
			return TaskTypeReview
		}
	}

	docKeywords := []string{"document", "readme", "comment"}
	for _, kw := range docKeywords {
		if strings.Contains(lower, kw) {
			return TaskTypeDoc
		}
	}

	codeKeywords := []string{"implement", "add", "create", "fix", "update", "refactor", "write"}
	for _, kw := range codeKeywords {
		if strings.Contains(lower, kw) {
			return TaskTypeCode
		}
	}

	return TaskTypeGeneral
}

// Route returns the backend and model for a step description.
// Selection logic:
//   - Default backend: cfg.Agents.DefaultBackend (fallback "claude")
//   - Model selection based on TaskType:
//     TaskTypeCode → cfg.Models.Worker (fallback "claude-sonnet-4-5")
//     TaskTypeReview → cfg.Models.Reviewer (fallback "claude-sonnet-4-5")
//     TaskTypeGeneral → cfg.Models.Worker (fallback "claude-sonnet-4-5")
//     others → cfg.Models.Worker
//   - If the default backend is not available (runner.AvailableBackends()),
//     fall back to the first available backend; if none, use "claude"
func (r *Router) Route(description string) RouteResult {
	taskType := r.Classify(description)

	// Determine backend
	defaultBackend := r.cfg.Agents.DefaultBackend
	if defaultBackend == "" {
		defaultBackend = "claude"
	}

	backend := defaultBackend
	available := r.runner.AvailableBackends()
	if !isBackendAvailable(available, defaultBackend) {
		if len(available) > 0 {
			backend = available[0].ID
		} else {
			backend = "claude"
		}
	}

	// Determine model
	const fallbackModel = "claude-sonnet-4-5"
	var model string
	switch taskType {
	case TaskTypeReview:
		model = r.cfg.Models.Reviewer
	default:
		model = r.cfg.Models.Worker
	}
	if model == "" {
		model = fallbackModel
	}

	return RouteResult{
		Backend:  backend,
		Model:    model,
		TaskType: taskType,
	}
}

// isBackendAvailable checks whether a backend with the given id is in the list.
func isBackendAvailable(backends []*agent.Backend, id string) bool {
	for _, b := range backends {
		if b.ID == id {
			return true
		}
	}
	return false
}
