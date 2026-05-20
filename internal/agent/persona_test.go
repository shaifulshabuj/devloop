package agent

import (
	"testing"
)

func TestRegistry_BuiltIns(t *testing.T) {
	r := NewPersonaRegistry()

	for _, name := range []string{"orchestrator", "worker", "reviewer"} {
		p, ok := r.Get(name)
		if !ok {
			t.Errorf("expected built-in persona %q to be present", name)
			continue
		}
		if p.Name != name {
			t.Errorf("persona.Name = %q, want %q", p.Name, name)
		}
		if p.SystemPrompt == "" {
			t.Errorf("persona %q has empty SystemPrompt", name)
		}
		if p.PreferredModel == "" {
			t.Errorf("persona %q has empty PreferredModel", name)
		}
		if p.DefaultBackend == "" {
			t.Errorf("persona %q has empty DefaultBackend", name)
		}
	}
}

func TestRegistry_Register_Duplicate(t *testing.T) {
	r := NewPersonaRegistry()

	duplicate := Persona{
		Name:           "orchestrator",
		Description:    "duplicate",
		SystemPrompt:   "some prompt",
		PreferredModel: "some-model",
		DefaultBackend: "claude",
	}
	err := r.Register(duplicate)
	if err == nil {
		t.Error("expected error when registering duplicate persona name, got nil")
	}
}

func TestRegistry_Register_New(t *testing.T) {
	r := NewPersonaRegistry()

	custom := Persona{
		Name:           "custom",
		Description:    "A custom persona",
		SystemPrompt:   "You are a custom agent.",
		PreferredModel: "claude-haiku-4-5",
		DefaultBackend: "claude",
	}
	if err := r.Register(custom); err != nil {
		t.Fatalf("unexpected error registering new persona: %v", err)
	}
	got, ok := r.Get("custom")
	if !ok {
		t.Fatal("expected custom persona to be retrievable after registration")
	}
	if got.Description != custom.Description {
		t.Errorf("Description = %q, want %q", got.Description, custom.Description)
	}
}

func TestRegistry_List_Sorted(t *testing.T) {
	r := NewPersonaRegistry()

	personas := r.List()
	if len(personas) < 3 {
		t.Fatalf("expected at least 3 personas, got %d", len(personas))
	}

	for i := 1; i < len(personas); i++ {
		if personas[i].Name < personas[i-1].Name {
			t.Errorf("List() not sorted: %q appears before %q",
				personas[i-1].Name, personas[i].Name)
		}
	}

	// Verify the exact built-in order: orchestrator, reviewer, worker.
	wantOrder := []string{"orchestrator", "reviewer", "worker"}
	if len(personas) == 3 {
		for i, want := range wantOrder {
			if personas[i].Name != want {
				t.Errorf("List()[%d].Name = %q, want %q", i, personas[i].Name, want)
			}
		}
	}
}
