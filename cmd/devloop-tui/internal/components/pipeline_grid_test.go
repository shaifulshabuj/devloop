package components

import (
	"strings"
	"testing"
	"time"
)

func TestRender_Empty(t *testing.T) {
	result := Render(nil, GridOptions{})
	if result != "" {
		t.Errorf("expected empty string for nil phases, got %q", result)
	}
	result = Render([]Phase{}, GridOptions{})
	if result != "" {
		t.Errorf("expected empty string for empty phases, got %q", result)
	}
}

func TestRender_AllStates(t *testing.T) {
	phases := []Phase{
		{Name: "architect", Status: PhasePending},
		{Name: "worker", Status: PhaseRunning},
		{Name: "reviewer", Status: PhaseDone},
		{Name: "fix-1", Status: PhaseFailed},
		{Name: "fix-2", Status: PhaseSkipped},
	}
	result := Render(phases, GridOptions{SpinnerTick: 0})

	// Glyph checks (the styled output still contains these rune literals)
	for _, glyph := range []string{"·", "✓", "✗", "→"} {
		if !strings.Contains(result, glyph) {
			t.Errorf("expected glyph %q in output:\n%s", glyph, result)
		}
	}

	// Running phase must contain at least one braille spinner char
	hasSpinner := false
	for _, frame := range spinnerFrames {
		if strings.Contains(result, frame) {
			hasSpinner = true
			break
		}
	}
	if !hasSpinner {
		t.Errorf("expected a braille spinner char for PhaseRunning, got:\n%s", result)
	}
	// Color: under `go test`, stdout isn't a TTY and Lipgloss correctly strips
	// ANSI codes — asserting on \x1b[ is brittle and tells us nothing useful.
	// The glyph checks above are the meaningful semantic assertion.
}

func TestRender_Compact(t *testing.T) {
	phases := []Phase{
		{Name: "architect", Status: PhaseDone},
		{Name: "worker", Status: PhaseRunning},
		{Name: "reviewer", Status: PhasePending},
	}
	result := Render(phases, GridOptions{Compact: true, SpinnerTick: 2})

	// Compact must produce a single logical line (no embedded newline)
	if strings.Contains(result, "\n") {
		t.Errorf("compact render must not contain newlines, got:\n%s", result)
	}
}

func TestRender_Spinner(t *testing.T) {
	phase := []Phase{{Name: "worker", Status: PhaseRunning}}

	frames := make([]string, 3)
	for i := 0; i < 3; i++ {
		frames[i] = Render(phase, GridOptions{SpinnerTick: i})
	}

	if frames[0] == frames[1] || frames[1] == frames[2] || frames[0] == frames[2] {
		t.Errorf("expected different braille chars for SpinnerTick 0,1,2; got %q %q %q",
			frames[0], frames[1], frames[2])
	}
}

func TestRender_Duration(t *testing.T) {
	tests := []struct {
		dur      time.Duration
		contains string
	}{
		{4231 * time.Millisecond, "4s"},
		{65 * time.Second, "1m 5s"},
		{3725 * time.Second, "1h 2m"}, // 62m 5s → 1h 2m
	}
	for _, tc := range tests {
		phase := []Phase{{Name: "worker", Status: PhaseDone, Duration: tc.dur}}
		result := Render(phase, GridOptions{})
		if !strings.Contains(result, tc.contains) {
			t.Errorf("duration %v: expected %q in output, got:\n%s", tc.dur, tc.contains, result)
		}
	}
}
