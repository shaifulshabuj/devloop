package stream

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// localTimeFmt is the format used by the bash engine for started_at /
// finished_at and the timestamp embedded in *.state files.
const localTimeFmt = "2006-01-02T15:04:05"

// Scan returns all sessions found under <rootDir>/.devloop/sessions/, sorted
// newest-first by StartedAt (then by ID descending as a tiebreaker for entries
// without a StartedAt). Sessions with a StartedAt always sort before sessions
// without one.
//
// A missing sessions/ directory is not an error — Scan returns (nil, nil).
// Partial or missing metadata files within a session directory are also not
// errors — the corresponding Session fields are left at their zero values.
func Scan(rootDir string) ([]Session, error) {
	sessionsDir := filepath.Join(rootDir, ".devloop", "sessions")

	entries, err := os.ReadDir(sessionsDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}

	var sessions []Session

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		name := entry.Name()
		if !strings.HasPrefix(name, "TASK-") {
			continue
		}

		dir := filepath.Join(sessionsDir, name)
		s := Session{
			ID:          name,
			Dir:         dir,
			PhaseStates: make(map[string]PhaseState),
		}

		// feature.txt
		s.Feature = readFileString(filepath.Join(dir, "feature.txt"))

		// status
		s.Status = strings.TrimSpace(readFileString(filepath.Join(dir, "status")))

		// started_at (local time)
		if raw := strings.TrimSpace(readFileString(filepath.Join(dir, "started_at"))); raw != "" {
			if t, err := time.ParseInLocation(localTimeFmt, raw, time.Local); err == nil {
				s.StartedAt = t
			}
		}

		// finished_at (local time)
		if raw := strings.TrimSpace(readFileString(filepath.Join(dir, "finished_at"))); raw != "" {
			if t, err := time.ParseInLocation(localTimeFmt, raw, time.Local); err == nil {
				s.FinishedAt = t
			}
		}

		// *.state files
		stateFiles, err := filepath.Glob(filepath.Join(dir, "*.state"))
		if err == nil {
			for _, sf := range stateFiles {
				base := filepath.Base(sf)
				phaseName := strings.TrimSuffix(base, ".state")
				if ps, ok := parsePhaseState(readFileString(sf)); ok {
					s.PhaseStates[phaseName] = ps
				}
			}
		}

		sessions = append(sessions, s)
	}

	sortSessions(sessions)
	return sessions, nil
}

// readFileString reads an entire file as a string. Returns "" on any error
// (including not-found), so callers can treat missing files as empty.
func readFileString(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return string(b)
}

// parsePhaseState parses the content of a *.state file.
// Expected format: "STATUS:TIMESTAMP", e.g. "done:2026-05-16T14:33:53".
// Returns (PhaseState, true) on success; ("", false) if the format is wrong
// or the file content is empty.
func parsePhaseState(content string) (PhaseState, bool) {
	content = strings.TrimSpace(content)
	if content == "" {
		return PhaseState{}, false
	}
	idx := strings.Index(content, ":")
	if idx < 0 {
		// No colon — treat the whole value as status with zero time.
		return PhaseState{Status: content}, true
	}

	status := content[:idx]
	tsStr := content[idx+1:]

	t, err := time.ParseInLocation(localTimeFmt, tsStr, time.Local)
	if err != nil {
		// Return status even if timestamp can't be parsed.
		return PhaseState{Status: status}, true
	}
	return PhaseState{Status: status, Time: t}, true
}

// sortSessions sorts sessions in-place: newest-first by StartedAt for sessions
// that have a non-zero StartedAt, then by ID descending (TASK-IDs are
// chronological so lexicographic descending == newest-first). All sessions
// with a StartedAt come before those without.
func sortSessions(sessions []Session) {
	sort.SliceStable(sessions, func(i, j int) bool {
		si, sj := sessions[i], sessions[j]
		iHas := !si.StartedAt.IsZero()
		jHas := !sj.StartedAt.IsZero()

		if iHas && jHas {
			if !si.StartedAt.Equal(sj.StartedAt) {
				return si.StartedAt.After(sj.StartedAt)
			}
			// Tiebreak by ID descending.
			return si.ID > sj.ID
		}
		if iHas && !jHas {
			return true
		}
		if !iHas && jHas {
			return false
		}
		// Both have zero StartedAt — sort by ID descending.
		return si.ID > sj.ID
	})
}
