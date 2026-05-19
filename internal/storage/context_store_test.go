package storage

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestContextStore_MemoryOnly(t *testing.T) {
	cs, err := NewContextStore("")
	if err != nil {
		t.Fatalf("NewContextStore: %v", err)
	}

	// Add messages for two different tasks.
	msgs := []Message{
		{TaskID: "task-1", Role: "user", Content: "hello"},
		{TaskID: "task-1", Role: "assistant", Content: "world"},
		{TaskID: "task-2", Role: "user", Content: "foo"},
	}
	for i := range msgs {
		if err := cs.Add(msgs[i]); err != nil {
			t.Fatalf("Add: %v", err)
		}
	}

	// Verify GetByTaskID for task-1.
	got := cs.GetByTaskID("task-1")
	if len(got) != 2 {
		t.Fatalf("GetByTaskID task-1: want 2, got %d", len(got))
	}
	if got[0].Role != "user" || got[1].Role != "assistant" {
		t.Errorf("unexpected roles: %v", got)
	}

	// Verify IDs are auto-generated.
	for _, m := range got {
		if m.ID == "" {
			t.Errorf("expected non-empty ID, got empty")
		}
	}

	// Verify All returns three messages.
	all := cs.All()
	if len(all) != 3 {
		t.Fatalf("All: want 3, got %d", len(all))
	}

	// Clear task-1 and verify.
	cs.Clear("task-1")
	if got := cs.GetByTaskID("task-1"); len(got) != 0 {
		t.Fatalf("after Clear task-1: want 0, got %d", len(got))
	}
	if got := cs.GetByTaskID("task-2"); len(got) != 1 {
		t.Fatalf("after Clear task-1: task-2 want 1, got %d", len(got))
	}
}

func TestContextStore_FileBackedRoundtrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "context.jsonl")

	// Write messages to file-backed store.
	cs1, err := NewContextStore(path)
	if err != nil {
		t.Fatalf("NewContextStore (write): %v", err)
	}

	want := []Message{
		{TaskID: "t1", Role: "system", Content: "you are helpful", CreatedAt: time.Now().UTC().Truncate(time.Millisecond)},
		{TaskID: "t1", Role: "user", Content: "ping"},
		{TaskID: "t2", Role: "user", Content: "other task"},
	}
	for i := range want {
		if err := cs1.Add(want[i]); err != nil {
			t.Fatalf("Add: %v", err)
		}
	}

	// Verify file was created.
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("context file not created: %v", err)
	}

	// Load a fresh store from the same file.
	cs2, err := NewContextStore(path)
	if err != nil {
		t.Fatalf("NewContextStore (read): %v", err)
	}

	all := cs2.All()
	if len(all) != len(want) {
		t.Fatalf("loaded messages: want %d, got %d", len(want), len(all))
	}

	for i, m := range all {
		if m.TaskID != want[i].TaskID {
			t.Errorf("[%d] TaskID: want %q, got %q", i, want[i].TaskID, m.TaskID)
		}
		if m.Role != want[i].Role {
			t.Errorf("[%d] Role: want %q, got %q", i, want[i].Role, m.Role)
		}
		if m.Content != want[i].Content {
			t.Errorf("[%d] Content: want %q, got %q", i, want[i].Content, m.Content)
		}
		if m.ID == "" {
			t.Errorf("[%d] ID should be non-empty after roundtrip", i)
		}
	}

	// GetByTaskID on loaded store.
	t1msgs := cs2.GetByTaskID("t1")
	if len(t1msgs) != 2 {
		t.Fatalf("GetByTaskID t1 after reload: want 2, got %d", len(t1msgs))
	}
}

func TestContextStore_MissingFileIsNotError(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nonexistent.jsonl")
	cs, err := NewContextStore(path)
	if err != nil {
		t.Fatalf("expected no error for missing file, got: %v", err)
	}
	if len(cs.All()) != 0 {
		t.Fatal("expected empty store for missing file")
	}
}
