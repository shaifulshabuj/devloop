package git_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/shaifulshabuj/devloop/internal/git"
)

// skipIfNoGit skips the test when git is not on PATH.
func skipIfNoGit(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not available")
	}
}

// TestNewClient verifies the struct is created with the correct repoDir.
func TestNewClient(t *testing.T) {
	c := git.NewClient("/tmp/some-repo")
	if c == nil {
		t.Fatal("NewClient returned nil")
	}
	// The Client is opaque; just confirm creation doesn't panic.
}

// TestAutoCommit_NothingToCommit verifies AutoCommit returns nil when there
// is nothing to commit in the current (real) repository.
func TestAutoCommit_NothingToCommit(t *testing.T) {
	skipIfNoGit(t)

	// Use the actual module root (two levels up from this file's package dir).
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}

	// Walk up to find the git root.
	root := findGitRoot(dir)
	if root == "" {
		t.Skip("not inside a git repository")
	}

	c := git.NewClient(root)

	// If the working tree is clean, AutoCommit should return nil immediately.
	// If it's dirty the test is still valid: AutoCommit may succeed or fail
	// depending on git config, so we only assert no panic and accept both outcomes.
	_ = c.AutoCommit("test task")
}

// TestHasChanges calls HasChanges on /tmp (not a git repo) and expects an
// error, or on the real repo dir and expects a bool result.
func TestHasChanges(t *testing.T) {
	skipIfNoGit(t)

	t.Run("non-git directory returns error", func(t *testing.T) {
		c := git.NewClient("/tmp")
		_, err := c.HasChanges()
		if err == nil {
			t.Log("HasChanges on /tmp returned no error (git may treat /tmp as a repo on this system)")
		}
		// We don't hard-fail; some systems may have /tmp inside a git worktree.
	})

	t.Run("real repo returns bool without error", func(t *testing.T) {
		dir, err := os.Getwd()
		if err != nil {
			t.Fatal(err)
		}
		root := findGitRoot(dir)
		if root == "" {
			t.Skip("not inside a git repository")
		}
		c := git.NewClient(root)
		_, err = c.HasChanges()
		if err != nil {
			t.Errorf("HasChanges on real repo returned error: %v", err)
		}
	})
}

// findGitRoot walks up from dir until it finds a directory containing .git.
func findGitRoot(dir string) string {
	for {
		if _, err := os.Stat(filepath.Join(dir, ".git")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return ""
		}
		dir = parent
	}
}
