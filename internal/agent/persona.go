package agent

import (
	"fmt"
	"sort"
)

// Persona defines an agent role with its own system prompt and model preference.
type Persona struct {
	Name           string // e.g. "orchestrator", "worker", "reviewer"
	Description    string
	SystemPrompt   string
	PreferredModel string // e.g. "claude-opus-4-5"
	DefaultBackend string // e.g. "claude"
}

// Built-in personas.
var (
	PersonaOrchestrator = Persona{
		Name:           "orchestrator",
		Description:    "Plans and coordinates multi-step tasks",
		SystemPrompt:   "You are the DevLoop orchestrator. Analyse the task and produce a numbered list of steps.",
		PreferredModel: "claude-opus-4-5",
		DefaultBackend: "claude",
	}
	PersonaWorker = Persona{
		Name:           "worker",
		Description:    "Implements individual task steps",
		SystemPrompt:   "You are a DevLoop worker agent. Implement the described step precisely and concisely.",
		PreferredModel: "claude-sonnet-4-5",
		DefaultBackend: "claude",
	}
	PersonaReviewer = Persona{
		Name:           "reviewer",
		Description:    "Reviews implementations for correctness and quality",
		SystemPrompt:   "You are a DevLoop reviewer. Check the implementation against the spec and report issues.",
		PreferredModel: "claude-sonnet-4-5",
		DefaultBackend: "claude",
	}
)

// PersonaRegistry holds named personas.
type PersonaRegistry struct {
	personas map[string]Persona
}

// NewPersonaRegistry creates a registry pre-loaded with the three built-in
// personas: orchestrator, worker, and reviewer.
func NewPersonaRegistry() *PersonaRegistry {
	r := &PersonaRegistry{personas: make(map[string]Persona)}
	for _, p := range []Persona{PersonaOrchestrator, PersonaWorker, PersonaReviewer} {
		r.personas[p.Name] = p
	}
	return r
}

// Register adds a persona to the registry. It returns an error if a persona
// with the same name is already registered.
func (r *PersonaRegistry) Register(p Persona) error {
	if _, exists := r.personas[p.Name]; exists {
		return fmt.Errorf("agent: persona %q is already registered", p.Name)
	}
	r.personas[p.Name] = p
	return nil
}

// Get returns the Persona with the given name and a boolean indicating whether
// it was found.
func (r *PersonaRegistry) Get(name string) (Persona, bool) {
	p, ok := r.personas[name]
	return p, ok
}

// List returns all registered personas sorted by name.
func (r *PersonaRegistry) List() []Persona {
	out := make([]Persona, 0, len(r.personas))
	for _, p := range r.personas {
		out = append(out, p)
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i].Name < out[j].Name
	})
	return out
}
