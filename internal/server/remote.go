package server

import (
	"encoding/json"
	"net/http"
	"sync"

	"github.com/google/uuid"

	"github.com/shaifulshabuj/devloop/internal/storage"
)

// TriggerRequest is the payload for the /trigger endpoint.
type TriggerRequest struct {
	Task    string `json:"task"`
	Backend string `json:"backend,omitempty"`
}

// TriggerResponse is returned after accepting a trigger.
type TriggerResponse struct {
	TaskID string `json:"task_id"`
	Status string `json:"status"` // "queued"
}

// TriggerQueue is a thread-safe queue of pending trigger requests.
type TriggerQueue struct {
	mu      sync.Mutex
	pending []TriggerRequest
}

// NewTriggerQueue creates a new empty TriggerQueue.
func NewTriggerQueue() *TriggerQueue {
	return &TriggerQueue{}
}

// Enqueue adds a request to the queue.
func (q *TriggerQueue) Enqueue(req TriggerRequest) {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.pending = append(q.pending, req)
}

// Dequeue removes and returns the next request (nil if empty).
func (q *TriggerQueue) Dequeue() *TriggerRequest {
	q.mu.Lock()
	defer q.mu.Unlock()
	if len(q.pending) == 0 {
		return nil
	}
	req := q.pending[0]
	q.pending = q.pending[1:]
	return &req
}

// Len returns the current queue length.
func (q *TriggerQueue) Len() int {
	q.mu.Lock()
	defer q.mu.Unlock()
	return len(q.pending)
}

// RegisterRemoteRoutes adds remote-control routes to an existing ServeMux.
//
//	POST /trigger  → enqueue task, return TriggerResponse with "queued" status
//	GET  /queue    → return JSON {"pending": <len>}
func RegisterRemoteRoutes(mux *http.ServeMux, _ *storage.Store, queue *TriggerQueue) {
	mux.HandleFunc("POST /trigger", func(w http.ResponseWriter, r *http.Request) {
		var req TriggerRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON"})
			return
		}
		if req.Task == "" {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "task is required"})
			return
		}

		taskID := uuid.New().String()
		queue.Enqueue(req)
		writeJSON(w, http.StatusAccepted, TriggerResponse{
			TaskID: taskID,
			Status: "queued",
		})
	})

	mux.HandleFunc("GET /queue", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]int{"pending": queue.Len()})
	})
}
