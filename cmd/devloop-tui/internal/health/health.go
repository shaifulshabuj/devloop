// Package health surfaces the devloop pipeline's provider-failover state to
// the TUI's top bar. The single source of truth is the file written by the
// bash runtime: .devloop/provider-health.sh — a shell-sourceable key=value
// list with six HEALTH_* variables.
//
// We intentionally do not source the file (no shell, no side effects); we
// parse the line format directly. Missing or malformed files yield a
// zero-value struct, which renders as "unknown / probably ok" rather than
// "broken".
package health

import (
	"bufio"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// File is the on-disk location relative to the project root.
const File = ".devloop/provider-health.sh"

// Variable names emitted by devloop.sh. Kept as constants so a tooling rename
// upstream is a one-line fix here.
const (
	keyMainSince      = "HEALTH_MAIN_LIMITED_SINCE"
	keyMainOverride   = "HEALTH_MAIN_OVERRIDE"
	keyMainLastProbe  = "HEALTH_MAIN_LAST_PROBE"
	keyWorkerSince    = "HEALTH_WORKER_LIMITED_SINCE"
	keyWorkerOverride = "HEALTH_WORKER_OVERRIDE"
	keyWorkerLastProbe = "HEALTH_WORKER_LAST_PROBE"
)

// Side identifies which half of the pipeline a state belongs to.
type Side int

const (
	Main Side = iota
	Worker
)

// State is the failover snapshot for one side (main or worker).
type State struct {
	// LimitedSince is the wall-clock time the side was first detected as
	// rate-limited. Zero value = not limited.
	LimitedSince time.Time

	// Override is the name of the fallback provider currently in use
	// (e.g. "copilot" when main=claude got limited). Empty = no override.
	Override string

	// LastProbe is the most recent time the limited provider was re-tested.
	// Zero value = never probed since the limit hit.
	LastProbe time.Time
}

// Limited reports whether this side is currently using a fallback provider.
func (s State) Limited() bool { return !s.LimitedSince.IsZero() || s.Override != "" }

// ProviderHealth is the combined snapshot the TUI top bar consumes.
type ProviderHealth struct {
	Main   State
	Worker State

	// SourceMissing is true when provider-health.sh did not exist (or was
	// unreadable). The TUI treats this as "no failover state recorded yet"
	// — which is the common case on a fresh project — and shows providers
	// as healthy.
	SourceMissing bool
}

// Load reads provider-health.sh from the project root and returns the
// parsed snapshot. Failures degrade gracefully: a missing file returns
// ProviderHealth{SourceMissing: true}, malformed lines are skipped.
func Load(projectRoot string) ProviderHealth {
	path := filepath.Join(projectRoot, File)
	f, err := os.Open(path)
	if err != nil {
		return ProviderHealth{SourceMissing: true}
	}
	defer f.Close()

	pairs := map[string]string{}
	sc := bufio.NewScanner(f)
	// Allow long lines defensively — provider-health.sh is tiny but we
	// don't want to silently truncate if a future field grows.
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		// Strip an optional leading `export ` (bash idiom) so we tolerate
		// either `KEY=val` or `export KEY=val`.
		line = strings.TrimPrefix(line, "export ")
		eq := strings.IndexByte(line, '=')
		if eq <= 0 {
			continue
		}
		key := strings.TrimSpace(line[:eq])
		val := strings.TrimSpace(line[eq+1:])
		// Unquote conservatively — handle both "x" and 'x'.
		if len(val) >= 2 {
			if (val[0] == '"' && val[len(val)-1] == '"') ||
				(val[0] == '\'' && val[len(val)-1] == '\'') {
				val = val[1 : len(val)-1]
			}
		}
		pairs[key] = val
	}
	// sc.Err() is intentionally ignored: a partial parse is still useful.
	_ = sc.Err()

	return ProviderHealth{
		Main: State{
			LimitedSince: parseUnixSeconds(pairs[keyMainSince]),
			Override:     pairs[keyMainOverride],
			LastProbe:    parseUnixSeconds(pairs[keyMainLastProbe]),
		},
		Worker: State{
			LimitedSince: parseUnixSeconds(pairs[keyWorkerSince]),
			Override:     pairs[keyWorkerOverride],
			LastProbe:    parseUnixSeconds(pairs[keyWorkerLastProbe]),
		},
	}
}

// parseUnixSeconds turns "1716020118" into time.Time. Empty / non-numeric
// input returns the zero time.
func parseUnixSeconds(s string) time.Time {
	if s == "" {
		return time.Time{}
	}
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil || n <= 0 {
		return time.Time{}
	}
	return time.Unix(n, 0)
}
