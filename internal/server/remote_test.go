package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/shaifulshabuj/devloop/v6/internal/storage"
)

func TestTriggerQueue_EnqueueDequeue(t *testing.T) {
	q := NewTriggerQueue()

	q.Enqueue(TriggerRequest{Task: "task1"})
	q.Enqueue(TriggerRequest{Task: "task2"})

	r1 := q.Dequeue()
	if r1 == nil || r1.Task != "task1" {
		t.Fatalf("expected task1, got %v", r1)
	}

	r2 := q.Dequeue()
	if r2 == nil || r2.Task != "task2" {
		t.Fatalf("expected task2, got %v", r2)
	}

	r3 := q.Dequeue()
	if r3 != nil {
		t.Fatalf("expected nil on empty dequeue, got %v", r3)
	}
}

func TestTriggerEndpoint(t *testing.T) {
	store, err := storage.Open(":memory:")
	if err != nil {
		t.Fatalf("storage.Open: %v", err)
	}
	defer func() { _ = store.Close() }()

	mux := http.NewServeMux()
	queue := NewTriggerQueue()
	RegisterRemoteRoutes(mux, store, queue)

	body := strings.NewReader(`{"task":"do something"}`)
	req := httptest.NewRequest(http.MethodPost, "/trigger", body)
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusAccepted {
		t.Fatalf("expected 202, got %d: %s", w.Code, w.Body.String())
	}

	var resp TriggerResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp.TaskID == "" {
		t.Error("expected non-empty task_id")
	}
	if resp.Status != "queued" {
		t.Errorf("expected status 'queued', got %q", resp.Status)
	}
	if queue.Len() != 1 {
		t.Errorf("expected queue length 1, got %d", queue.Len())
	}
}

func TestQueueEndpoint(t *testing.T) {
	store, err := storage.Open(":memory:")
	if err != nil {
		t.Fatalf("storage.Open: %v", err)
	}
	defer func() { _ = store.Close() }()

	mux := http.NewServeMux()
	queue := NewTriggerQueue()
	RegisterRemoteRoutes(mux, store, queue)

	req := httptest.NewRequest(http.MethodGet, "/queue", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	var resp map[string]int
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp["pending"] != 0 {
		t.Errorf("expected pending 0, got %d", resp["pending"])
	}
}
