package agent

import (
	"context"
	"errors"
	"testing"
	"time"
)

// TestDetect verifies Detect() runs without panicking and that the built-in
// backends (claude, copilot, opencode, pi) are never confused with a shell
// built-in like "echo" that is not a registered backend.
func TestDetect(t *testing.T) {
	r := NewRunner()
	// Must not panic.
	r.Detect()

	// "echo" is a shell built-in, never a registered backend.
	if _, ok := r.backends["echo"]; ok {
		t.Error("echo should not be a built-in backend")
	}

	// AvailableBackends must only return backends whose Found flag is true.
	for _, b := range r.AvailableBackends() {
		if !b.Found {
			t.Errorf("AvailableBackends returned backend %q with Found=false", b.ID)
		}
	}
}

// TestSpawnUnknownBackend verifies that spawning a backend that was never
// registered returns an error instead of panicking.
func TestSpawnUnknownBackend(t *testing.T) {
	r := NewRunner()
	_, err := r.Spawn(context.Background(), "definitely-does-not-exist", SpawnOpts{})
	if err == nil {
		t.Fatal("expected error for unknown backend, got nil")
	}
}

// TestSpawnContextCancel verifies that cancelling the context causes Spawn to
// return quickly with context.Canceled and a non-nil partial session.
func TestSpawnContextCancel(t *testing.T) {
	r := NewRunner()
	// Inject a long-running subprocess using /bin/sleep from PATH.
	r.backends["sleeper"] = &Backend{
		ID:     "sleeper",
		Binary: "/bin/sleep",
		Args:   []string{"30"},
		Found:  true,
	}

	ctx, cancel := context.WithCancel(context.Background())
	start := time.Now()

	// Cancel the context shortly after the subprocess starts.
	go func() {
		time.Sleep(150 * time.Millisecond)
		cancel()
	}()

	sess, err := r.Spawn(ctx, "sleeper", SpawnOpts{})
	elapsed := time.Since(start)

	if !errors.Is(err, context.Canceled) {
		t.Fatalf("expected context.Canceled, got %v", err)
	}
	if elapsed > 5*time.Second {
		t.Fatalf("Spawn took too long to return after cancel: %v", elapsed)
	}
	if sess == nil {
		t.Fatal("expected a non-nil partial session, got nil")
	}
}

// TestSpawnOutputLines verifies that stdout lines are captured in the session
// and forwarded to OutputCh.
func TestSpawnOutputLines(t *testing.T) {
	r := NewRunner()
	// Use /bin/sh -c so we can emit a controlled line.
	r.backends["sh"] = &Backend{
		ID:     "sh",
		Binary: "/bin/sh",
		Args:   []string{"-c", "echo hello world"},
		Found:  true,
	}

	ch := make(chan string, 10)
	sess, err := r.Spawn(context.Background(), "sh", SpawnOpts{OutputCh: ch})
	close(ch)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(sess.Lines) == 0 {
		t.Fatal("expected at least one line in session")
	}
	if sess.Lines[0] != "hello world" {
		t.Errorf("expected 'hello world', got %q", sess.Lines[0])
	}

	// Drain the channel and verify the line arrived there too.
	var chLines []string
	for l := range ch {
		chLines = append(chLines, l)
	}
	if len(chLines) == 0 {
		t.Fatal("expected at least one line delivered via OutputCh")
	}
	if chLines[0] != "hello world" {
		t.Errorf("OutputCh: expected 'hello world', got %q", chLines[0])
	}
}

// TestSpawnStdinInput verifies that InputText is written to stdin and consumed
// by the subprocess (using /bin/cat which echoes stdin to stdout).
func TestSpawnStdinInput(t *testing.T) {
	r := NewRunner()
	r.backends["cat"] = &Backend{
		ID:     "cat",
		Binary: "/bin/cat",
		Args:   []string{},
		Found:  true,
	}

	sess, err := r.Spawn(context.Background(), "cat", SpawnOpts{
		InputText: "ping",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(sess.Lines) == 0 {
		t.Fatal("expected at least one line from cat")
	}
	if sess.Lines[0] != "ping" {
		t.Errorf("expected 'ping', got %q", sess.Lines[0])
	}
}
