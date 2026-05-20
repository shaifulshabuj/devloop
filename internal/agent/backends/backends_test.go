package backends_test

import (
	"testing"

	"github.com/shaifulshabuj/devloop/v6/internal/agent/backends"
)

func TestAll(t *testing.T) {
	all := backends.All()
	if len(all) != 4 {
		t.Fatalf("expected 4 adapters, got %d", len(all))
	}

	seen := make(map[string]bool)
	for _, a := range all {
		id := a.ID()
		if seen[id] {
			t.Errorf("duplicate adapter ID: %q", id)
		}
		seen[id] = true
	}
}

func TestDetected(t *testing.T) {
	// Detected() must return a subset of All() and must not panic.
	all := backends.All()
	detected := backends.Detected()

	if len(detected) > len(all) {
		t.Errorf("Detected() returned more adapters (%d) than All() (%d)", len(detected), len(all))
	}

	allIDs := make(map[string]bool)
	for _, a := range all {
		allIDs[a.ID()] = true
	}
	for _, a := range detected {
		if !allIDs[a.ID()] {
			t.Errorf("Detected() returned unknown adapter ID: %q", a.ID())
		}
	}
}

func TestOpenCodeAdapter(t *testing.T) {
	a := &backends.OpenCode{}

	if a.ID() != "opencode" {
		t.Errorf("ID: got %q, want %q", a.ID(), "opencode")
	}
	if a.Binary() != "opencode" {
		t.Errorf("Binary: got %q, want %q", a.Binary(), "opencode")
	}
	if len(a.DefaultArgs()) != 0 {
		t.Errorf("DefaultArgs: expected empty slice, got %v", a.DefaultArgs())
	}
	if a.Description() == "" {
		t.Error("Description must not be empty")
	}
	// Detect must not panic
	_ = a.Detect()
}

func TestPiAdapter(t *testing.T) {
	a := &backends.Pi{}

	if a.ID() != "pi" {
		t.Errorf("ID: got %q, want %q", a.ID(), "pi")
	}
	if a.Binary() != "pi" {
		t.Errorf("Binary: got %q, want %q", a.Binary(), "pi")
	}
	if len(a.DefaultArgs()) != 0 {
		t.Errorf("DefaultArgs: expected empty slice, got %v", a.DefaultArgs())
	}
	if a.Description() == "" {
		t.Error("Description must not be empty")
	}
	// Detect must not panic
	_ = a.Detect()
}

func TestClaudeAdapter(t *testing.T) {
	a := &backends.Claude{}

	if a.ID() != "claude" {
		t.Errorf("ID: got %q, want %q", a.ID(), "claude")
	}
	if a.Binary() != "claude" {
		t.Errorf("Binary: got %q, want %q", a.Binary(), "claude")
	}

	args := a.DefaultArgs()
	found := false
	for i, arg := range args {
		if arg == "--permission-mode" && i+1 < len(args) && args[i+1] == "acceptEdits" {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("DefaultArgs: expected --permission-mode acceptEdits, got %v", args)
	}

	if a.Description() == "" {
		t.Error("Description must not be empty")
	}
	_ = a.Detect()
}

func TestCopilotAdapter(t *testing.T) {
	a := &backends.Copilot{}

	if a.ID() != "copilot" {
		t.Errorf("ID: got %q, want %q", a.ID(), "copilot")
	}
	if a.Binary() != "copilot" {
		t.Errorf("Binary: got %q, want %q", a.Binary(), "copilot")
	}

	args := a.DefaultArgs()
	found := false
	for _, arg := range args {
		if arg == "--allow-all" {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("DefaultArgs: expected --allow-all, got %v", args)
	}

	if a.Description() == "" {
		t.Error("Description must not be empty")
	}
	_ = a.Detect()
}
