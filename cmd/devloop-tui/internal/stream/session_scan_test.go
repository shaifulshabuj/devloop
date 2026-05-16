package stream

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// mkSessionDir creates <root>/.devloop/sessions/<id>/ and returns the session dir.
func mkSessionDir(t *testing.T, root, id string) string {
	t.Helper()
	dir := filepath.Join(root, ".devloop", "sessions", id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkSessionDir: %v", err)
	}
	return dir
}

// writeFile writes content to path.
func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("writeFile %s: %v", path, err)
	}
}

func TestScan_EmptyDir(t *testing.T) {
	root := t.TempDir()
	sessions, err := Scan(root)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if sessions != nil {
		t.Errorf("expected nil slice for empty dir, got %v", sessions)
	}
}

func TestScan_HappyPath(t *testing.T) {
	root := t.TempDir()

	// Create two sessions.
	// Session 1 — older
	dir1 := mkSessionDir(t, root, "TASK-20260516-100000")
	writeFile(t, filepath.Join(dir1, "feature.txt"), "add dark mode toggle")
	writeFile(t, filepath.Join(dir1, "status"), "approved")
	writeFile(t, filepath.Join(dir1, "started_at"), "2026-05-16T10:00:00")
	writeFile(t, filepath.Join(dir1, "finished_at"), "2026-05-16T10:05:30")
	writeFile(t, filepath.Join(dir1, "worker.state"), "done:2026-05-16T10:03:00")

	// Session 2 — newer
	dir2 := mkSessionDir(t, root, "TASK-20260516-120000")
	writeFile(t, filepath.Join(dir2, "feature.txt"), "refactor API client")
	writeFile(t, filepath.Join(dir2, "status"), "running")
	writeFile(t, filepath.Join(dir2, "started_at"), "2026-05-16T12:00:00")
	// No finished_at (still running)
	writeFile(t, filepath.Join(dir2, "architect.state"), "done:2026-05-16T12:01:00")

	sessions, err := Scan(root)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(sessions) != 2 {
		t.Fatalf("expected 2 sessions, got %d", len(sessions))
	}

	// Newest first.
	if sessions[0].ID != "TASK-20260516-120000" {
		t.Errorf("sessions[0].ID = %q, want TASK-20260516-120000", sessions[0].ID)
	}
	if sessions[1].ID != "TASK-20260516-100000" {
		t.Errorf("sessions[1].ID = %q, want TASK-20260516-100000", sessions[1].ID)
	}

	// Check session 2 (index 0 after sort).
	s2 := sessions[0]
	if s2.Feature != "refactor API client" {
		t.Errorf("sessions[0].Feature = %q", s2.Feature)
	}
	if s2.Status != "running" {
		t.Errorf("sessions[0].Status = %q", s2.Status)
	}
	if s2.Dir != dir2 {
		t.Errorf("sessions[0].Dir = %q", s2.Dir)
	}
	wantStart2 := time.Date(2026, 5, 16, 12, 0, 0, 0, time.Local)
	if !s2.StartedAt.Equal(wantStart2) {
		t.Errorf("sessions[0].StartedAt = %v, want %v", s2.StartedAt, wantStart2)
	}
	if !s2.FinishedAt.IsZero() {
		t.Errorf("sessions[0].FinishedAt should be zero (running), got %v", s2.FinishedAt)
	}
	ps, ok := s2.PhaseStates["architect"]
	if !ok {
		t.Fatal("sessions[0] missing PhaseState[architect]")
	}
	if ps.Status != "done" {
		t.Errorf("PhaseState[architect].Status = %q, want done", ps.Status)
	}

	// Check session 1 (index 1 after sort).
	s1 := sessions[1]
	if s1.Feature != "add dark mode toggle" {
		t.Errorf("sessions[1].Feature = %q", s1.Feature)
	}
	wantFinish1 := time.Date(2026, 5, 16, 10, 5, 30, 0, time.Local)
	if !s1.FinishedAt.Equal(wantFinish1) {
		t.Errorf("sessions[1].FinishedAt = %v, want %v", s1.FinishedAt, wantFinish1)
	}
	_, ok = s1.PhaseStates["worker"]
	if !ok {
		t.Fatal("sessions[1] missing PhaseState[worker]")
	}
}

func TestScan_MissingFiles(t *testing.T) {
	root := t.TempDir()
	// Create a session directory with no metadata files.
	_ = mkSessionDir(t, root, "TASK-20260516-090000")

	sessions, err := Scan(root)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(sessions) != 1 {
		t.Fatalf("expected 1 session, got %d", len(sessions))
	}

	s := sessions[0]
	if s.ID != "TASK-20260516-090000" {
		t.Errorf("ID = %q", s.ID)
	}
	if s.Dir == "" {
		t.Error("Dir should not be empty")
	}
	if s.Feature != "" {
		t.Errorf("Feature should be empty, got %q", s.Feature)
	}
	if s.Status != "" {
		t.Errorf("Status should be empty, got %q", s.Status)
	}
	if !s.StartedAt.IsZero() {
		t.Errorf("StartedAt should be zero, got %v", s.StartedAt)
	}
	if !s.FinishedAt.IsZero() {
		t.Errorf("FinishedAt should be zero, got %v", s.FinishedAt)
	}
	if len(s.PhaseStates) != 0 {
		t.Errorf("PhaseStates should be empty, got %v", s.PhaseStates)
	}
}

func TestScan_PhaseStates(t *testing.T) {
	root := t.TempDir()
	dir := mkSessionDir(t, root, "TASK-20260516-143000")
	writeFile(t, filepath.Join(dir, "started_at"), "2026-05-16T14:30:00")
	writeFile(t, filepath.Join(dir, "worker.state"), "done:2026-05-16T14:33:53")

	sessions, err := Scan(root)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(sessions) != 1 {
		t.Fatalf("expected 1 session, got %d", len(sessions))
	}

	ps, ok := sessions[0].PhaseStates["worker"]
	if !ok {
		t.Fatal("missing PhaseState[worker]")
	}
	if ps.Status != "done" {
		t.Errorf("PhaseState.Status = %q, want done", ps.Status)
	}
	wantTime := time.Date(2026, 5, 16, 14, 33, 53, 0, time.Local)
	if !ps.Time.Equal(wantTime) {
		t.Errorf("PhaseState.Time = %v, want %v", ps.Time, wantTime)
	}
}
