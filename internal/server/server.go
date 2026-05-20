// Package server implements the optional local HTTP API for DevLoop.
package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"sync"

	"github.com/google/uuid"

	"github.com/shaifulshabuj/devloop/v6/internal/agent"
	"github.com/shaifulshabuj/devloop/v6/internal/orchestrator"
	"github.com/shaifulshabuj/devloop/v6/internal/storage"
)

const version = "v6.0.0-dev"

// taskState holds in-flight output for a running task and its subscribers.
type taskState struct {
	mu          sync.Mutex
	done        bool
	subscribers []chan string
}

// addLine fans out a line to all SSE subscribers.
func (ts *taskState) addLine(line string) {
	ts.mu.Lock()
	defer ts.mu.Unlock()
	for _, sub := range ts.subscribers {
		select {
		case sub <- line:
		default:
		}
	}
}

// subscribe returns past context and a channel of future lines.
// The channel is closed when the task completes.
func (ts *taskState) subscribe() <-chan string {
	ts.mu.Lock()
	defer ts.mu.Unlock()
	ch := make(chan string, 64)
	if ts.done {
		close(ch)
	} else {
		ts.subscribers = append(ts.subscribers, ch)
	}
	return ch
}

// complete closes all subscriber channels.
func (ts *taskState) complete() {
	ts.mu.Lock()
	defer ts.mu.Unlock()
	ts.done = true
	for _, sub := range ts.subscribers {
		close(sub)
	}
	ts.subscribers = nil
}

// Server is a local HTTP API for DevLoop.
type Server struct {
	addr   string // e.g. "127.0.0.1:7777"
	store  *storage.Store
	runner *agent.Runner // may be nil (disables dispatch)
	tasks  sync.Map      // taskID → *taskState
	mux    *http.ServeMux
}

// New creates a new Server and registers all routes on a fresh ServeMux.
// runner may be nil, in which case POST /task will mark tasks as failed immediately.
func New(addr string, store *storage.Store, runner *agent.Runner) *Server {
	s := &Server{
		addr:   addr,
		store:  store,
		runner: runner,
		mux:    http.NewServeMux(),
	}
	s.registerRoutes()
	return s
}

func (s *Server) registerRoutes() {
	// Legacy plural routes (kept for backward compatibility).
	s.mux.HandleFunc("GET /health", s.handleHealth)
	s.mux.HandleFunc("GET /tasks", s.handleListTasks)
	s.mux.HandleFunc("POST /tasks", s.handleCreateTask)
	s.mux.HandleFunc("GET /tasks/{id}", s.handleGetTask)

	// New dispatch-wired singular routes.
	s.mux.HandleFunc("POST /task", s.handleSubmitTask)
	s.mux.HandleFunc("GET /task/{id}", s.handleTaskStatus)
	s.mux.HandleFunc("GET /task/{id}/stream", s.handleTaskStream)
}

// Start runs the HTTP server and blocks until ctx is cancelled, at which point
// it shuts down gracefully. ListenAndServe errors other than ErrServerClosed
// are returned directly.
func (s *Server) Start(ctx context.Context) error {
	srv := &http.Server{
		Addr:    s.addr,
		Handler: s.mux,
	}
	return s.serve(ctx, srv, func() error { return srv.ListenAndServe() })
}

// Serve is like Start but accepts an already-open listener, avoiding the
// TOCTOU race between binding a free port and starting the server.
// Useful for tests and callers that need to know the bound address upfront.
func (s *Server) Serve(ctx context.Context, ln net.Listener) error {
	srv := &http.Server{Handler: s.mux}
	return s.serve(ctx, srv, func() error { return srv.Serve(ln) })
}

func (s *Server) serve(ctx context.Context, srv *http.Server, listenFn func() error) error {
	errCh := make(chan error, 1)
	go func() {
		if err := listenFn(); !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
		close(errCh)
	}()

	select {
	case <-ctx.Done():
		return srv.Shutdown(context.Background()) //nolint:contextcheck
	case err := <-errCh:
		return err
	}
}

// handleHealth returns 200 {"status":"ok","version":"v6.0.0-dev"}.
func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{
		"status":  "ok",
		"version": version,
	})
}

// handleListTasks returns the last 20 tasks as a JSON array.
func (s *Server) handleListTasks(w http.ResponseWriter, _ *http.Request) {
	tasks, err := s.store.ListTasks(20)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errBody(err))
		return
	}
	if tasks == nil {
		tasks = []*storage.Task{}
	}
	writeJSON(w, http.StatusOK, tasks)
}

type createTaskRequest struct {
	Title string `json:"title"`
}

type createTaskResponse struct {
	ID string `json:"id"`
}

