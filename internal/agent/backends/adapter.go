// Package backends provides backend adapters for agent CLIs.
package backends

// Adapter describes how to launch and interact with a specific agent backend.
type Adapter interface {
	// ID returns the backend's unique identifier (e.g., "opencode", "pi").
	ID() string
	// Binary returns the executable name to look up in PATH.
	Binary() string
	// DefaultArgs returns the CLI args to pass when spawning the backend.
	DefaultArgs() []string
	// Detect reports whether the backend binary is installed.
	Detect() bool
	// Description returns a human-readable description of the backend.
	Description() string
}
