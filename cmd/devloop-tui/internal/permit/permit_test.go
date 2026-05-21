package permit

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func mkroot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, Dir), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	return root
}

func writeJSON(t *testing.T, root, id, body string) {
	t.Helper()
	path := filepath.Join(root, Dir, id+".json")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
}

func writeResponse(t *testing.T, root, id, decision string) {
	t.Helper()
	path := filepath.Join(root, Dir, id+".response")
	if err := os.WriteFile(path, []byte(decision), 0o644); err != nil {
		t.Fatalf("write response: %v", err)
	}
}

func TestRead_MissingDir(t *testing.T) {
	root := t.TempDir() // no .devloop dir at all
	got, err := Read(root)
	if err != nil {
		t.Errorf("missing dir should not error, got %v", err)
	}
	if len(got) != 0 {
		t.Errorf("missing dir should yield empty slice, got %d items", len(got))
	}
}

func TestRead_EmptyDir(t *testing.T) {
	root := mkroot(t)
	got, _ := Read(root)
	if len(got) != 0 {
		t.Errorf("empty dir → empty slice, got %v", got)
	}
}

func TestRead_ParsesPendingItems(t *testing.T) {
	root := mkroot(t)
	writeJSON(t, root, "abc12f", `{"command":"rsync -av dist/ user@host:/var/www","tool":"Bash","ts":"2026-05-20T10:00:00Z"}`)
	writeJSON(t, root, "7d4e91", `{"command":"npm install -g foo","tool":"Bash","ts":"2026-05-20T10:01:00Z"}`)
	got, err := Read(root)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 items, got %d", len(got))
	}
	// Sorted oldest-first.
	if got[0].ID != "abc12f" || got[1].ID != "7d4e91" {
		t.Errorf("expected oldest-first ordering, got %v / %v", got[0].ID, got[1].ID)
	}
	if got[0].Command != "rsync -av dist/ user@host:/var/www" {
		t.Errorf("Command mismatch, got %q", got[0].Command)
	}
}

func TestRead_SkipsResolved(t *testing.T) {
	root := mkroot(t)
	writeJSON(t, root, "abc", `{"command":"a","tool":"Bash","ts":"2026-05-20T10:00:00Z"}`)
	writeJSON(t, root, "def", `{"command":"b","tool":"Bash","ts":"2026-05-20T10:01:00Z"}`)
	writeResponse(t, root, "abc", "allow")
	got, _ := Read(root)
	if len(got) != 1 || got[0].ID != "def" {
		t.Errorf("expected only 'def' pending, got %v", got)
	}
}

func TestRead_SkipsMalformed(t *testing.T) {
	root := mkroot(t)
	writeJSON(t, root, "good", `{"command":"x","tool":"Bash","ts":"2026-05-20T10:00:00Z"}`)
	writeJSON(t, root, "bad", `not valid json {`)
	got, _ := Read(root)
	if len(got) != 1 {
		t.Errorf("malformed JSON should be skipped silently, got %d items", len(got))
	}
}

func TestCount(t *testing.T) {
	root := mkroot(t)
	if Count(root) != 0 {
		t.Errorf("Count should be 0 for empty queue")
	}
	writeJSON(t, root, "a", `{"command":"x","tool":"Bash","ts":""}`)
	writeJSON(t, root, "b", `{"command":"y","tool":"Bash","ts":""}`)
	if Count(root) != 2 {
		t.Errorf("Count should be 2, got %d", Count(root))
	}
}

func TestItem_ShortIDAndRelativeTime(t *testing.T) {
	item := Item{
		ID:          "abc1234567",
		Command:     "x",
		RequestedAt: time.Date(2026, 5, 20, 10, 0, 0, 0, time.UTC),
	}
	if item.ShortID() != "abc1234" {
		t.Errorf("ShortID expected abc1234, got %q", item.ShortID())
	}
	now := time.Date(2026, 5, 20, 10, 1, 15, 0, time.UTC)
	rt := item.RelativeTime(now)
	if rt != "1m ago" {
		t.Errorf("RelativeTime expected '1m ago', got %q", rt)
	}
}

func TestItem_RelativeTimeJustNow(t *testing.T) {
	item := Item{ID: "x"}
	if got := item.RelativeTime(time.Now()); got != "just now" {
		t.Errorf("zero RequestedAt → 'just now', got %q", got)
	}
}
