package views

import (
	"os"
	"path/filepath"
)

// devloopInvocation returns the argv prefix needed to invoke devloop.
// If devloop.sh exists in root (dev / self-hosted mode) it is executed via
// bash.  Otherwise the globally installed `devloop` CLI on PATH is used.
func devloopInvocation(root string, sub ...string) []string {
	local := filepath.Join(root, "devloop.sh")
	if _, err := os.Stat(local); err == nil {
		return append([]string{"bash", local}, sub...)
	}
	return append([]string{"devloop"}, sub...)
}
