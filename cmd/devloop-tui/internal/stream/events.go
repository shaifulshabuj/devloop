package stream

import (
	"encoding/json"
	"fmt"
	"time"
)

// Event is a parsed NDJSON event line from the devloop event stream.
// All optional fields are empty string when absent in the JSON payload.
// Raw holds the full decoded map so consumers can access any field not
// yet promoted to a typed field here.
type Event struct {
	TS      time.Time // parsed from "ts" (RFC3339 / ISO-8601 UTC)
	Session string    // "session"
	Kind    string    // "kind"

	// Optional promoted fields — only set when present in JSON.
	Phase        string
	Status       string
	Feature      string
	Gate         string
	Decision     string
	Source       string
	Summary      string
	DetailPath   string
	DetailSize   string
	DecisionFile string
	DurationMs   string

	// Raw holds the full decoded JSON object so consumers can read fields
	// we have not promoted yet. Keys are JSON field names.
	Raw map[string]any
}

// PhaseState represents the content of a <phase>.state helper file.
type PhaseState struct {
	// Status is one of: running, done, failed, approved, needs-work, rejected, skipped.
	Status string
	// Time is the timestamp embedded in the state file (local time).
	Time time.Time
}

// Session is a snapshot of a single devloop session directory.
type Session struct {
	ID          string                // e.g. "TASK-20260516-100000"
	Feature     string                // from feature.txt
	Status      string                // from status file
	StartedAt   time.Time             // from started_at; zero if missing
	FinishedAt  time.Time             // from finished_at; zero if running/missing
	PhaseStates map[string]PhaseState // phase name → state (e.g. "architect", "worker")
	Dir         string                // absolute path to the session directory
}

// ParseEvent decodes one NDJSON line into an Event.
// It returns an error only for malformed JSON or an unparseable "ts" value.
// Unknown "kind" values are silently accepted and round-trip through Raw.
func ParseEvent(line []byte) (Event, error) {
	var raw map[string]any
	if err := json.Unmarshal(line, &raw); err != nil {
		return Event{}, fmt.Errorf("stream.ParseEvent: invalid JSON: %w", err)
	}

	e := Event{Raw: raw}

	// Required: ts
	tsStr := asString(raw, "ts")
	if tsStr != "" {
		t, err := time.Parse(time.RFC3339, tsStr)
		if err != nil {
			return Event{}, fmt.Errorf("stream.ParseEvent: invalid ts %q: %w", tsStr, err)
		}
		e.TS = t
	}

	// Required: kind, session
	e.Kind = asString(raw, "kind")
	e.Session = asString(raw, "session")

	// Optional promoted fields
	e.Phase = asString(raw, "phase")
	e.Status = asString(raw, "status")
	e.Feature = asString(raw, "feature")
	e.Gate = asString(raw, "gate")
	e.Decision = asString(raw, "decision")
	e.Source = asString(raw, "source")
	e.Summary = asString(raw, "summary")
	e.DetailPath = asString(raw, "detail_path")
	e.DetailSize = asString(raw, "detail_size")
	e.DecisionFile = asString(raw, "decision_file")
	e.DurationMs = asString(raw, "duration_ms")

	return e, nil
}

// asString extracts a string value from a decoded JSON map by key.
// It handles both string and numeric JSON values, converting numbers to
// their decimal string representation. Returns "" when the key is absent
// or the value type is not representable as a string.
func asString(m map[string]any, key string) string {
	v, ok := m[key]
	if !ok || v == nil {
		return ""
	}
	switch val := v.(type) {
	case string:
		return val
	case float64:
		// JSON numbers decode as float64; convert to a clean representation.
		// For integer values (e.g. duration_ms: 4231) strip the decimal point.
		if val == float64(int64(val)) {
			return fmt.Sprintf("%d", int64(val))
		}
		return fmt.Sprintf("%g", val)
	case bool:
		if val {
			return "true"
		}
		return "false"
	default:
		return fmt.Sprintf("%v", v)
	}
}
