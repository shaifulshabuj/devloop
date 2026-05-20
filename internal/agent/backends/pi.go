package backends

import "os/exec"

// Pi is a backend adapter for the Pi coding agent CLI.
type Pi struct{}

func (p *Pi) ID() string             { return "pi" }
func (p *Pi) Binary() string         { return "pi" }
func (p *Pi) DefaultArgs() []string  { return []string{} }
func (p *Pi) Detect() bool           { _, err := exec.LookPath("pi"); return err == nil }
func (p *Pi) Description() string    { return "Pi — coding agent" }
