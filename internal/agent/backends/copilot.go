package backends

import "os/exec"

// Copilot is a backend adapter for the GitHub Copilot CLI agent.
type Copilot struct{}

func (c *Copilot) ID() string             { return "copilot" }
func (c *Copilot) Binary() string         { return "copilot" }
func (c *Copilot) DefaultArgs() []string  { return []string{"--allow-all"} }
func (c *Copilot) Detect() bool           { _, err := exec.LookPath("copilot"); return err == nil }
func (c *Copilot) Description() string    { return "GitHub Copilot CLI — coding agent" }
