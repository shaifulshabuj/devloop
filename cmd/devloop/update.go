package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/spf13/cobra"
)

const (
	githubRepo    = "shaifulshabuj/devloop"
	githubAPIBase = "https://api.github.com/repos/" + githubRepo
	installScript = "https://raw.githubusercontent.com/" + githubRepo + "/main/install.sh"
)

// githubRelease is the subset of fields we need from the GitHub releases API.
type githubRelease struct {
	TagName     string    `json:"tag_name"`
	PublishedAt time.Time `json:"published_at"`
	HTMLURL     string    `json:"html_url"`
	Body        string    `json:"body"`
}

// fetchLatestRelease calls the GitHub releases API and returns the latest release.
func fetchLatestRelease() (*githubRelease, error) {
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Get(githubAPIBase + "/releases/latest")
	if err != nil {
		return nil, fmt.Errorf("HTTP request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GitHub API returned status %d", resp.StatusCode)
	}

	var rel githubRelease
	if err := json.NewDecoder(resp.Body).Decode(&rel); err != nil {
		return nil, fmt.Errorf("decode response: %w", err)
	}
	return &rel, nil
}

// normalizeTag strips a leading "v" for semver comparison, or returns the tag as-is.
func normalizeTag(t string) string {
	return strings.TrimPrefix(t, "v")
}

// isNewer returns true when remote is a higher semver than local.
// Falls back to string comparison when parsing fails.
func isNewer(local, remote string) bool {
	l := normalizeTag(local)
	r := normalizeTag(remote)
	// Simple lexicographic comparison works for canonical semver strings.
	return r > l
}

// backgroundVersionHint performs a version check at most once per 24 hours and
// prints a one-line notice to stderr when an update is available. It is
// designed to be run in a goroutine and never blocks the main command.
func backgroundVersionHint() {
	stampFile := filepath.Join(os.TempDir(), "devloop-version-check.stamp")

	// Skip if we already checked within the last 24 hours.
	if fi, err := os.Stat(stampFile); err == nil {
		if time.Since(fi.ModTime()) < 24*time.Hour {
			return
		}
	}

	rel, err := fetchLatestRelease()
	if err != nil {
		return // silently ignore network errors
	}

	// Touch the stamp file regardless of whether an update is found.
	_ = os.WriteFile(stampFile, []byte(rel.TagName), 0600)

	if isNewer(version, rel.TagName) {
		fmt.Fprintf(os.Stderr, "\n  💡 devloop %s is available (you have %s) — run: devloop update\n\n",
			rel.TagName, version)
	}
}

func checkCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "check",
		Short: "Check for a newer version of devloop",
		Long: `Queries the GitHub releases API and compares the latest published tag
against the running binary's version. Prints a one-line status and exits 0.`,
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Printf("  Local:  %s\n", version)
			fmt.Printf("  Source: https://github.com/%s/releases\n\n", githubRepo)

			rel, err := fetchLatestRelease()
			if err != nil {
				return fmt.Errorf("could not reach GitHub: %w", err)
			}

			fmt.Printf("  Latest: %s (published %s)\n\n", rel.TagName, rel.PublishedAt.Format("2006-01-02"))

			if isNewer(version, rel.TagName) {
				fmt.Printf("  ✨ Update available: %s → %s\n", version, rel.TagName)
				fmt.Printf("     Run: devloop update\n")
				fmt.Printf("     Or:  %s\n", installScript)
			} else {
				fmt.Printf("  ✅ Up to date — %s\n", version)
			}
			return nil
		},
	}
}

// updateCmd returns the `devloop update` cobra command.
func updateCmd() *cobra.Command {
	var installDir string
	cmd := &cobra.Command{
		Use:   "update",
		Short: "Upgrade devloop to the latest release",
		Long: `Downloads and runs the official install.sh script from GitHub to upgrade
the devloop binary to the latest published release.

The installer detects your platform (darwin/linux, amd64/arm64), downloads
the correct binary, verifies its SHA-256 checksum, and installs it.

By default it installs to /usr/local/bin (may require sudo). Use
--install-dir to choose a different directory (e.g. ~/.local/bin).`,
		RunE: func(cmd *cobra.Command, args []string) error {
			// 1. Check what version is available
			fmt.Printf("  Current version: %s\n", version)

			rel, err := fetchLatestRelease()
			if err != nil {
				fmt.Fprintf(os.Stderr, "  ⚠ Could not reach GitHub (%v) — attempting upgrade anyway\n", err)
			} else {
				fmt.Printf("  Latest version:  %s\n\n", rel.TagName)
				if !isNewer(version, rel.TagName) {
					fmt.Printf("  ✅ Already up to date — %s\n", version)
					return nil
				}
				fmt.Printf("  ✨ Upgrading %s → %s\n\n", version, rel.TagName)
			}

			// 2. Download install.sh to a temp file
			client := &http.Client{Timeout: 30 * time.Second}
			resp, err := client.Get(installScript)
			if err != nil {
				return fmt.Errorf("download install.sh: %w", err)
			}
			defer resp.Body.Close()

			tmp, err := os.CreateTemp("", "devloop-install-*.sh")
			if err != nil {
				return fmt.Errorf("create temp file: %w", err)
			}
			defer os.Remove(tmp.Name())

			if _, err := io.Copy(tmp, resp.Body); err != nil {
				return fmt.Errorf("write install.sh: %w", err)
			}
			tmp.Close()

			if err := os.Chmod(tmp.Name(), 0700); err != nil {
				return fmt.Errorf("chmod install.sh: %w", err)
			}

			// 3. Build bash args for the installer
			bashArgs := []string{tmp.Name()}
			if installDir != "" {
				bashArgs = append(bashArgs, "--install-dir", installDir)
			}

			// 4. Run install.sh
			shell := "bash"
			if runtime.GOOS == "windows" {
				return fmt.Errorf("self-update is not supported on Windows — download manually from:\n  https://github.com/%s/releases/latest", githubRepo)
			}
			if p, err := exec.LookPath("bash"); err == nil {
				shell = p
			}

			//nolint:gosec // intentional subprocess invocation of downloaded install script
			installer := exec.Command(shell, bashArgs...)
			installer.Stdout = os.Stdout
			installer.Stderr = os.Stderr
			installer.Stdin = os.Stdin

			if err := installer.Run(); err != nil {
				return fmt.Errorf("installer failed: %w", err)
			}

			// 5. Print the path of the newly installed binary
			self, _ := os.Executable()
			if self != "" {
				self, _ = filepath.EvalSymlinks(self)
			}
			fmt.Printf("\n  ✅ devloop updated — restart your shell or run: %s version\n", self)
			return nil
		},
	}
	cmd.Flags().StringVar(&installDir, "install-dir", "", "Directory to install the binary into (default: /usr/local/bin)")
	return cmd
}
