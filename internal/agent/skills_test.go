package agent

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSkillLoader_EmptyDir(t *testing.T) {
	// Use a path that does not exist — should return empty slice, no error.
	loader := NewSkillLoader(filepath.Join(t.TempDir(), "nonexistent"))
	skills, err := loader.Load()
	if err != nil {
		t.Fatalf("expected no error for missing dir, got: %v", err)
	}
	if len(skills) != 0 {
		t.Fatalf("expected empty slice, got %d skills", len(skills))
	}
}

func TestSkillLoader_Load(t *testing.T) {
	dir := t.TempDir()

	writeFile(t, dir, "zebra.md", "# Zebra\nZebra skill content.")
	writeFile(t, dir, "alpha.md", "# Alpha\nAlpha skill content.")

	loader := NewSkillLoader(dir)
	skills, err := loader.Load()
	if err != nil {
		t.Fatalf("Load() error: %v", err)
	}

	if len(skills) != 2 {
		t.Fatalf("expected 2 skills, got %d", len(skills))
	}

	// Sorted by name: alpha before zebra.
	if skills[0].Name != "alpha" {
		t.Errorf("expected first skill to be %q, got %q", "alpha", skills[0].Name)
	}
	if skills[1].Name != "zebra" {
		t.Errorf("expected second skill to be %q, got %q", "zebra", skills[1].Name)
	}

	if skills[0].Content != "# Alpha\nAlpha skill content." {
		t.Errorf("unexpected content for alpha: %q", skills[0].Content)
	}

	expectedPath := filepath.Join(dir, "alpha.md")
	if skills[0].Path != expectedPath {
		t.Errorf("expected path %q, got %q", expectedPath, skills[0].Path)
	}
}

func TestSkillLoader_Get_Found(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "myskill.md", "# My Skill\nDoes things.")

	loader := NewSkillLoader(dir)
	sk, err := loader.Get("myskill")
	if err != nil {
		t.Fatalf("Get() error: %v", err)
	}

	if sk.Name != "myskill" {
		t.Errorf("expected name %q, got %q", "myskill", sk.Name)
	}
	if sk.Content != "# My Skill\nDoes things." {
		t.Errorf("unexpected content: %q", sk.Content)
	}
}

func TestSkillLoader_Get_NotFound(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "other.md", "# Other")

	loader := NewSkillLoader(dir)
	_, err := loader.Get("nonexistent")
	if err == nil {
		t.Fatal("expected error for nonexistent skill, got nil")
	}
}

// writeFile is a helper that creates a file in dir with the given content.
func writeFile(t *testing.T, dir, name, content string) {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("writeFile(%q): %v", path, err)
	}
}
