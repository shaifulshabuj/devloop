package agent

import (
	"testing"
)

func TestSessionID_Deterministic(t *testing.T) {
	id1 := SessionID("proj-123", "orchestrator")
	id2 := SessionID("proj-123", "orchestrator")
	if id1 != id2 {
		t.Errorf("expected deterministic ID, got %q and %q", id1, id2)
	}
}

func TestSessionID_Different(t *testing.T) {
	id1 := SessionID("proj-123", "orchestrator")
	id2 := SessionID("proj-123", "worker")
	if id1 == id2 {
		t.Errorf("expected different IDs for different roles, both got %q", id1)
	}
}

func TestPool_Get_CreatesNew(t *testing.T) {
	pool := NewSessionPool(NewRunner())
	ps := pool.Get("proj-1", "orchestrator", "claude")

	if ps == nil {
		t.Fatal("expected a PooledSession, got nil")
	}
	if ps.ProjectID != "proj-1" {
		t.Errorf("expected ProjectID %q, got %q", "proj-1", ps.ProjectID)
	}
	if ps.Role != "orchestrator" {
		t.Errorf("expected Role %q, got %q", "orchestrator", ps.Role)
	}
	if ps.Backend != "claude" {
		t.Errorf("expected Backend %q, got %q", "claude", ps.Backend)
	}
	if ps.UseCount != 1 {
		t.Errorf("expected UseCount 1, got %d", ps.UseCount)
	}
	want := SessionID("proj-1", "orchestrator")
	if ps.ID != want {
		t.Errorf("expected deterministic ID %q, got %q", want, ps.ID)
	}
}

func TestPool_Get_Reuses(t *testing.T) {
	pool := NewSessionPool(NewRunner())

	first := pool.Get("proj-2", "worker", "claude")
	firstID := first.ID

	second := pool.Get("proj-2", "worker", "claude")
	if second.ID != firstID {
		t.Errorf("expected same ID on reuse, got %q and %q", firstID, second.ID)
	}
	if second.UseCount != 2 {
		t.Errorf("expected UseCount 2, got %d", second.UseCount)
	}
}

func TestPool_Remove(t *testing.T) {
	pool := NewSessionPool(NewRunner())

	first := pool.Get("proj-3", "reviewer", "claude")
	firstID := first.ID

	pool.Remove("proj-3", "reviewer")

	// After removal, Get should create a fresh session.
	second := pool.Get("proj-3", "reviewer", "claude")

	// The ID is deterministic, so it must match the original.
	if second.ID != firstID {
		t.Errorf("expected same deterministic ID after Remove+Get, got %q and %q", firstID, second.ID)
	}
	// UseCount resets to 1 because this is a fresh session.
	if second.UseCount != 1 {
		t.Errorf("expected UseCount 1 after Remove+Get, got %d", second.UseCount)
	}
}
