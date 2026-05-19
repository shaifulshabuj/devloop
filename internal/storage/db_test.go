package storage

import (
	"testing"

	"github.com/google/uuid"
)

// openTestStore opens an in-memory SQLite store for testing.
func openTestStore(t *testing.T) *Store {
	t.Helper()
	s, err := Open(":memory:")
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func TestCreateTaskGetTask(t *testing.T) {
	t.Parallel()
	s := openTestStore(t)

	id := uuid.New().String()
	if err := s.CreateTask(id, "my first task"); err != nil {
		t.Fatalf("CreateTask: %v", err)
	}

	got, err := s.GetTask(id)
	if err != nil {
		t.Fatalf("GetTask: %v", err)
	}

	if got.ID != id {
		t.Errorf("ID: got %q, want %q", got.ID, id)
	}
	if got.Title != "my first task" {
		t.Errorf("Title: got %q, want %q", got.Title, "my first task")
	}
	if got.Status != "pending" {
		t.Errorf("Status: got %q, want pending", got.Status)
	}
	if got.CreatedAt == 0 {
		t.Error("CreatedAt should be non-zero")
	}
	if got.UpdatedAt == 0 {
		t.Error("UpdatedAt should be non-zero")
	}
}

func TestListTasksCount(t *testing.T) {
	t.Parallel()
	s := openTestStore(t)

	for i := range 5 {
		id := uuid.New().String()
		if err := s.CreateTask(id, uuid.New().String()); err != nil {
			t.Fatalf("CreateTask[%d]: %v", i, err)
		}
	}

	tasks, err := s.ListTasks(10)
	if err != nil {
		t.Fatalf("ListTasks: %v", err)
	}
	if len(tasks) != 5 {
		t.Errorf("len(tasks): got %d, want 5", len(tasks))
	}

	// Limit is respected.
	limited, err := s.ListTasks(3)
	if err != nil {
		t.Fatalf("ListTasks(3): %v", err)
	}
	if len(limited) != 3 {
		t.Errorf("len(limited): got %d, want 3", len(limited))
	}
}

func TestUpdateTaskStatus(t *testing.T) {
	t.Parallel()
	s := openTestStore(t)

	id := uuid.New().String()
	if err := s.CreateTask(id, "status-test"); err != nil {
		t.Fatalf("CreateTask: %v", err)
	}

	if err := s.UpdateTaskStatus(id, "running"); err != nil {
		t.Fatalf("UpdateTaskStatus: %v", err)
	}

	got, err := s.GetTask(id)
	if err != nil {
		t.Fatalf("GetTask: %v", err)
	}
	if got.Status != "running" {
		t.Errorf("Status: got %q, want running", got.Status)
	}
}

func TestCreateStepUpdateStep(t *testing.T) {
	t.Parallel()
	s := openTestStore(t)

	taskID := uuid.New().String()
	if err := s.CreateTask(taskID, "step-test"); err != nil {
		t.Fatalf("CreateTask: %v", err)
	}

	stepID := uuid.New().String()
	if err := s.CreateStep(stepID, taskID, "compile sources"); err != nil {
		t.Fatalf("CreateStep: %v", err)
	}

	if err := s.UpdateStep(stepID, "done", "build succeeded"); err != nil {
		t.Fatalf("UpdateStep: %v", err)
	}

	// Verify via a direct query (no GetStep exposed in spec).
	row := s.db.QueryRow("SELECT status, output FROM steps WHERE id = ?", stepID)
	var status, output string
	if err := row.Scan(&status, &output); err != nil {
		t.Fatalf("Scan step row: %v", err)
	}
	if status != "done" {
		t.Errorf("step status: got %q, want done", status)
	}
	if output != "build succeeded" {
		t.Errorf("step output: got %q, want %q", output, "build succeeded")
	}
}

func TestAppendContextGetContext(t *testing.T) {
	t.Parallel()
	s := openTestStore(t)

	taskID := uuid.New().String()
	if err := s.CreateTask(taskID, "ctx-test"); err != nil {
		t.Fatalf("CreateTask: %v", err)
	}

	msgs := []struct{ role, content string }{
		{"user", "hello"},
		{"assistant", "world"},
		{"user", "goodbye"},
	}
	for _, m := range msgs {
		if err := s.AppendContext(uuid.New().String(), taskID, m.role, m.content); err != nil {
			t.Fatalf("AppendContext(%q): %v", m.role, err)
		}
	}

	entries, err := s.GetContext(taskID)
	if err != nil {
		t.Fatalf("GetContext: %v", err)
	}
	if len(entries) != len(msgs) {
		t.Fatalf("len(entries): got %d, want %d", len(entries), len(msgs))
	}
	for i, e := range entries {
		if e.Role != msgs[i].role {
			t.Errorf("entries[%d].Role: got %q, want %q", i, e.Role, msgs[i].role)
		}
		if e.Content != msgs[i].content {
			t.Errorf("entries[%d].Content: got %q, want %q", i, e.Content, msgs[i].content)
		}
		if e.TaskID != taskID {
			t.Errorf("entries[%d].TaskID: got %q, want %q", i, e.TaskID, taskID)
		}
	}
}
