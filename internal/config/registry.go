// Package config handles DevLoop configuration loading (global + project).
package config

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"time"

	"github.com/BurntSushi/toml"
)

// ProjectEntry holds metadata for a registered DevLoop project.
type ProjectEntry struct {
	Name     string    `toml:"name"`
	Path     string    `toml:"path"`
	LastUsed time.Time `toml:"last_used"`
}

// Registry holds all registered DevLoop projects.
type Registry struct {
	Projects []ProjectEntry `toml:"projects"`
}

// LoadRegistry reads the registry at path. If the file is missing it returns
// an empty Registry with no error. Any other read or parse error is returned.
func LoadRegistry(path string) (*Registry, error) {
	r := &Registry{}

	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return r, nil
		}
		return nil, fmt.Errorf("reading registry %s: %w", path, err)
	}

	if _, err := toml.Decode(string(data), r); err != nil {
		return nil, fmt.Errorf("parsing registry %s: %w", path, err)
	}

	return r, nil
}

// Save writes the registry to path as TOML, creating parent directories as
// needed.
func (r *Registry) Save(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("creating registry directory: %w", err)
	}

	f, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("creating registry file %s: %w", path, err)
	}
	defer f.Close() //nolint:errcheck

	if err := toml.NewEncoder(f).Encode(r); err != nil {
		return fmt.Errorf("encoding registry: %w", err)
	}

	return nil
}

// Add inserts entry into the registry. If an entry with the same Path already
// exists, LastUsed is updated (idempotent upsert).
func (r *Registry) Add(entry ProjectEntry) error {
	for i, p := range r.Projects {
		if p.Path == entry.Path {
			r.Projects[i].LastUsed = entry.LastUsed
			if entry.Name != "" {
				r.Projects[i].Name = entry.Name
			}
			return nil
		}
	}
	r.Projects = append(r.Projects, entry)
	return nil
}

// Remove deletes the entry with the given path from the registry. If no entry
// matches, this is a no-op.
func (r *Registry) Remove(path string) error {
	filtered := r.Projects[:0]
	for _, p := range r.Projects {
		if p.Path != path {
			filtered = append(filtered, p)
		}
	}
	r.Projects = filtered
	return nil
}

// List returns all entries sorted by LastUsed descending (most recent first).
func (r *Registry) List() []ProjectEntry {
	out := make([]ProjectEntry, len(r.Projects))
	copy(out, r.Projects)
	sort.Slice(out, func(i, j int) bool {
		return out[i].LastUsed.After(out[j].LastUsed)
	})
	return out
}

// TouchLastUsed updates the LastUsed timestamp for the entry at the given path
// to now. If no entry matches, it is a no-op (no error).
func (r *Registry) TouchLastUsed(path string) error {
	now := time.Now()
	for i, p := range r.Projects {
		if p.Path == path {
			r.Projects[i].LastUsed = now
			return nil
		}
	}
	return nil
}
