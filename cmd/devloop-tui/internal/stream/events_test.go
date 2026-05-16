package stream

import (
	"testing"
	"time"
)

func TestParseEvent_KnownKinds(t *testing.T) {
	t.Run("session.start", func(t *testing.T) {
		line := []byte(`{"ts":"2026-05-16T14:32:11Z","session":"TASK-20260516-143211","kind":"session.start","feature":"add dark mode toggle"}`)
		ev, err := ParseEvent(line)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		want := time.Date(2026, 5, 16, 14, 32, 11, 0, time.UTC)
		if !ev.TS.Equal(want) {
			t.Errorf("TS = %v, want %v", ev.TS, want)
		}
		if ev.Session != "TASK-20260516-143211" {
			t.Errorf("Session = %q, want TASK-20260516-143211", ev.Session)
		}
		if ev.Kind != "session.start" {
			t.Errorf("Kind = %q, want session.start", ev.Kind)
		}
		if ev.Feature != "add dark mode toggle" {
			t.Errorf("Feature = %q, want 'add dark mode toggle'", ev.Feature)
		}
		// Raw must also contain the fields.
		if ev.Raw["kind"] != "session.start" {
			t.Errorf("Raw[kind] = %v", ev.Raw["kind"])
		}
		if ev.Raw["feature"] != "add dark mode toggle" {
			t.Errorf("Raw[feature] = %v", ev.Raw["feature"])
		}
	})

	t.Run("phase.end with duration_ms as string", func(t *testing.T) {
		line := []byte(`{"ts":"2026-05-16T14:33:00Z","session":"TASK-1","kind":"phase.end","phase":"worker","status":"done","duration_ms":"4231"}`)
		ev, err := ParseEvent(line)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if ev.Kind != "phase.end" {
			t.Errorf("Kind = %q", ev.Kind)
		}
		if ev.Phase != "worker" {
			t.Errorf("Phase = %q, want worker", ev.Phase)
		}
		if ev.Status != "done" {
			t.Errorf("Status = %q, want done", ev.Status)
		}
		if ev.DurationMs != "4231" {
			t.Errorf("DurationMs = %q, want 4231", ev.DurationMs)
		}
	})

	t.Run("phase.end with duration_ms as number", func(t *testing.T) {
		line := []byte(`{"ts":"2026-05-16T14:33:00Z","session":"TASK-1","kind":"phase.end","phase":"architect","status":"done","duration_ms":4231}`)
		ev, err := ParseEvent(line)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if ev.DurationMs != "4231" {
			t.Errorf("DurationMs = %q, want 4231 (from number)", ev.DurationMs)
		}
	})

	t.Run("approval.request", func(t *testing.T) {
		line := []byte(`{"ts":"2026-05-16T14:34:00Z","session":"TASK-2","kind":"approval.request","gate":"plan","summary":"Add dark mode","detail_path":".devloop/specs/TASK-2.md","detail_size":"3942","decision_file":".devloop/sessions/TASK-2/approvals/plan.json"}`)
		ev, err := ParseEvent(line)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if ev.Kind != "approval.request" {
			t.Errorf("Kind = %q", ev.Kind)
		}
		if ev.Gate != "plan" {
			t.Errorf("Gate = %q, want plan", ev.Gate)
		}
		if ev.Summary != "Add dark mode" {
			t.Errorf("Summary = %q", ev.Summary)
		}
		if ev.DetailPath != ".devloop/specs/TASK-2.md" {
			t.Errorf("DetailPath = %q", ev.DetailPath)
		}
		if ev.DetailSize != "3942" {
			t.Errorf("DetailSize = %q", ev.DetailSize)
		}
		if ev.DecisionFile != ".devloop/sessions/TASK-2/approvals/plan.json" {
			t.Errorf("DecisionFile = %q", ev.DecisionFile)
		}
	})

	t.Run("approval.decision", func(t *testing.T) {
		line := []byte(`{"ts":"2026-05-16T14:35:00Z","session":"TASK-2","kind":"approval.decision","gate":"plan","decision":"approve","source":"gum"}`)
		ev, err := ParseEvent(line)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if ev.Kind != "approval.decision" {
			t.Errorf("Kind = %q", ev.Kind)
		}
		if ev.Decision != "approve" {
			t.Errorf("Decision = %q, want approve", ev.Decision)
		}
		if ev.Source != "gum" {
			t.Errorf("Source = %q, want gum", ev.Source)
		}
	})
}

func TestParseEvent_UnknownKind(t *testing.T) {
	line := []byte(`{"ts":"2026-05-16T14:36:00Z","session":"TASK-X","kind":"weird.thing","extra":42}`)
	ev, err := ParseEvent(line)
	if err != nil {
		t.Fatalf("unknown kind must not error, got: %v", err)
	}
	if ev.Kind != "weird.thing" {
		t.Errorf("Kind = %q, want weird.thing", ev.Kind)
	}
	// Raw should contain the unpromoted extra field.
	extra, ok := ev.Raw["extra"]
	if !ok {
		t.Fatal("Raw missing 'extra' field")
	}
	// JSON numbers decode as float64.
	if extra.(float64) != 42 {
		t.Errorf("Raw[extra] = %v, want 42", extra)
	}
}

func TestParseEvent_Malformed(t *testing.T) {
	_, err := ParseEvent([]byte(`{garbage`))
	if err == nil {
		t.Fatal("expected error for malformed JSON, got nil")
	}
}
