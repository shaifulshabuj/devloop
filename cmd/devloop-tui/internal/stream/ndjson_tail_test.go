package stream

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

const tailTimeout = 5 * time.Second

// drainN reads exactly n events from ch within timeout. Returns the events
// collected; if fewer than n arrive it returns what arrived and t.Fatal fires.
func drainN(t *testing.T, ch <-chan Event, n int, timeout time.Duration) []Event {
	t.Helper()
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	got := make([]Event, 0, n)
	for len(got) < n {
		select {
		case ev, ok := <-ch:
			if !ok {
				t.Fatalf("channel closed after %d/%d events", len(got), n)
			}
			got = append(got, ev)
		case <-timer.C:
			t.Fatalf("timed out waiting for event %d/%d", len(got)+1, n)
		}
	}
	return got
}

// waitClose waits for a channel to close within timeout.
func waitClose(t *testing.T, ch <-chan Event, timeout time.Duration) {
	t.Helper()
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	for {
		select {
		case _, ok := <-ch:
			if !ok {
				return
			}
			// Drain any remaining events.
		case <-timer.C:
			t.Fatal("events channel did not close within timeout after context cancel")
		}
	}
}

// sampleLine produces a valid NDJSON event line for testing.
func sampleLine(session, kind string) []byte {
	return []byte(`{"ts":"2026-05-16T14:32:11Z","session":"` + session + `","kind":"` + kind + `"}`)
}

func TestTailer_ExistingThenAppend(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "events.ndjson")

	// Write 2 existing lines.
	line1 := sampleLine("S1", "session.start")
	line2 := sampleLine("S1", "phase.start")
	content := append(line1, '\n')
	content = append(content, line2...)
	content = append(content, '\n')
	if err := os.WriteFile(path, content, 0o644); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	tailer := &Tailer{Path: path}
	events, _, err := tailer.Run(ctx)
	if err != nil {
		t.Fatal(err)
	}

	// Should receive the 2 existing events.
	got := drainN(t, events, 2, tailTimeout)
	if got[0].Kind != "session.start" {
		t.Errorf("event[0].Kind = %q, want session.start", got[0].Kind)
	}
	if got[1].Kind != "phase.start" {
		t.Errorf("event[1].Kind = %q, want phase.start", got[1].Kind)
	}

	// Append a 3rd line.
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	line3 := sampleLine("S1", "phase.end")
	if _, err := f.Write(append(line3, '\n')); err != nil {
		t.Fatal(err)
	}
	f.Close()

	// Should receive the 3rd event.
	got3 := drainN(t, events, 1, tailTimeout)
	if got3[0].Kind != "phase.end" {
		t.Errorf("event[2].Kind = %q, want phase.end", got3[0].Kind)
	}

	// Cancel and verify channels close.
	cancel()
	waitClose(t, events, tailTimeout)
}

func TestTailer_WaitsForCreate(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "events.ndjson")
	// Path does NOT exist yet.

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	tailer := &Tailer{Path: path}
	events, _, err := tailer.Run(ctx)
	if err != nil {
		t.Fatal(err)
	}

	// Small delay to ensure the tailer is watching before we create the file.
	time.Sleep(50 * time.Millisecond)

	// Create the file with 1 line.
	line := sampleLine("S2", "session.start")
	if err := os.WriteFile(path, append(line, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}

	got := drainN(t, events, 1, tailTimeout)
	if got[0].Kind != "session.start" {
		t.Errorf("Kind = %q, want session.start", got[0].Kind)
	}

	cancel()
	waitClose(t, events, tailTimeout)
}

func TestTailer_Truncation(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "events.ndjson")

	// Write 3 lines.
	var content []byte
	for i, kind := range []string{"session.start", "phase.start", "phase.end"} {
		_ = i
		content = append(content, sampleLine("S3", kind)...)
		content = append(content, '\n')
	}
	if err := os.WriteFile(path, content, 0o644); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	tailer := &Tailer{Path: path}
	events, _, err := tailer.Run(ctx)
	if err != nil {
		t.Fatal(err)
	}

	// Drain the initial 3 events.
	drainN(t, events, 3, tailTimeout)

	// Truncate the file and write 1 fresh line.
	freshLine := sampleLine("S3", "session.end")
	if err := os.WriteFile(path, append(freshLine, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}

	// Verify the fresh event arrives. Re-emits of older lines are tolerated —
	// we just need to confirm "session.end" shows up eventually.
	found := false
	timer := time.NewTimer(tailTimeout)
	defer timer.Stop()
outer:
	for {
		select {
		case ev, ok := <-events:
			if !ok {
				break outer
			}
			if ev.Kind == "session.end" {
				found = true
				break outer
			}
		case <-timer.C:
			break outer
		}
	}
	if !found {
		t.Error("did not receive session.end after truncation")
	}

	cancel()
	waitClose(t, events, tailTimeout)
}
