package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"text/tabwriter"
	"time"

	"github.com/google/uuid"
	"github.com/shaifulshabuj/devloop/internal/agent"
	"github.com/shaifulshabuj/devloop/internal/config"
	"github.com/shaifulshabuj/devloop/internal/orchestrator"
	"github.com/shaifulshabuj/devloop/internal/storage"
	"github.com/shaifulshabuj/devloop/internal/tui"
	"github.com/spf13/cobra"
)

var version = "v6.0.0-dev"

// Global flags, populated by PersistentPreRunE on the root command.
var (
	globalProject string
	globalBackend string
	globalNoColor bool
)

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

	root.PersistentFlags().StringVar(&globalProject, "project", "", "Path to project directory (defaults to cwd)")
	root.PersistentFlags().StringVar(&globalBackend, "backend", "", "Agent backend to use (claude|copilot|opencode|pi)")
	root.PersistentFlags().BoolVar(&globalNoColor, "no-color", false, "Disable color output")

	root.AddCommand(versionCmd())
	root.AddCommand(configCmd())
	root.AddCommand(contextCmd())
	root.AddCommand(startCmd())
	root.AddCommand(initCmd())
	root.AddCommand(projectsCmd())
	root.AddCommand(runCmd())
	root.AddCommand(statusCmd())
	root.AddCommand(planCmd())
	root.AddCommand(resumeCmd())
	root.AddCommand(resumableCmd())
	root.AddCommand(skillsCmd())
	root.AddCommand(personasCmd())
	root.AddCommand(learnCmd())

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

			projectName := name
			if projectName == "" {
				projectName = filepath.Base(cwd)
			}

			devloopDir := filepath.Join(cwd, ".devloop")
			if err := os.MkdirAll(devloopDir, 0o755); err != nil {
				return fmt.Errorf("creating .devloop directory: %w", err)
			}

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

// openStore resolves the storage DB path from config and opens a Store.
func openStore() (*storage.Store, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, fmt.Errorf("resolving home directory: %w", err)
	}

	globalPath := filepath.Join(home, ".devloop", "config.toml")
	projectPath := filepath.Join(".devloop", "config.toml")

	cfg, err := config.Load(globalPath, projectPath)
	if err != nil {
		return nil, fmt.Errorf("loading config: %w", err)
	}

	dbPath := cfg.Storage.DBPath
	if dbPath == "" {
		dbPath = filepath.Join(home, ".devloop", "devloop.db")
	} else if len(dbPath) >= 2 && dbPath[:2] == "~/" {
		dbPath = filepath.Join(home, dbPath[2:])
	}

	if err := os.MkdirAll(filepath.Dir(dbPath), 0o755); err != nil {
		return nil, fmt.Errorf("creating storage directory: %w", err)
	}

	return storage.Open(dbPath)
}

func runCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "run <task>",
		Short: "Run an agent task non-interactively",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			taskTitle := args[0]

			store, err := openStore()
			if err != nil {
				return fmt.Errorf("opening storage: %w", err)
			}
			defer func() {
				if cerr := store.Close(); cerr != nil {
					fmt.Fprintf(os.Stderr, "warning: closing storage: %v\n", cerr)
				}
			}()

			taskID := uuid.New().String()
			if err := store.CreateTask(taskID, taskTitle); err != nil {
				return fmt.Errorf("creating task: %w", err)
			}

			runner := agent.NewRunner()
			runner.Detect()

			backendID := globalBackend
			if backendID == "" {
				home, _ := os.UserHomeDir()
				cfg, cfgErr := config.Load(
					filepath.Join(home, ".devloop", "config.toml"),
					filepath.Join(".devloop", "config.toml"),
				)
				if cfgErr == nil && cfg.Agents.DefaultBackend != "" {
					backendID = cfg.Agents.DefaultBackend
				}
			}
			if backendID == "" {
				backendID = "claude"
			}

			ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
			defer cancel()

			outputCh := make(chan string, 64)
			go func() {
				for line := range outputCh {
					fmt.Println(line)
				}
			}()

			if err := store.UpdateTaskStatus(taskID, "running"); err != nil {
				return fmt.Errorf("updating task status: %w", err)
			}

			_, spawnErr := runner.Spawn(ctx, backendID, agent.SpawnOpts{
				OutputCh:  outputCh,
				InputText: taskTitle,
			})
			close(outputCh)

			finalStatus := "done"
			if spawnErr != nil {
				finalStatus = "failed"
			}

			if err := store.UpdateTaskStatus(taskID, finalStatus); err != nil {
				fmt.Fprintf(os.Stderr, "warning: updating task status: %v\n", err)
			}

			if spawnErr != nil {
				return fmt.Errorf("agent: %w", spawnErr)
			}

			fmt.Printf("\nTask %s completed.\n", taskID[:8])
			return nil
		},
	}
}

func statusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "List recent DevLoop tasks",
		RunE: func(cmd *cobra.Command, args []string) error {
			store, err := openStore()
			if err != nil {
				return fmt.Errorf("opening storage: %w", err)
			}
			defer func() {
				if cerr := store.Close(); cerr != nil {
					fmt.Fprintf(os.Stderr, "warning: closing storage: %v\n", cerr)
				}
			}()

			tasks, err := store.ListTasks(10)
			if err != nil {
				return fmt.Errorf("listing tasks: %w", err)
			}

			if len(tasks) == 0 {
				fmt.Println("No tasks found. Run `devloop run <task>` to create one.")
				return nil
			}

			w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
			if _, err := fmt.Fprintln(w, "ID\tSTATUS\tCREATED\tTITLE"); err != nil {
				return fmt.Errorf("writing header: %w", err)
			}
			for _, t := range tasks {
				created := time.Unix(t.CreatedAt, 0).Format("2006-01-02 15:04")
				shortID := t.ID
				if len(shortID) > 8 {
					shortID = shortID[:8]
				}
				if _, err := fmt.Fprintf(w, "%s\t%s\t%s\t%s\n", shortID, t.Status, created, t.Title); err != nil {
					return fmt.Errorf("writing row: %w", err)
				}
			}
			return w.Flush()
		},
	}
}

func planCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "plan <task>",
		Short: "Generate an execution plan for a task without running it",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			task := args[0]

			store, err := openStore()
			if err != nil {
				return fmt.Errorf("opening storage: %w", err)
			}
			defer func() {
				if cerr := store.Close(); cerr != nil {
					fmt.Fprintf(os.Stderr, "warning: closing storage: %v\n", cerr)
				}
			}()

			runner := agent.NewRunner()
			runner.Detect()

			orch := orchestrator.New(store, runner)

			ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
			defer cancel()

			plan, err := orch.Plan(ctx, task)
			if err != nil {
				return fmt.Errorf("planning task: %w", err)
			}

			fmt.Printf("Plan: %s\n", plan.Title)
			fmt.Printf("Estimated time: %s\n", plan.EstimatedTime)
			fmt.Printf("Steps (%d):\n", len(plan.Steps))
			for _, s := range plan.Steps {
				fmt.Printf("  %d. %s\n", s.Number, s.Description)
			}
			return nil
		},
	}
}

func resumeCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "resume <task-id>",
		Short: "Resume a pending or failed task by re-running its steps",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			taskID := args[0]

			store, err := openStore()
			if err != nil {
				return fmt.Errorf("opening storage: %w", err)
			}
			defer func() {
				if cerr := store.Close(); cerr != nil {
					fmt.Fprintf(os.Stderr, "warning: closing storage: %v\n", cerr)
				}
			}()

			runner := agent.NewRunner()
			runner.Detect()

			dispatcher := orchestrator.NewDispatcher(store, runner)
			resumer := orchestrator.NewResumer(store, dispatcher)

			ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
			defer cancel()

			result, err := resumer.Resume(ctx, taskID)
			if result != nil {
				for _, sr := range result.Results {
					status := "ok"
					if sr.Error != nil {
						status = "failed"
					}
					fmt.Printf("  Step %d [%s]: %s\n", sr.Step.Number, status, sr.Step.Description)
					if sr.Output != "" {
						fmt.Printf("    %s\n", sr.Output)
					}
				}
			}
			if err != nil {
				return fmt.Errorf("resume: %w", err)
			}
			fmt.Printf("\nTask %s resumed successfully.\n", taskID)
			return nil
		},
	}
}

func resumableCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "resumable",
		Short: "List tasks that can be resumed (pending, running, or failed)",
		RunE: func(cmd *cobra.Command, args []string) error {
			store, err := openStore()
			if err != nil {
				return fmt.Errorf("opening storage: %w", err)
			}
			defer func() {
				if cerr := store.Close(); cerr != nil {
					fmt.Fprintf(os.Stderr, "warning: closing storage: %v\n", cerr)
				}
			}()

			// Dispatcher and runner are not used by Resumable(), but NewResumer
			// requires them to satisfy the interface for Resume().
			runner := agent.NewRunner()
			dispatcher := orchestrator.NewDispatcher(store, runner)
			resumer := orchestrator.NewResumer(store, dispatcher)

			tasks, err := resumer.Resumable()
			if err != nil {
				return fmt.Errorf("listing resumable tasks: %w", err)
			}

			if len(tasks) == 0 {
				fmt.Println("No resumable tasks found.")
				return nil
			}

			w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
			if _, err := fmt.Fprintln(w, "ID\tSTATUS\tTITLE"); err != nil {
				return fmt.Errorf("writing header: %w", err)
			}
			for _, t := range tasks {
				shortID := t.ID
				if len(shortID) > 8 {
					shortID = shortID[:8]
				}
				if _, err := fmt.Fprintf(w, "%s\t%s\t%s\n", shortID, t.Status, t.Title); err != nil {
					return fmt.Errorf("writing row: %w", err)
				}
			}
			return w.Flush()
		},
	}
}

func skillsCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "skills",
		Short: "Manage DevLoop skills",
		RunE: func(cmd *cobra.Command, args []string) error {
			loader := agent.NewSkillLoader(".devloop/skills")
			names, err := loader.Names()
			if err != nil {
				return fmt.Errorf("loading skills: %w", err)
			}
			if len(names) == 0 {
				fmt.Println("No skills found. Add .md files to .devloop/skills/")
				return nil
			}
			for _, name := range names {
				fmt.Println(name)
			}
			return nil
		},
	}
	cmd.AddCommand(skillsShowCmd())
	return cmd
}

func skillsShowCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "show <name>",
		Short: "Show the content of a named skill",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			loader := agent.NewSkillLoader(".devloop/skills")
			skill, err := loader.Get(args[0])
			if err != nil {
				return err
			}
			fmt.Print(skill.Content)
			return nil
		},
	}
}

func personasCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "personas",
		Short: "List registered agent personas",
		RunE: func(cmd *cobra.Command, args []string) error {
			registry := agent.NewPersonaRegistry()
			personas := registry.List()

			w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
			if _, err := fmt.Fprintln(w, "NAME\tDESCRIPTION"); err != nil {
				return fmt.Errorf("writing header: %w", err)
			}
			for _, p := range personas {
				if _, err := fmt.Fprintf(w, "%s\t%s\n", p.Name, p.Description); err != nil {
					return fmt.Errorf("writing row: %w", err)
				}
			}
			return w.Flush()
		},
	}
}

func learnCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "learn <task-id>",
		Short: "Extract lessons from a task's context and append to .devloop/lessons.md",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			taskID := args[0]

			store, err := openStore()
			if err != nil {
				return fmt.Errorf("opening storage: %w", err)
			}
			defer func() {
				if cerr := store.Close(); cerr != nil {
					fmt.Fprintf(os.Stderr, "warning: closing storage: %v\n", cerr)
				}
			}()

			task, err := store.GetTask(taskID)
			if err != nil {
				return fmt.Errorf("getting task %q: %w", taskID, err)
			}

			entries, err := store.GetContext(taskID)
			if err != nil {
				return fmt.Errorf("getting context for task %q: %w", taskID, err)
			}

			inputs := make([]agent.LessonInput, len(entries))
			for i, e := range entries {
				inputs[i] = agent.LessonInput{Output: e.Content}
			}

			loop := agent.NewLearningLoop(".devloop/lessons.md")
			lessons := loop.Extract(task.ID, task.Title, inputs)
			if err := loop.Persist(task.Title, task.ID, lessons); err != nil {
				return fmt.Errorf("persisting lessons: %w", err)
			}

			fmt.Printf("Extracted %d lesson(s) from task %q.\n", len(lessons), task.Title)
			return nil
		},
	}
}
