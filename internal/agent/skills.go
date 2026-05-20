package agent

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Skill represents a named capability loaded from a markdown file.
type Skill struct {
	Name    string // filename without .md extension
	Content string // full markdown content
	Path    string // absolute file path
}

// SkillLoader loads skills from a directory of .md files.
type SkillLoader struct {
	dir string // e.g. ".devloop/skills"
}

// NewSkillLoader creates a SkillLoader that reads from dir.
func NewSkillLoader(dir string) *SkillLoader {
	return &SkillLoader{dir: dir}
}

// Load reads all *.md files from the skills directory.
// A missing directory is not an error — it returns an empty slice.
// Files are returned sorted by name.
func (s *SkillLoader) Load() ([]Skill, error) {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("read skills dir %q: %w", s.dir, err)
	}

	var skills []Skill
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".md") {
			continue
		}

		absPath := filepath.Join(s.dir, e.Name())
		data, err := os.ReadFile(absPath)
		if err != nil {
			return nil, fmt.Errorf("read skill file %q: %w", absPath, err)
		}

		skills = append(skills, Skill{
			Name:    strings.TrimSuffix(e.Name(), ".md"),
			Content: string(data),
			Path:    absPath,
		})
	}

	sort.Slice(skills, func(i, j int) bool {
		return skills[i].Name < skills[j].Name
	})

	return skills, nil
}

// Get returns a single skill by name (without .md extension).
// Returns an error if the skill is not found.
func (s *SkillLoader) Get(name string) (Skill, error) {
	skills, err := s.Load()
	if err != nil {
		return Skill{}, err
	}

	for _, sk := range skills {
		if sk.Name == name {
			return sk, nil
		}
	}

	return Skill{}, fmt.Errorf("skill %q not found in %q", name, s.dir)
}

// Names returns the names of all available skills (sorted).
func (s *SkillLoader) Names() ([]string, error) {
	skills, err := s.Load()
	if err != nil {
		return nil, err
	}

	names := make([]string, len(skills))
	for i, sk := range skills {
		names[i] = sk.Name
	}

	return names, nil
}
