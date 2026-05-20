package agent

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"os/exec"
	"strings"
	"time"

	"github.com/google/uuid"
)

// Backend describes a CLI agent backend that can be spawned as a subprocess.
type Backend struct {
	ID     string   // e.g. "claude", "copilot", "opencode", "pi"
	Binary string   // actual binary name looked up in PATH
	Args   []string // default CLI arguments
	Found  bool     // set by Detect()
}

// Session holds the captured output of one spawned subprocess.
type Session struct {
	ID        string
	Backend   string
	StartedAt time.Time
	Lines     []string
	ExitCode  int
}

// SpawnOpts controls how Spawn launches and communicates with a subprocess.
type SpawnOpts struct {
	// OutputCh receives each stdout line as it arrives; may be nil.
	OutputCh chan<- string
	// InputText is written to the subprocess's stdin; a trailing newline is
	// added if not already present. Empty string means stdin is not piped.
	InputText string
}

// Runner manages a set of named agent backends.
type Runner struct {
	backends map[string]*Backend
}

// NewRunner returns a Runner pre-loaded with the four built-in backends.
func NewRunner() *Runner {
	r := &Runner{backends: make(map[string]*Backend)}
	for _, b := range []*Backend{
		{ID: "claude", Binary: "claude", Args: []string{"--permission-mode", "acceptEdits"}},
		{ID: "copilot", Binary: "copilot", Args: []string{}},
		{ID: "opencode", Binary: "opencode", Args: []string{}},
		{ID: "pi", Binary: "pi", Args: []string{}},
	} {
		r.backends[b.ID] = b
	}
	return r
}

// Detect probes PATH for each backend binary and updates Backend.Found.
func (r *Runner) Detect() {
	for _, b := range r.backends {
		path, err := exec.LookPath(b.Binary)
		if err == nil {
			b.Found = true
			log.Printf("agent: backend %q available at %s", b.ID, path)
		} else {
			b.Found = false
			log.Printf("agent: backend %q not available in PATH", b.ID)
		}
	}
}

// AvailableBackends returns only the backends whose Found flag is true.
func (r *Runner) AvailableBackends() []*Backend {
	var out []*Backend
	for _, b := range r.backends {
		if b.Found {
			out = append(out, b)
		}
	}
	return out
}

// SetBackendArgs overrides the default argument list for a named backend.
func (r *Runner) SetBackendArgs(id string, args []string) {
	if b, ok := r.backends[id]; ok {
		b.Args = args
	}
}

// limitPatterns are substrings (lowercase) that indicate a backend has hit a
// usage/session/rate limit and a failover to the next backend should be tried.
var limitPatterns = []string{
	"session limit",
	"rate limit",
	"hit your limit",
	"hit limit",
	"usage limit",
	"you've hit",
	"you have hit",
	"quota exceeded",
	"too many requests",
	"resets ",
}

// failoverOrder defines the priority order for automatic backend failover.
// When a backend hits a limit, the next available backend in this list is tried.
var failoverOrder = []string{"claude", "copilot", "opencode", "pi"}

// IsLimitError reports whether the session output or error message indicates
// the backend has hit a rate/session limit and a failover should be attempted.
// stdout is always checked regardless of exit code — some backends output their
// limit message to stdout and exit with code 0 rather than a non-zero code.
func IsLimitError(sess *Session, err error) bool {
	check := func(s string) bool {
		lower := strings.ToLower(s)
		for _, p := range limitPatterns {
			if strings.Contains(lower, p) {
				return true
			}
		}
		return false
	}
	if err != nil && check(err.Error()) {
		return true
	}
	// Check stdout lines regardless of exit code.
	if sess != nil {
		for _, line := range sess.Lines {
			if check(line) {
				return true
			}
		}
	}
	return false
}

