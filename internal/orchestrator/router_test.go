package orchestrator

import (
	"testing"

	"github.com/shaifulshabuj/devloop/v6/internal/agent"
	"github.com/shaifulshabuj/devloop/v6/internal/config"
)

func TestClassify(t *testing.T) {
	r := NewRouter(&config.Config{}, agent.NewRunner())

	tests := []struct {
		description string
		want        TaskType
	}{
		// TaskTypeTest keywords
		{"write a test for the parser", TaskTypeTest},
		{"add spec for the handler", TaskTypeTest},
		{"increase coverage to 90%", TaskTypeTest},
		// TaskTypeReview keywords
		{"review the pull request", TaskTypeReview},
		{"analyse the architecture", TaskTypeReview},
		{"check for memory leaks", TaskTypeReview},
		{"audit the security config", TaskTypeReview},
		// TaskTypeDoc keywords
		{"document the API endpoints", TaskTypeDoc},
		{"update the readme", TaskTypeDoc},
		{"add comment to the function", TaskTypeDoc},
		// TaskTypeCode keywords
		{"implement the login feature", TaskTypeCode},
		{"add a new endpoint", TaskTypeCode},
		{"create the database schema", TaskTypeCode},
		{"fix the null pointer bug", TaskTypeCode},
		{"update the config loader", TaskTypeCode},
		{"refactor the auth module", TaskTypeCode},
		{"write the data parser", TaskTypeCode},
		// TaskTypeGeneral — no matching keywords
		{"deploy to production", TaskTypeGeneral},
		{"set up the environment", TaskTypeGeneral},
		{"", TaskTypeGeneral},
	}

	for _, tc := range tests {
		got := r.Classify(tc.description)
		if got != tc.want {
			t.Errorf("Classify(%q) = %q, want %q", tc.description, got, tc.want)
		}
	}
}

func TestRoute_DefaultBackend(t *testing.T) {
	cfg := &config.Config{
		Agents: config.Agents{
			DefaultBackend: "claude",
		},
		Models: config.Models{
			Worker:   "claude-sonnet-4-5",
			Reviewer: "claude-sonnet-4-5",
		},
	}
	// NewRunner with no Detect() call → all backends have Found=false
	runner := agent.NewRunner()

	r := NewRouter(cfg, runner)
	result := r.Route("deploy to production")

	// No available backends → fall back to "claude"
	if result.Backend != "claude" {
		t.Errorf("Route backend = %q, want %q", result.Backend, "claude")
	}
}

func TestRoute_ModelSelection(t *testing.T) {
	cfg := &config.Config{
		Agents: config.Agents{
			DefaultBackend: "claude",
		},
		Models: config.Models{
			Worker:   "claude-sonnet-4-5",
			Reviewer: "claude-opus-4-5",
		},
	}
	runner := agent.NewRunner()
	r := NewRouter(cfg, runner)

	// TaskTypeCode → Worker model
	codeResult := r.Route("implement the login handler")
	if codeResult.TaskType != TaskTypeCode {
		t.Errorf("expected TaskTypeCode, got %q", codeResult.TaskType)
	}
	if codeResult.Model != cfg.Models.Worker {
		t.Errorf("code task model = %q, want %q", codeResult.Model, cfg.Models.Worker)
	}

	// TaskTypeReview → Reviewer model
	reviewResult := r.Route("review the auth module")
	if reviewResult.TaskType != TaskTypeReview {
		t.Errorf("expected TaskTypeReview, got %q", reviewResult.TaskType)
	}
	if reviewResult.Model != cfg.Models.Reviewer {
		t.Errorf("review task model = %q, want %q", reviewResult.Model, cfg.Models.Reviewer)
	}

	// TaskTypeGeneral → Worker model
	generalResult := r.Route("deploy to production")
	if generalResult.TaskType != TaskTypeGeneral {
		t.Errorf("expected TaskTypeGeneral, got %q", generalResult.TaskType)
	}
	if generalResult.Model != cfg.Models.Worker {
		t.Errorf("general task model = %q, want %q", generalResult.Model, cfg.Models.Worker)
	}
}
