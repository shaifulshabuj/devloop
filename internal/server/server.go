// Package server implements the optional local HTTP API for DevLoop.
package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/google/uuid"

	"github.com/shaifulshabuj/devloop/internal/storage"
)

const version = "v6.0.0-dev"

// Server is a local HTTP API for DevLoop.
type Server struct {
	addr  string // e.g. "127.0.0.1:7777"
	store *storage.Store
	mux   *http.ServeMux
}

// New creates a new Server and registers all routes on a fresh ServeMux.
func New(addr string, store *storage.Store) *Server {
	s := &Server{
		addr:  addr,
		store: store,
		mux:   http.NewServeMux(),
	}
	s.registerRoutes()
	return s
}

func (s *Server) registerRoutes() {
	s.mux.HandleFunc("GET /health", s.handleHealth)
	s.mux.HandleFunc("GET /tasks", s.handleListTasks)
	s.mux.HandleFunc("POST /tasks", s.handleCreateTask)
	s.mux.HandleFunc("GET /tasks/{id}", s.handleGetTask)
}

// Start runs the HTTP server and blocks until ctx is cancelled, at which point
// it shuts down gracefully. ListenAndServe errors other than ErrServerClosed
// are returned directly.
func (s *Server) Start(ctx context.Context) error {
	srv := &http.Server{
		Addr:    s.addr,
		Handler: s.mux,
	}

	errCh := make(chan error, 1)
	go func() {
		if err := srv.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
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
	// Always return an array, never null.
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
// task, and returns 201 {"id":"..."}.
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

// writeJSON sets Content-Type, writes the status code, and JSON-encodes v.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func errBody(err error) map[string]string {
	return map[string]string{"error": err.Error()}
}
