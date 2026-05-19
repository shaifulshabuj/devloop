// Package git provides git integration utilities.
package git

import (
	"errors"
	"fmt"
	"os/exec"
	"strings"
)

// Client wraps git operations for a repository directory.
type Client struct {
	repoDir string
}

// NewClient creates a new Client rooted at repoDir.
func NewClient(repoDir string) *Client {
	return &Client{repoDir: repoDir}
}

// HasChanges returns true if there are staged or unstaged changes in repoDir.
// Runs: git status --porcelain
func (c *Client) HasChanges() (bool, error) {
	out, err := c.run("status", "--porcelain")
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(out) != "", nil
}

// StageAll stages all changed files.
// Runs: git add -A
func (c *Client) StageAll() error {
	_, err := c.run("add", "-A")
	return err
}

// Commit creates a commit with the given message.
// Runs: git commit -m <message>
func (c *Client) Commit(message string) error {
	_, err := c.run("commit", "-m", message)
	return err
}

// AutoCommit stages all changes and commits with a generated message.
// Generated message format: "devloop: <taskTitle> [auto]"
// Only commits if HasChanges returns true; returns nil if nothing to commit.
func (c *Client) AutoCommit(taskTitle string) error {
	ok, err := c.HasChanges()
	if err != nil {
		return fmt.Errorf("git auto-commit: checking for changes: %w", err)
	}
	if !ok {
		return nil
	}
	if err := c.StageAll(); err != nil {
		return fmt.Errorf("git auto-commit: staging files: %w", err)
	}
	msg := fmt.Sprintf("devloop: %s [auto]", taskTitle)
	if err := c.Commit(msg); err != nil {
		return fmt.Errorf("git auto-commit: committing: %w", err)
	}
	return nil
}

// Diff returns the output of `git diff --stat HEAD` (summary of changes).
// Returns empty string if no changes.
func (c *Client) Diff() (string, error) {
	out, err := c.run("diff", "--stat", "HEAD")
	if err != nil {
		return "", err
	}
	return out, nil
}

// run executes a git subcommand in c.repoDir and returns combined stdout.
func (c *Client) run(args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = c.repoDir
	out, err := cmd.Output()
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return "", fmt.Errorf("git %s: exit %d: %s",
				strings.Join(args, " "), exitErr.ExitCode(), string(exitErr.Stderr))
		}
		return "", fmt.Errorf("git %s: %w", strings.Join(args, " "), err)
	}
	return string(out), nil
}
