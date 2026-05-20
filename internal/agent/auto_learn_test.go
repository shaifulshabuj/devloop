package agent

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/shaifulshabuj/devloop/v6/internal/storage"
)

// mockStore implements learnStore for testing.
type mockStore struct {
	tasks    []*storage.Task
	contexts map[string][]*storage.ContextEntry
}

func (m *mockStore) ListTasks(limit int) ([]*storage.Task, error) {
	if limit < len(m.tasks) {
		return m.tasks[:limit], nil
	}
	return m.tasks, nil
}

func (m *mockStore) GetContext(taskID string) ([]*storage.ContextEntry, error) {
	return m.contexts[taskID], nil
}

// TestProcessTask_Idempotent verifies that calling ProcessTask twice with the
// same task ID writes lessons to the file only once.
func TestProcessTask_Idempotent(t *testing.T) {
	dir := t.TempDir()
	lessonsPath := filepath.Join(dir, "lessons.md")

	al := NewAutoLearner(AutoLearnConfig{LessonsPath: lessonsPath}, &mockStore{})

	entries := []*storage.ContextEntry{
		{ID: "e1", TaskID: "task-1", Role: "assistant", Content: "lesson: always test your code"},
	}

	// First call — should write lessons.
	if err := al.ProcessTask("task-1", "Test Task", entries); err != nil {
		t.Fatalf("first ProcessTask: %v", err)
	}

	data1, err := os.ReadFile(lessonsPath)
	if err != nil {
		t.Fatalf("reading lessons after first call: %v", err)
	}

	// Second call — should be a no-op (idempotent).
	if err := al.ProcessTask("task-1", "Test Task", entries); err != nil {
		t.Fatalf("second ProcessTask: %v", err)
	}

	data2, err := os.ReadFile(lessonsPath)
	if err != nil {
		t.Fatalf("reading lessons after second call: %v", err)
	}

	if string(data1) != string(data2) {
		t.Errorf("lessons file changed on second call:\nbefore: %s\nafter: %s", data1, data2)
	}
}

// TestAutoLearner_Run_Cancels verifies that Run returns promptly when ctx is
// cancelled.
func TestAutoLearner_Run_Cancels(t *testing.T) {
	dir := t.TempDir()
	lessonsPath := filepath.Join(dir, "lessons.md")

	// Use a very long poll interval so the ticker never fires during the test.
	al := NewAutoLearner(AutoLearnConfig{
		LessonsPath:  lessonsPath,
		PollInterval: 10 * time.Minute,
	}, &mockStore{})

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)

	go func() {
		done <- al.Run(ctx)
	}()

	cancel()

	select {
	case <-done:
		// Run returned as expected.
	case <-time.After(time.Second):
		t.Fatal("Run did not return within 1s after context cancellation")
	}
}

// TestProcessTask_NoContext verifies that calling ProcessTask with an empty
// context entry slice writes no lessons and returns no error.
func TestProcessTask_NoContext(t *testing.T) {
	dir := t.TempDir()
	lessonsPath := filepath.Join(dir, "lessons.md")

	al := NewAutoLearner(AutoLearnConfig{LessonsPath: lessonsPath}, &mockStore{})

	if err := al.ProcessTask("task-empty", "Empty Task", nil); err != nil {
		t.Fatalf("ProcessTask with no context: %v", err)
	}

	if _, err := os.Stat(lessonsPath); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("expected lessons file not to be created for empty context")
	}
}
