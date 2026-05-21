package views

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func driveOnboard(t *testing.T, m OnboardModel, msg tea.Msg) OnboardModel {
	t.Helper()
	updated, _ := m.Update(msg)
	mm, ok := updated.(OnboardModel)
	if !ok {
		t.Fatalf("Update returned %T, want OnboardModel", updated)
	}
	return mm
}

func TestOnboard_FormatInitLine(t *testing.T) {
	cases := []struct {
		in       string
		contains string
	}{
		{"✔  Created: devloop.config.sh", "created"},
		{"✔  Updated: CLAUDE.md", "updated"},
		{"Auto-configured: devloop.config.sh (updated 4 values)", "Auto-configured"},
		{"some random progress line", "some random progress line"},
	}
	for _, c := range cases {
		out := formatInitLine(c.in)
		if !strings.Contains(out, c.contains) {
			t.Errorf("formatInitLine(%q) missing %q in %q", c.in, c.contains, out)
		}
	}
}

func TestOnboard_InitToDoctorTransition(t *testing.T) {
	m := NewOnboardWithOptions(t.TempDir(), OnboardOptions{NoSubprocess: true})

	if m.phase != PhaseInit {
		t.Fatalf("expected initial phase PhaseInit, got %v", m.phase)
	}

	// Simulate the init batch arriving (canned in test mode).
	m = driveOnboard(t, m, initBatchMsg{
		lines:    []string{"✔ Created: devloop.config.sh"},
		exitCode: 0,
	})
	// initBatchMsg returns a tea.Cmd that emits initDoneMsg — call it.
	_, cmd := m.Update(initBatchMsg{
		lines:    []string{"✔ Created: devloop.config.sh"},
		exitCode: 0,
	})
	if cmd == nil {
		t.Fatal("expected initBatchMsg to schedule initDoneMsg")
	}
	doneMsg := cmd()
	m = driveOnboard(t, m, doneMsg)

	if m.phase != PhaseDoctor {
		t.Errorf("expected phase PhaseDoctor after init done, got %v", m.phase)
	}
}

func TestOnboard_DoctorToReadyTransition(t *testing.T) {
	m := NewOnboardWithOptions(t.TempDir(), OnboardOptions{NoSubprocess: true})
	m = driveOnboard(t, m, initDoneMsg{exitCode: 0})
	m = driveOnboard(t, m, doctorDoneMsg{
		pass:   2,
		fail:   0,
		checks: []DoctorCheck{{Check: "git installed", Status: "pass"}},
	})

	if m.phase != PhaseDone {
		t.Errorf("expected PhaseDone after doctor, got %v", m.phase)
	}
	m = driveOnboard(t, m, tea.WindowSizeMsg{Width: 100, Height: 30})
	out := stripANSI(m.View())
	if !strings.Contains(out, "READY") {
		t.Errorf("expected READY box, got %q", out)
	}
}

func TestOnboard_DoctorFailShowsWarning(t *testing.T) {
	m := NewOnboardWithOptions(t.TempDir(), OnboardOptions{NoSubprocess: true})
	m = driveOnboard(t, m, initDoneMsg{exitCode: 0})
	m = driveOnboard(t, m, doctorDoneMsg{
		pass: 1,
		fail: 1,
		checks: []DoctorCheck{
			{Check: "git installed", Status: "pass"},
			{Check: "claude installed", Status: "fail", Message: "install hint"},
		},
	})
	m = driveOnboard(t, m, tea.WindowSizeMsg{Width: 100, Height: 30})
	out := stripANSI(m.View())
	if !strings.Contains(out, "failing check") {
		t.Errorf("expected failing-check banner, got %q", out)
	}
	if !strings.Contains(out, "claude installed") {
		t.Errorf("expected failed check row, got %q", out)
	}
}

func TestOnboard_InitFailureSetsError(t *testing.T) {
	m := NewOnboardWithOptions(t.TempDir(), OnboardOptions{NoSubprocess: true})
	m = driveOnboard(t, m, initDoneMsg{exitCode: 2})
	if m.err == nil {
		t.Fatal("expected err to be set on init failure")
	}
	if m.phase == PhaseDoctor {
		t.Errorf("should not transition to doctor on init failure")
	}
}
