package main

import (
	"fmt"
	"os"
	"path/filepath"
	"text/tabwriter"
	"time"

	"github.com/shaifulshabuj/devloop/internal/agent"
	"github.com/shaifulshabuj/devloop/internal/config"
	"github.com/shaifulshabuj/devloop/internal/tui"
	"github.com/spf13/cobra"
)

var version = "v6.0.0-dev"

func main() {
	root := &cobra.Command{
		Use:     "devloop",
		Short:   "DevLoop — AI development platform",
		Long:    "DevLoop v6: a standalone AI development platform with interactive agent sessions.",
		Version: version,
		RunE: func(cmd *cobra.Command, args []string) error {
			return cmd.Help()
		},
	}

	root.AddCommand(versionCmd())
	root.AddCommand(configCmd())
	root.AddCommand(contextCmd())
	root.AddCommand(startCmd())
	root.AddCommand(initCmd())
	root.AddCommand(projectsCmd())

	if err := root.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func versionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print devloop version",
		Run: func(cmd *cobra.Command, args []string) {
			fmt.Printf("devloop %s\n", version)
		},
	}
}

func configCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "config",
		Short: "Manage devloop configuration",
		RunE: func(cmd *cobra.Command, args []string) error {
			return cmd.Help()
		},
	}

	cmd.AddCommand(configShowCmd())
	return cmd
}

func configShowCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "show",
		Short: "Dump merged (global + project) config as TOML",
		RunE: func(cmd *cobra.Command, args []string) error {
			home, err := os.UserHomeDir()
			if err != nil {
				return fmt.Errorf("resolving home directory: %w", err)
			}

			globalPath := filepath.Join(home, ".devloop", "config.toml")
			projectPath := filepath.Join(".devloop", "config.toml")

			cfg, err := config.Load(globalPath, projectPath)
			if err != nil {
				return fmt.Errorf("loading config: %w", err)
			}

			out, err := cfg.Show()
			if err != nil {
				return fmt.Errorf("serialising config: %w", err)
			}

			fmt.Print(out)
			return nil
		},
	}
}

func contextCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "context",
		Short: "Manage DevLoop agent context",
		RunE: func(cmd *cobra.Command, args []string) error {
			return cmd.Help()
		},
	}

	cmd.AddCommand(contextShowCmd())
	return cmd
}

func contextShowCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "show",
		Short: "Print the system prompt that would be injected at agent startup",
		RunE: func(cmd *cobra.Command, args []string) error {
			home, err := os.UserHomeDir()
			if err != nil {
				return fmt.Errorf("resolving home directory: %w", err)
			}

			globalPath := filepath.Join(home, ".devloop", "config.toml")
			projectPath := filepath.Join(".devloop", "config.toml")

			cfg, err := config.Load(globalPath, projectPath)
			if err != nil {
				return fmt.Errorf("loading config: %w", err)
			}

			prompt := agent.BuildSystemPrompt(cfg, "", ".devloop")
			fmt.Print(prompt)
			return nil
		},
	}
}

func startCmd() *cobra.Command {
	var noTUI bool

	cmd := &cobra.Command{
		Use:   "start",
		Short: "Start DevLoop (launches the interactive TUI by default)",
		RunE: func(cmd *cobra.Command, args []string) error {
			if noTUI {
				fmt.Println("DevLoop v6 started (no TUI)")
				return nil
			}
			// Use the current directory name as the project name for Phase 1.
			cwd, err := os.Getwd()
			if err != nil {
				cwd = "."
			}
			projectName := filepath.Base(cwd)
			return tui.Run(projectName)
		},
	}

	cmd.Flags().BoolVar(&noTUI, "no-tui", false, "Run in non-interactive mode without the TUI")
	return cmd
}

// registryPath returns the default path to the global projects registry.
func registryPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolving home directory: %w", err)
	}
	return filepath.Join(home, ".devloop", "projects.toml"), nil
}

func initCmd() *cobra.Command {
	var name string

	cmd := &cobra.Command{
		Use:   "init",
		Short: "Initialise a DevLoop project in the current directory",
		RunE: func(cmd *cobra.Command, args []string) error {
			cwd, err := os.Getwd()
			if err != nil {
				return fmt.Errorf("resolving current directory: %w", err)
			}

			// Derive project name from flag or directory name.
			projectName := name
			if projectName == "" {
				projectName = filepath.Base(cwd)
			}

			// Create .devloop/ directory.
			devloopDir := filepath.Join(cwd, ".devloop")
			if err := os.MkdirAll(devloopDir, 0o755); err != nil {
				return fmt.Errorf("creating .devloop directory: %w", err)
			}

			// Write .devloop/config.toml with sensible defaults.
			cfgPath := filepath.Join(devloopDir, "config.toml")
			cfgContent := fmt.Sprintf(`[project]
name = %q
description = ""
stack = ""
conventions = ""

[agents]
default_backend = "claude"

[models]
orchestrator = "claude-opus-4-5"
worker = "claude-sonnet-4-5"
reviewer = "claude-sonnet-4-5"

[storage]
db_path = "~/.devloop/devloop.db"
sessions_dir = "~/.devloop/sessions"
keep_days = 30
`, projectName)

			if err := os.WriteFile(cfgPath, []byte(cfgContent), 0o644); err != nil {
				return fmt.Errorf("writing config.toml: %w", err)
			}

			// Register project in the global registry (idempotent).
			regPath, err := registryPath()
			if err != nil {
				return err
			}
			reg, err := config.LoadRegistry(regPath)
			if err != nil {
				return fmt.Errorf("loading registry: %w", err)
			}
			if err := reg.Add(config.ProjectEntry{
				Name:     projectName,
				Path:     cwd,
				LastUsed: time.Now(),
			}); err != nil {
				return fmt.Errorf("adding project to registry: %w", err)
			}
			if err := reg.Save(regPath); err != nil {
				return fmt.Errorf("saving registry: %w", err)
			}

			fmt.Printf("Initialized DevLoop project: %s\n", projectName)
			return nil
		},
	}

	cmd.Flags().StringVar(&name, "name", "", "Project name (defaults to current directory name)")
	return cmd
}

func projectsCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "projects",
		Short: "List all registered DevLoop projects",
		RunE: func(cmd *cobra.Command, args []string) error {
			regPath, err := registryPath()
			if err != nil {
				return err
			}

			reg, err := config.LoadRegistry(regPath)
			if err != nil {
				return fmt.Errorf("loading registry: %w", err)
			}

			list := reg.List()
			if len(list) == 0 {
				fmt.Println("No projects registered. Run `devloop init` in a project directory.")
				return nil
			}

			w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
			if _, err := fmt.Fprintln(w, "NAME\tPATH\tLAST USED"); err != nil {
				return fmt.Errorf("writing header: %w", err)
			}
			for _, p := range list {
				lastUsed := p.LastUsed.Format("2006-01-02 15:04:05")
				if p.LastUsed.IsZero() {
					lastUsed = "never"
				}
				if _, err := fmt.Fprintf(w, "%s\t%s\t%s\n", p.Name, p.Path, lastUsed); err != nil {
					return fmt.Errorf("writing row: %w", err)
				}
			}
			return w.Flush()
		},
	}
}
