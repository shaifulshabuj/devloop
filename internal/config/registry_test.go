package config

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestLoadRegistry_MissingFile_ReturnsEmpty(t *testing.T) {
	r, err := LoadRegistry("/nonexistent/path/projects.toml")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if r == nil {
		t.Fatal("registry must not be nil")
	}
	if len(r.Projects) != 0 {
		t.Errorf("expected empty registry, got %d entries", len(r.Projects))
	}
}

func TestRegistryAdd_ListReturnsEntry(t *testing.T) {
	r := &Registry{}
	entry := ProjectEntry{
		Name:     "myproject",
		Path:     "/home/user/myproject",
		LastUsed: time.Now(),
	}

	if err := r.Add(entry); err != nil {
		t.Fatalf("Add() error: %v", err)
	}

	list := r.List()
	if len(list) != 1 {
		t.Fatalf("expected 1 entry, got %d", len(list))
	}
	if list[0].Path != entry.Path {
		t.Errorf("expected path %q, got %q", entry.Path, list[0].Path)
	}
	if list[0].Name != entry.Name {
		t.Errorf("expected name %q, got %q", entry.Name, list[0].Name)
	}
}

func TestRegistryAdd_SamePath_IdempotentUpdatesLastUsed(t *testing.T) {
	r := &Registry{}

	first := ProjectEntry{
		Name:     "myproject",
		Path:     "/home/user/myproject",
		LastUsed: time.Now().Add(-time.Hour),
	}
	if err := r.Add(first); err != nil {
		t.Fatalf("first Add() error: %v", err)
	}

	later := time.Now()
	second := ProjectEntry{
		Name:     "myproject",
		Path:     "/home/user/myproject",
		LastUsed: later,
	}
	if err := r.Add(second); err != nil {
		t.Fatalf("second Add() error: %v", err)
	}

	list := r.List()
	if len(list) != 1 {
		t.Fatalf("expected exactly 1 entry after idempotent add, got %d", len(list))
	}
	if !list[0].LastUsed.Equal(later) {
		t.Errorf("expected LastUsed to be updated; got %v, want %v", list[0].LastUsed, later)
	}
}

func TestRegistryRemove_EntryGone(t *testing.T) {
	r := &Registry{}

	if err := r.Add(ProjectEntry{Name: "a", Path: "/a", LastUsed: time.Now()}); err != nil {
		t.Fatalf("Add a: %v", err)
	}
	if err := r.Add(ProjectEntry{Name: "b", Path: "/b", LastUsed: time.Now()}); err != nil {
		t.Fatalf("Add b: %v", err)
	}

	if err := r.Remove("/a"); err != nil {
		t.Fatalf("Remove: %v", err)
	}

	list := r.List()
	if len(list) != 1 {
		t.Fatalf("expected 1 entry after Remove, got %d", len(list))
	}
	if list[0].Path != "/b" {
		t.Errorf("expected remaining entry path=/b, got %q", list[0].Path)
	}
}

func TestRegistryTouchLastUsed_UpdatesTimestamp(t *testing.T) {
	r := &Registry{}
	old := time.Now().Add(-time.Hour)
	if err := r.Add(ProjectEntry{Name: "p", Path: "/p", LastUsed: old}); err != nil {
		t.Fatalf("Add: %v", err)
	}

	before := time.Now()
	if err := r.TouchLastUsed("/p"); err != nil {
		t.Fatalf("TouchLastUsed: %v", err)
	}

	list := r.List()
	if len(list) != 1 {
		t.Fatalf("expected 1 entry, got %d", len(list))
	}
	if !list[0].LastUsed.After(before) {
		t.Errorf("expected LastUsed after %v, got %v", before, list[0].LastUsed)
	}
}

func TestRegistryTouchLastUsed_NoOp_WhenNotFound(t *testing.T) {
	r := &Registry{}
	if err := r.TouchLastUsed("/nonexistent"); err != nil {
		t.Fatalf("TouchLastUsed on missing entry should be a no-op, got: %v", err)
	}
}

func TestRegistry_SaveLoad_RoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "projects.toml")

	r := &Registry{}
	now := time.Now().Truncate(time.Second) // TOML has second precision
	if err := r.Add(ProjectEntry{Name: "alpha", Path: "/alpha", LastUsed: now}); err != nil {
		t.Fatalf("Add: %v", err)
	}

	if err := r.Save(path); err != nil {
		t.Fatalf("Save: %v", err)
	}

	r2, err := LoadRegistry(path)
	if err != nil {
		t.Fatalf("LoadRegistry: %v", err)
	}
	if len(r2.Projects) != 1 {
		t.Fatalf("expected 1 project, got %d", len(r2.Projects))
	}
	if r2.Projects[0].Name != "alpha" {
		t.Errorf("expected name=alpha, got %q", r2.Projects[0].Name)
	}
	if r2.Projects[0].Path != "/alpha" {
		t.Errorf("expected path=/alpha, got %q", r2.Projects[0].Path)
	}
	if !r2.Projects[0].LastUsed.Equal(now) {
		t.Errorf("expected last_used=%v, got %v", now, r2.Projects[0].LastUsed)
	}
}

func TestLoadRegistry_InvalidTOML_ReturnsError(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "bad.toml")
	if err := os.WriteFile(path, []byte("[[projects\nbroken"), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	_, err := LoadRegistry(path)
	if err == nil {
		t.Fatal("expected error for invalid TOML, got nil")
	}
}
