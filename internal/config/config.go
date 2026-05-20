// Package config handles DevLoop configuration loading (global + project).
package config

import (
	"bytes"
	"fmt"
	"log"
	"os"

	"github.com/BurntSushi/toml"
)

// Project holds project-level configuration.
type Project struct {
	Name        string `toml:"name"`
	Description string `toml:"description"`
	Stack       string `toml:"stack"`
	Conventions string `toml:"conventions"`
}

// Agents holds agent/backend configuration.
type Agents struct {
	DefaultBackend string            `toml:"default_backend"`
	Backends       map[string]string `toml:"backends"`
}

// Models holds model configuration per agent role.
type Models struct {
	Orchestrator string `toml:"orchestrator"`
	Worker       string `toml:"worker"`
	Reviewer     string `toml:"reviewer"`
}

// Storage holds persistence configuration.
type Storage struct {
	DBPath      string `toml:"db_path"`
	SessionsDir string `toml:"sessions_dir"`
	KeepDays    int    `toml:"keep_days"`
}

// Config is the merged DevLoop configuration (global + project).
type Config struct {
	Project Project `toml:"project"`
	Agents  Agents  `toml:"agents"`
	Models  Models  `toml:"models"`
	Storage Storage `toml:"storage"`
}

// defaults returns a Config pre-filled with sensible built-in defaults.
func defaults() *Config {
	return &Config{
		Project: Project{},
		Agents: Agents{
			DefaultBackend: "claude",
			Backends:       map[string]string{},
		},
		Models: Models{
			Orchestrator: "claude-opus-4-5",
			Worker:       "claude-sonnet-4-5",
			Reviewer:     "claude-sonnet-4-5",
		},
		Storage: Storage{
			DBPath:      "~/.devloop/devloop.db",
			SessionsDir: "~/.devloop/sessions",
			KeepDays:    30,
		},
	}
}

// Load reads globalPath first, then projectPath, merging them so that project
// values win over global values. A missing file is not an error — defaults are
// used instead. Unknown TOML keys are logged as warnings and ignored.
func Load(globalPath, projectPath string) (*Config, error) {
	cfg := defaults()

	for _, path := range []string{globalPath, projectPath} {
		if err := loadFile(cfg, path); err != nil {
			return nil, err
		}
	}

	return cfg, nil
}

// loadFile decodes one TOML file into cfg. A missing file is silently skipped.
// Unknown keys are logged via log.Println.
func loadFile(cfg *Config, path string) error {
	if path == "" {
		return nil
	}

	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("reading config %s: %w", path, err)
	}

	md, decodeErr := toml.Decode(string(data), cfg)
	if decodeErr != nil {
		return fmt.Errorf("parsing config %s: %w", path, decodeErr)
	}

	for _, key := range md.Undecoded() {
		log.Printf("config: unknown key %q in %s (ignored)\n", key, path)
	}

	return nil
}

// Show returns the merged Config serialised as pretty-printed TOML.
func (c *Config) Show() (string, error) {
	var buf bytes.Buffer
	if err := toml.NewEncoder(&buf).Encode(c); err != nil {
		return "", fmt.Errorf("encoding config as TOML: %w", err)
	}
	return buf.String(), nil
}
