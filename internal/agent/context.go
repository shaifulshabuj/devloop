// Package agent provides subprocess management and context injection for DevLoop agents.
package agent

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"

	"github.com/shaifulshabuj/devloop/internal/config"
)

// BuildSystemPrompt constructs the system prompt to inject at agent startup.
// projectDir is the .devloop directory root (where skills/ and lessons.md live).
// Missing projectDir, skills directory, or lessons.md are silently ignored.
func BuildSystemPrompt(cfg *config.Config, taskTitle, projectDir string) string {
	var sb strings.Builder

	sb.WriteString("# DevLoop Project Context\n\n")

	sb.WriteString("**Project:** ")
	sb.WriteString(cfg.Project.Name)
	sb.WriteString("\n")

	sb.WriteString("**Stack:** ")
	sb.WriteString(cfg.Project.Stack)
	sb.WriteString("\n")

	if cfg.Project.Conventions != "" {
		sb.WriteString("\n## Conventions\n")
		sb.WriteString(cfg.Project.Conventions)
		sb.WriteString("\n")
	}

	if projectDir != "" {
		skillsDir := filepath.Join(projectDir, "skills")
		entries, err := os.ReadDir(skillsDir)
		if err == nil && len(entries) > 0 {
			sb.WriteString("\n## Active Skills\n")
			for _, e := range entries {
				if !e.IsDir() {
					sb.WriteString("- ")
					sb.WriteString(e.Name())
					sb.WriteString("\n")
				}
			}
		}

		lessonsPath := filepath.Join(projectDir, "lessons.md")
		if lines := lastNLines(lessonsPath, 20); len(lines) > 0 {
			sb.WriteString("\n## Recent Lessons\n")
			for _, l := range lines {
				sb.WriteString(l)
				sb.WriteString("\n")
			}
		}
	}

	return sb.String()
}

// lastNLines reads up to n trailing lines from the file at path.
// Returns nil if the file does not exist or cannot be read.
func lastNLines(path string, n int) []string {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close() //nolint:errcheck

	var lines []string
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		lines = append(lines, scanner.Text())
	}

	if len(lines) <= n {
		return lines
	}
	return lines[len(lines)-n:]
}
