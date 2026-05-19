package agent

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// V5Bridge provides fallback execution via the legacy devloop.sh script.
type V5Bridge struct {
	scriptPath string // absolute path to devloop.sh
	found      bool   // set by Detect()
}

// NewV5Bridge creates a bridge pointing at scriptPath.
func NewV5Bridge(scriptPath string) *V5Bridge {
	return &V5Bridge{scriptPath: scriptPath}
}

// Detect checks whether scriptPath exists and is executable.
// Sets v.found accordingly.
func (v *V5Bridge) Detect() bool {
	info, err := os.Stat(v.scriptPath)
	if err != nil {
		v.found = false
		return false
	}
	// Check that at least one execute bit is set.
	v.found = info.Mode()&0o111 != 0
	return v.found
}

// Available returns true if the script was found by Detect().
func (v *V5Bridge) Available() bool {
	return v.found
}

// Run executes `devloop.sh <args...>` as a subprocess in workDir,
// streaming stdout lines to outputCh (if non-nil).
// Returns the combined output and any error.
func (v *V5Bridge) Run(ctx context.Context, workDir string, args []string, outputCh chan<- string) (string, error) {
	//nolint:gosec // intentional subprocess invocation of user-supplied script
	cmd := exec.CommandContext(ctx, v.scriptPath, args...)
	cmd.Dir = workDir

	var stderrBuf bytes.Buffer
	cmd.Stderr = &stderrBuf

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return "", fmt.Errorf("v5bridge: stdout pipe: %w", err)
	}

	if err = cmd.Start(); err != nil {
		return "", fmt.Errorf("v5bridge: start %q: %w", v.scriptPath, err)
	}

	var lines []string
	scanner := bufio.NewScanner(stdout)
	for scanner.Scan() {
		line := scanner.Text()
		lines = append(lines, line)
		if outputCh != nil {
			select {
			case outputCh <- line:
			case <-ctx.Done():
				// Do not block sending when context is already cancelled.
			}
		}
	}

	waitErr := cmd.Wait()
	output := strings.Join(lines, "\n")

	if waitErr != nil {
		var exitErr *exec.ExitError
		if errors.As(waitErr, &exitErr) {
			// Prefer the context error so callers can distinguish cancellation
			// from subprocess failure.
			if ctx.Err() != nil {
				return output, ctx.Err()
			}
			return output, fmt.Errorf("v5bridge: subprocess exited with code %d: %s",
				exitErr.ExitCode(), stderrBuf.String())
		}
		return output, fmt.Errorf("v5bridge: wait: %w", waitErr)
	}

	return output, nil
}
