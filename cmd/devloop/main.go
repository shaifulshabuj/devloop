package main

import (
	"fmt"
	"os"
	"path/filepath"

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
	root.AddCommand(startCmd())

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
