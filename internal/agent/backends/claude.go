package backends

import "os/exec"

// Claude is a backend adapter for the Claude CLI agent.
type Claude struct{}

func (c *Claude) ID() string             { return "claude" }
func (c *Claude) Binary() string         { return "claude" }
func (c *Claude) DefaultArgs() []string  { return []string{"--permission-mode", "acceptEdits"} }
func (c *Claude) Detect() bool           { _, err := exec.LookPath("claude"); return err == nil }
func (c *Claude) Description() string    { return "Claude CLI — Anthropic coding agent" }