// SpawnWithFailover tries the preferred backend first, then automatically
// falls back through failoverOrder when a limit error is detected.
// Returns the session, the backend that actually ran, and any error.
func (r *Runner) SpawnWithFailover(ctx context.Context, preferredBackend string, opts SpawnOpts) (*Session, string, error) {
	// Build ordered candidate list: preferred backend first, then failover order.
	seen := map[string]bool{}
	var order []string
	for _, id := range append([]string{preferredBackend}, failoverOrder...) {
		if !seen[id] {
			seen[id] = true
			order = append(order, id)
		}
	}

	var lastSess *Session
	var lastErr error
	anyTried := false

	for _, id := range order {
		b, ok := r.backends[id]
		if !ok || !b.Found {
			continue
		}
		anyTried = true
		if id != preferredBackend {
			log.Printf("agent: failover — trying backend %q (previous hit limit)", id)
		}

		sess, err := r.Spawn(ctx, id, opts)

		// Check for limit in stdout even on clean exit (exit 0 + limit message).
		if IsLimitError(sess, err) {
			lastSess, lastErr = sess, err
			if lastErr == nil {
				lastErr = fmt.Errorf("agent: backend %q hit usage limit", id)
			}
			log.Printf("agent: backend %q hit limit, failing over to next backend", id)
			continue
		}

		if err == nil {
			return sess, id, nil
		}

		lastSess, lastErr = sess, err

		if ctx.Err() != nil {
			return sess, id, ctx.Err()
		}
		// Real error (not a limit) — stop immediately, don't try other backends.
		return sess, id, err
	}

	if !anyTried {
		return nil, preferredBackend, fmt.Errorf("agent: no available backend found in [%s]",
			strings.Join(order, ", "))
	}

	// If all backends were exhausted by usage limits, surface the limit message
	// from stdout (much more useful than "subprocess exited with code 1").
	if IsLimitError(lastSess, lastErr) && lastSess != nil {
		for _, line := range lastSess.Lines {
			lower := strings.ToLower(line)
			if strings.Contains(lower, "limit") || strings.Contains(lower, "resets") {
				return lastSess, preferredBackend, fmt.Errorf("agent: %s", line)
			}
		}
	}

	return lastSess, preferredBackend, lastErr
}

// Spawn launches the named backend as a subprocess and streams its stdout.
//
// Behaviour:
//   - Returns an error immediately if the backend is not registered or not found.
//   - Writes opts.InputText to stdin (closing it afterwards) when non-empty.
//   - Delivers each stdout line to opts.OutputCh when provided.
//   - On ctx cancellation the subprocess is killed; Spawn returns the partial
//     Session together with the context error.
//   - On a non-zero exit code Spawn returns an error wrapping captured stderr.
func (r *Runner) Spawn(ctx context.Context, backendID string, opts SpawnOpts) (*Session, error) {
	b, ok := r.backends[backendID]
	if !ok || !b.Found {
		return nil, fmt.Errorf("agent: backend %q is not registered or not installed", backendID)
	}

	sess := &Session{
		ID:        uuid.New().String(),
		Backend:   backendID,
		StartedAt: time.Now(),
	}

	//nolint:gosec // intentional subprocess invocation
	cmd := exec.CommandContext(ctx, b.Binary, b.Args...)
	var stderrBuf bytes.Buffer
	cmd.Stderr = &stderrBuf

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("agent: stdout pipe: %w", err)
	}

	var stdinPipe io.WriteCloser
	if opts.InputText != "" {
		stdinPipe, err = cmd.StdinPipe()
		if err != nil {
			return nil, fmt.Errorf("agent: stdin pipe: %w", err)
		}
	}

	if err = cmd.Start(); err != nil {
		return nil, fmt.Errorf("agent: start %q: %w", b.Binary, err)
	}

	if stdinPipe != nil {
		text := opts.InputText
		if !strings.HasSuffix(text, "\n") {
			text += "\n"
		}
		if _, werr := io.WriteString(stdinPipe, text); werr != nil {
			log.Printf("agent: stdin write: %v", werr)
		}
		if cerr := stdinPipe.Close(); cerr != nil {
			log.Printf("agent: stdin close: %v", cerr)
		}
	}

	scanner := bufio.NewScanner(stdout)
	for scanner.Scan() {
		line := scanner.Text()
		sess.Lines = append(sess.Lines, line)
		if opts.OutputCh != nil {
			select {
			case opts.OutputCh <- line:
			case <-ctx.Done():
				// Do not block sending when context is already cancelled.
			}
		}
	}

	waitErr := cmd.Wait()
	if waitErr != nil {
		var exitErr *exec.ExitError
		if errors.As(waitErr, &exitErr) {
			sess.ExitCode = exitErr.ExitCode()
		}
		// Prefer returning the context error so callers can distinguish
		// cancellation from subprocess failure.
		if ctx.Err() != nil {
			return sess, ctx.Err()
		}
		return sess, fmt.Errorf("agent: subprocess exited with code %d: %s",
			sess.ExitCode, stderrBuf.String())
	}

	return sess, nil
}
