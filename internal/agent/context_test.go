package agent

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/shaifulshabuj/devloop/internal/config"
)

// TestBuildSystemPromptEmpty verifies that an empty Config does not panic and
// still produces the required header.
func TestBuildSystemPromptEmpty(t *testing.T) {
	cfg := &config.Config{}
	out := BuildSystemPrompt(cfg, "", "")

	if !strings.Contains(out, "# DevLoop Project Context") {
		t.Errorf("expected header '# DevLoop Project Context', got:\n%s", out)
	}
}

// TestBuildSystemPromptFull verifies that project name, stack, and conventions
// all appear in the generated prompt.
func TestBuildSystemPromptFull(t *testing.T) {
	cfg := &config.Config{
		Project: config.Project{
			Name:        "myapp",
			Stack:       "Go",
			Conventions: "use tabs",
		},
	}
	out := BuildSystemPrompt(cfg, "some task", "")

	for _, want := range []string{"myapp", "Go", "use tabs"} {
		if !strings.Contains(out, want) {
			t.Errorf("expected %q in prompt, got:\n%s", want, out)
		}
	}
}

// TestBuildSystemPromptWithSkills verifies that skill filenames are listed when
// the projectDir/skills/ directory contains files.
func TestBuildSystemPromptWithSkills(t *testing.T) {
	dir := t.TempDir()
	skillsDir := filepath.Join(dir, "skills")
	if err := os.MkdirAll(skillsDir, 0o755); err != nil {
		t.Fatalf("creating skills dir: %v", err)
	}

	for _, name := range []string{"alpha.md", "beta.md"} {
		if err := os.WriteFile(filepath.Join(skillsDir, name), []byte("content"), 0o644); err != nil {
			t.Fatalf("writing %s: %v", name, err)
		}
	}

	cfg := &config.Config{}
	out := BuildSystemPrompt(cfg, "", dir)

	for _, want := range []string{"alpha.md", "beta.md"} {
		if !strings.Contains(out, want) {
			t.Errorf("expected skill %q listed in prompt, got:\n%s", want, out)
		}
	}
}

// TestBuildSystemPromptWithLessons verifies that only the last 20 lines of
// lessons.md appear in the prompt when the file has more than 20 lines.
func TestBuildSystemPromptWithLessons(t *testing.T) {
	dir := t.TempDir()

	// Write 25 numbered lines; each is uniquely identifiable via its zero-padded tag.
	var sb strings.Builder
	for i := 1; i <= 25; i++ {
		fmt.Fprintf(&sb, "LESSON:%02d\n", i)
	}
	lessonsPath := filepath.Join(dir, "lessons.md")
	if err := os.WriteFile(lessonsPath, []byte(sb.String()), 0o644); err != nil {
		t.Fatalf("writing lessons.md: %v", err)
	}

	cfg := &config.Config{}
	out := BuildSystemPrompt(cfg, "", dir)

	// Lines 1–5 must NOT appear (only last 20 of 25 lines → lines 6–25).
	for _, absent := range []string{"LESSON:01", "LESSON:02", "LESSON:03", "LESSON:04", "LESSON:05"} {
		if strings.Contains(out, absent) {
			t.Errorf("%q should not appear in prompt (only last 20 lines expected):\n%s", absent, out)
		}
	}

	// Lines 6–25 MUST all appear.
	for i := 6; i <= 25; i++ {
		want := fmt.Sprintf("LESSON:%02d", i)
		if !strings.Contains(out, want) {
			t.Errorf("%q should appear in prompt:\n%s", want, out)
		}
	}
}