// handleCreateTask reads {"title":"..."} from the request body, persists the
// task, and returns 201 {"id":"..."}. Does NOT dispatch.
func (s *Server) handleCreateTask(w http.ResponseWriter, r *http.Request) {
	var req createTaskRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON"})
		return
	}
	if req.Title == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "title is required"})
		return
	}

	id := uuid.New().String()
	if err := s.store.CreateTask(id, req.Title); err != nil {
		writeJSON(w, http.StatusInternalServerError, errBody(err))
		return
	}

	writeJSON(w, http.StatusCreated, createTaskResponse{ID: id})
}

// handleGetTask returns the task with the given {id}, or 404 if not found.
func (s *Server) handleGetTask(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	task, err := s.store.GetTask(id)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "task not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, errBody(err))
		return
	}
	writeJSON(w, http.StatusOK, task)
}

// --- New dispatch-wired endpoints ---

type submitTaskRequest struct {
	Title string `json:"title"`
}

type submitTaskResponse struct {
	ID string `json:"id"`
}

// handleSubmitTask creates a task and dispatches it asynchronously.
// Returns 202 {"id":"..."} immediately.
func (s *Server) handleSubmitTask(w http.ResponseWriter, r *http.Request) {
	var req submitTaskRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON"})
		return
	}
	if req.Title == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "title is required"})
		return
	}

	id := uuid.New().String()
	if err := s.store.CreateTask(id, req.Title); err != nil {
		writeJSON(w, http.StatusInternalServerError, errBody(err))
		return
	}

	ts := &taskState{}
	s.tasks.Store(id, ts)
	go s.runDispatch(id, req.Title, ts)

	writeJSON(w, http.StatusAccepted, submitTaskResponse{ID: id})
}

// runDispatch runs Plan+Dispatch for a task and streams lines via taskState.
func (s *Server) runDispatch(taskID, title string, ts *taskState) {
	defer func() {
		ts.complete()
		s.tasks.Delete(taskID)
	}()

	appendLine := func(line string) {
		_ = s.store.AppendContext(uuid.New().String(), taskID, "assistant", line)
		ts.addLine(line)
	}

	if s.runner == nil {
		_ = s.store.UpdateTaskStatus(taskID, "failed")
		appendLine("error: no runner configured")
		return
	}

	orch := orchestrator.New(s.store, s.runner)
	disp := orchestrator.NewDispatcher(s.store, s.runner)

	plan, err := orch.Plan(context.Background(), title)
	if err != nil {
		_ = s.store.UpdateTaskStatus(taskID, "failed")
		appendLine("error planning: " + err.Error())
		return
	}

	for _, step := range plan.Steps {
		appendLine(fmt.Sprintf("[%d/%d] %s", step.Number, len(plan.Steps), step.Description))
	}

	result, err := disp.Dispatch(context.Background(), plan)
	if err != nil {
		appendLine("error: " + err.Error())
	}
	if result != nil {
		for _, sr := range result.Results {
			if sr.Output != "" {
				appendLine(sr.Output)
			}
		}
	}
}

type taskStatusResponse struct {
	ID     string   `json:"id"`
	Status string   `json:"status"`
	Output []string `json:"output"`
}

// handleTaskStatus returns task status and accumulated output lines.
func (s *Server) handleTaskStatus(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	task, err := s.store.GetTask(id)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "task not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, errBody(err))
		return
	}

	entries, err := s.store.GetContext(id)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errBody(err))
		return
	}

	lines := make([]string, 0, len(entries))
	for _, e := range entries {
		lines = append(lines, e.Content)
	}

	writeJSON(w, http.StatusOK, taskStatusResponse{
		ID:     task.ID,
		Status: task.Status,
		Output: lines,
	})
}

// handleTaskStream streams task output as Server-Sent Events.
func (s *Server) handleTaskStream(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")

	// Verify task exists.
	if _, err := s.store.GetTask(id); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			http.Error(w, "task not found", http.StatusNotFound)
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)

	flusher, canFlush := w.(http.Flusher)

	flush := func() {
		if canFlush {
			flusher.Flush()
		}
	}

	// Replay persisted lines.
	entries, _ := s.store.GetContext(id)
	for _, e := range entries {
		_, _ = fmt.Fprintf(w, "data: %s\n\n", e.Content)
	}
	flush()

	// Subscribe for in-flight lines.
	val, running := s.tasks.Load(id)
	if !running {
		_, _ = fmt.Fprintf(w, "event: done\ndata: done\n\n")
		flush()
		return
	}

	ts, ok := val.(*taskState)
	if !ok {
		http.Error(w, "internal error: invalid task state", http.StatusInternalServerError)
		return
	}
	ch := ts.subscribe()

	for {
		select {
		case line, ok := <-ch:
			if !ok {
				_, _ = fmt.Fprintf(w, "event: done\ndata: done\n\n")
				flush()
				return
			}
			_, _ = fmt.Fprintf(w, "data: %s\n\n", line)
			flush()
		case <-r.Context().Done():
			return
		}
	}
}

// writeJSON sets Content-Type, writes the status code, and JSON-encodes v.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func errBody(err error) map[string]string {
	return map[string]string{"error": err.Error()}
}
