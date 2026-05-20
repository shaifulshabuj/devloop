package server_test

import (
	"encoding/json"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/shaifulshabuj/devloop/v6/internal/server"
	"github.com/shaifulshabuj/devloop/v6/internal/storage"
)

func startTestServer(t *testing.T) string {
	t.Helper()
	store, err := storage.Open(":memory:")
	if err != nil {
		t.Fatalf("storage.Open: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })

	// Bind a free port before starting the server to avoid TOCTOU races.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("net.Listen: %v", err)
	}
	addr := ln.Addr().String()

	srv := server.New(addr, store, nil) // nil runner: tasks will end "failed"
	ctx := t.Context()
	go func() { _ = srv.Serve(ctx, ln) }()

	// Wait for the server to be ready.
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		resp, err := http.Get("http://" + addr + "/health")
		if err == nil {
			_ = resp.Body.Close()
			break
		}
		time.Sleep(20 * time.Millisecond)
	}

	return addr
}

func TestIntegration_SubmitAndPoll(t *testing.T) {
	addr := startTestServer(t)
	base := "http://" + addr

	// POST /task
	body := strings.NewReader(`{"title":"integration test task"}`)
	resp, err := http.Post(base+"/task", "application/json", body)
	if err != nil {
		t.Fatalf("POST /task: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusAccepted {
		t.Fatalf("expected 202, got %d", resp.StatusCode)
	}

	var postResp struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&postResp); err != nil {
		t.Fatalf("decode POST response: %v", err)
	}
	if postResp.ID == "" {
		t.Fatal("expected non-empty task id")
	}

	// Poll GET /task/{id} until done (status != "pending").
	taskURL := base + "/task/" + postResp.ID
	deadline := time.Now().Add(5 * time.Second)
	var finalStatus string
	for time.Now().Before(deadline) {
		r, err := http.Get(taskURL)
		if err != nil {
			t.Fatalf("GET /task/{id}: %v", err)
		}
		var taskResp struct {
			Status string   `json:"status"`
			Output []string `json:"output"`
		}
		_ = json.NewDecoder(r.Body).Decode(&taskResp)
		_ = r.Body.Close()

		if taskResp.Status != "pending" && taskResp.Status != "running" {
			finalStatus = taskResp.Status
			break
		}
		time.Sleep(50 * time.Millisecond)
	}

	// With nil runner the task should reach "failed".
	if finalStatus == "" {
		t.Fatal("task did not reach a terminal status within deadline")
	}
	if finalStatus != "failed" && finalStatus != "done" {
		t.Errorf("unexpected final status %q", finalStatus)
	}
}
