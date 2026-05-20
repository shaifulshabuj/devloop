package backends

import "os/exec"

// OpenCode is a backend adapter for the OpenCode agent CLI.
type OpenCode struct{}

func (o *OpenCode) ID() string             { return "opencode" }
func (o *OpenCode) Binary() string         { return "opencode" }
func (o *OpenCode) DefaultArgs() []string  { return []string{} }
func (o *OpenCode) Detect() bool           { _, err := exec.LookPath("opencode"); return err == nil }
func (o *OpenCode) Description() string    { return "OpenCode — open-source AI coding agent" }
