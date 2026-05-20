package agent

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestV5Bridge_NotFound verifies that a bridge pointing at a non-existent
// script reports itself as unavailable after Detect().
func TestV5Bridge_NotFound(t *testing.T) {
	b := NewV5Bridge("/nonexistent/devloop.sh")
	if b.Detect() {
		t.Fatal("Detect() returned true for a non-existent script")
	}
	if b.Available() {
		t.Fatal("Available() returned true after Detect() found nothing")
	}
}

// TestV5Bridge_Found writes a minimal shell script to a temp directory,
// marks it executable, and verifies that the bridge detects and runs it.
func TestV5Bridge_Found(t *testing.T) {
	dir := t.TempDir()
	scriptPath := filepath.Join(dir, "devloop.sh")

	const script = "#!/bin/sh\necho hello\n"
	if err := os.WriteFile(scriptPath, []byte(script), 0o755); err != nil {
		t.Fatalf("failed to write temp script: %v", err)
	}

	b := NewV5Bridge(scriptPath)

	if !b.Detect() {
		t.Fatal("Detect() returned false for a valid executable script")
	}
	if !b.Available() {
		t.Fatal("Available() returned false after successful Detect()")
	}

	output, err := b.Run(context.Background(), ".", []string{}, nil)
	if err != nil {
		t.Fatalf("Run() returned unexpected error: %v", err)
	}
	if !strings.Contains(output, "hello") {
		t.Errorf("expected output to contain %q, got %q", "hello", output)
	}
}

// TestV5Bridge_OutputCh verifies that stdout lines are forwarded to outputCh.
func TestV5Bridge_OutputCh(t *testing.T) {
	dir := t.TempDir()
	scriptPath := filepath.Join(dir, "devloop.sh")

	const script = "#!/bin/sh\necho line1\necho line2\n"
	if err := os.WriteFile(scriptPath, []byte(script), 0o755); err != nil {
		t.Fatalf("failed to write temp script: %v", err)
	}

	b := NewV5Bridge(scriptPath)
	b.Detect()

	ch := make(chan string, 10)
	output, err := b.Run(context.Background(), ".", []string{}, ch)
	close(ch)
	if err != nil {
		t.Fatalf("Run() returned unexpected error: %v", err)
	}

	if !strings.Contains(output, "line1") || !strings.Contains(output, "line2") {
		t.Errorf("unexpected output: %q", output)
	}

	var chLines []string
	for l := range ch {
		chLines = append(chLines, l)
	}
	if len(chLines) < 2 {
		t.Fatalf("expected at least 2 lines via outputCh, got %d", len(chLines))
	}
}
