// Package permit reads the on-disk permission queue written by
// devloop.sh's permit gate. Each pending request is a UUID-named JSON file
// at .devloop/permission-queue/<UUID>.json; once resolved a sibling
// <UUID>.response file appears containing "allow" or "deny".
//
// IMPORTANT (spec correction): the redesign brief originally said the
// filename IS the command. That's wrong — UUIDs can't represent commands
// that contain '/' or spaces. The command lives in the JSON body's
// "command" field. Verified against devloop.sh during preflight (PF-6).
package permit

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Dir is the on-disk queue directory relative to the project root.
const Dir = ".devloop/permission-queue"

// Item is one pending permission request.
type Item struct {
	ID          string    // UUID — filename without .json suffix
	Command     string    // from JSON body
	Tool        string    // from JSON body (e.g. "Bash")
	RequestedAt time.Time // parsed from JSON "ts" field; zero on parse failure
}

// rawRequest mirrors the JSON shape written by devloop.sh's permit hook.
// Additional fields are ignored — extensible by design.
type rawRequest struct {
	Command string `json:"command"`
	Tool    string `json:"tool"`
	TS      string `json:"ts"`
}

// Read returns all currently-pending permission requests in the project's
// queue directory. An entry is considered pending when there's no matching
// .response sibling. Missing directory → empty slice (not an error).
// Malformed JSON files are skipped silently — never break the UI just
// because one file is half-written by the gate writer.
func Read(projectRoot string) ([]Item, error) {
	dir := filepath.Join(projectRoot, Dir)
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}

	// Build a set of resolved IDs so we can skip them.
	resolved := map[string]bool{}
	for _, e := range entries {
		name := e.Name()
		if strings.HasSuffix(name, ".response") {
			resolved[strings.TrimSuffix(name, ".response")] = true
		}
	}

	var items []Item
	for _, e := range entries {
		name := e.Name()
		if !strings.HasSuffix(name, ".json") {
			continue
		}
		id := strings.TrimSuffix(name, ".json")
		if resolved[id] {
			continue
		}
		path := filepath.Join(dir, name)
		b, err := os.ReadFile(path)
		if err != nil {
			continue // race: file vanished mid-scan
		}
		var raw rawRequest
		if err := json.Unmarshal(b, &raw); err != nil {
			continue // malformed; skip silently
		}
		ts := parseTimestamp(raw.TS)
		items = append(items, Item{
			ID:          id,
			Command:     raw.Command,
			Tool:        raw.Tool,
			RequestedAt: ts,
		})
	}

	// Stable sort: oldest first (which is what the UI shows top→bottom).
	// Items without parseable timestamps sort last so they don't push
	// real requests around.
	sort.SliceStable(items, func(i, j int) bool {
		ti := items[i].RequestedAt
		tj := items[j].RequestedAt
		if ti.IsZero() && tj.IsZero() {
			return items[i].ID < items[j].ID
		}
		if ti.IsZero() {
			return false
		}
		if tj.IsZero() {
			return true
		}
		return ti.Before(tj)
	})

	return items, nil
}

// Count is a convenience for the top-bar indicator: returns the number of
// pending items, treating any error as 0.
func Count(projectRoot string) int {
	items, err := Read(projectRoot)
	if err != nil {
		return 0
	}
	return len(items)
}

// ShortID returns the first 7 characters of an item's ID, suitable for
// rendering in narrow UI cells.
func (i Item) ShortID() string {
	if len(i.ID) <= 7 {
		return i.ID
	}
	return i.ID[:7]
}

// RelativeTime returns a human-readable "Ns ago" / "Nm ago" string.
// Empty timestamp returns "just now".
func (i Item) RelativeTime(now time.Time) string {
	if i.RequestedAt.IsZero() {
		return "just now"
	}
	d := now.Sub(i.RequestedAt)
	switch {
	case d < time.Second:
		return "just now"
	case d < time.Minute:
		return formatInt(int(d.Seconds())) + "s ago"
	case d < time.Hour:
		return formatInt(int(d.Minutes())) + "m ago"
	default:
		return formatInt(int(d.Hours())) + "h ago"
	}
}

func formatInt(n int) string {
	if n < 0 {
		n = 0
	}
	const digits = "0123456789"
	if n < 10 {
		return string(digits[n])
	}
	// Tiny base-10 itoa to avoid pulling fmt/strconv in this hot path.
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = digits[n%10]
		n /= 10
	}
	return string(buf[i:])
}

// parseTimestamp accepts a few formats devloop.sh might emit: RFC3339,
// Unix seconds as a string, or ISO-8601 in UTC.
func parseTimestamp(s string) time.Time {
	s = strings.TrimSpace(s)
	if s == "" {
		return time.Time{}
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t
	}
	if t, err := time.Parse("2006-01-02T15:04:05Z", s); err == nil {
		return t
	}
	return time.Time{}
}
