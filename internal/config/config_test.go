package config

import (
	"bytes"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeTemp writes content to a temporary file and returns its path.
func writeTemp(t *testing.T, dir, name, content string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
		t.Fatalf("writeTemp: %v", err)
	}
	return p
}

func TestLoad_MissingBothFiles_ReturnsDefaults(t *testing.T) {
	cfg, err := Load("/nonexistent/global.toml", "/nonexistent/project.toml")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg == nil {
		t.Fatal("cfg must not be nil")
	}
	// Spot-check a few default values.
	if cfg.Agents.DefaultBackend != "claude" {
		t.Errorf("expected default_backend=claude, got %q", cfg.Agents.DefaultBackend)
	}
	if cfg.Storage.KeepDays != 30 {
		t.Errorf("expected keep_days=30, got %d", cfg.Storage.KeepDays)
	}
	if cfg.Models.Orchestrator != "claude-opus-4-5" {
		t.Errorf("expected orchestrator=claude-opus-4-5, got %q", cfg.Models.Orchestrator)
	}
}

func TestLoad_GlobalOnly(t *testing.T) {
	dir := t.TempDir()
	global := writeTemp(t, dir, "global.toml", `
[project]
name = "global-project"

[models]
orchestrator = "claude-opus-4"
`)

	cfg, err := Load(global, "/nonexistent/project.toml")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Project.Name != "global-project" {
		t.Errorf("expected name=global-project, got %q", cfg.Project.Name)
	}
	if cfg.Models.Orchestrator != "claude-opus-4" {
		t.Errorf("expected orchestrator=claude-opus-4, got %q", cfg.Models.Orchestrator)
	}
	// Keep default for fields not in global.
	if cfg.Storage.KeepDays != 30 {
		t.Errorf("expected keep_days=30 (default), got %d", cfg.Storage.KeepDays)
	}
}

func TestLoad_ProjectOnly(t *testing.T) {
	dir := t.TempDir()
	project := writeTemp(t, dir, "project.toml", `
[project]
name = "my-project"
stack = "Go"

[storage]
keep_days = 7
`)

	cfg, err := Load("/nonexistent/global.toml", project)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Project.Name != "my-project" {
		t.Errorf("expected name=my-project, got %q", cfg.Project.Name)
	}
	if cfg.Project.Stack != "Go" {
		t.Errorf("expected stack=Go, got %q", cfg.Project.Stack)
	}
	if cfg.Storage.KeepDays != 7 {
		t.Errorf("expected keep_days=7, got %d", cfg.Storage.KeepDays)
	}
}

func TestLoad_BothFiles_ProjectWins(t *testing.T) {
	dir := t.TempDir()

	global := writeTemp(t, dir, "global.toml", `
[project]
name = "global-name"

[models]
orchestrator = "global-orchestrator"
worker = "global-worker"

[storage]
keep_days = 90
`)

	project := writeTemp(t, dir, "project.toml", `
[project]
name = "project-name"

[models]
orchestrator = "project-orchestrator"
`)

	cfg, err := Load(global, project)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Project wins for fields it sets.
	if cfg.Project.Name != "project-name" {
		t.Errorf("expected name=project-name, got %q", cfg.Project.Name)
	}
	if cfg.Models.Orchestrator != "project-orchestrator" {
		t.Errorf("expected orchestrator=project-orchestrator, got %q", cfg.Models.Orchestrator)
	}

	// Global wins for fields project does not set.
	if cfg.Models.Worker != "global-worker" {
		t.Errorf("expected worker=global-worker, got %q", cfg.Models.Worker)
	}
	if cfg.Storage.KeepDays != 90 {
		t.Errorf("expected keep_days=90 (from global), got %d", cfg.Storage.KeepDays)
	}
}

func TestLoad_UnknownKey_LoggedNoError(t *testing.T) {
	dir := t.TempDir()

	// Capture log output.
	var buf bytes.Buffer
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	project := writeTemp(t, dir, "project.toml", `
[project]
name = "test"
unknown_field = "surprise"
`)

	cfg, err := Load("/nonexistent/global.toml", project)
	if err != nil {
		t.Fatalf("expected no error for unknown key, got: %v", err)
	}
	if cfg == nil {
		t.Fatal("cfg must not be nil")
	}

	logged := buf.String()
	if !strings.Contains(logged, "unknown_field") {
		t.Errorf("expected unknown key warning in log, got: %q", logged)
	}
	if !strings.Contains(logged, "ignored") {
		t.Errorf("expected 'ignored' in log warning, got: %q", logged)
	}
}

func TestConfig_Show(t *testing.T) {
	cfg := defaults()
	cfg.Project.Name = "test-show"

	out, err := cfg.Show()
	if err != nil {
		t.Fatalf("Show() error: %v", err)
	}
	if !strings.Contains(out, "test-show") {
		t.Errorf("Show() output missing project name, got:\n%s", out)
	}
	if !strings.Contains(out, "[project]") {
		t.Errorf("Show() output missing [project] section, got:\n%s", out)
	}
}
