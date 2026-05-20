package agent

import (
	"context"
	"os"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/shaifulshabuj/devloop/v6/internal/storage"
)

const idleTimeout = 30 * time.Minute

// SessionPool maintains a set of named, reusable sessions keyed by (projectID, role).
type SessionPool struct {
	mu       sync.Mutex
	sessions map[string]*PooledSession
	runner   *Runner
}

// PooledSession wraps a Session with a deterministic ID and reuse tracking.
type PooledSession struct {
	ID             string // UUID v5 from projectID+role
	ProjectID      string
	Role           string // e.g. "orchestrator", "worker", "reviewer"
	Backend        string
	ProcessPID     int
	Status         string // idle | warm | archived | dead
	ContextSummary string
	MessageCount   int
	CreatedAt      time.Time
	LastUsedAt     time.Time
	UseCount       int
}

// NewSessionPool creates a new SessionPool backed by the given Runner.
func NewSessionPool(runner *Runner) *SessionPool {
	return &SessionPool{
		sessions: make(map[string]*PooledSession),
		runner:   runner,
	}
}

// SessionID returns the deterministic UUID v5 for a project+role pair.
// Namespace: uuid.NameSpaceURL (a well-known UUID namespace).
// Name: "<projectID>:<role>"
func SessionID(projectID, role string) string {
	name := projectID + ":" + role
	return uuid.NewSHA1(uuid.NameSpaceURL, []byte(name)).String()
}

// poolKey returns the internal map key for a project+role pair.
func poolKey(projectID, role string) string {
	return projectID + ":" + role
}

// Get returns an existing PooledSession for the project+role, or creates a new
// one (without spawning a subprocess). The session's LastUsedAt and UseCount
// are updated on every call.
func (p *SessionPool) Get(projectID, role, backend string) *PooledSession {
	p.mu.Lock()
	defer p.mu.Unlock()

	now := time.Now()
	key := poolKey(projectID, role)

	if ps, ok := p.sessions[key]; ok {
		ps.LastUsedAt = now
		ps.UseCount++
		return ps
	}

	ps := &PooledSession{
		ID:         SessionID(projectID, role),
		ProjectID:  projectID,
		Role:       role,
		Backend:    backend,
		Status:     "idle",
		CreatedAt:  now,
		LastUsedAt: now,
		UseCount:   1,
	}
	p.sessions[key] = ps
	return ps
}

// IsAlive reports whether the session's subprocess is still running.
// Returns false when ProcessPID is 0 or the process cannot be signalled.
func IsAlive(ps *PooledSession) bool {
	if ps.ProcessPID == 0 {
		return false
	}
	proc, err := os.FindProcess(ps.ProcessPID)
	if err != nil {
		return false
	}
	// os.Signal(0) checks process existence without side effects.
	return proc.Signal(os.Signal(nil)) == nil
}

// Remove removes a session from the pool (e.g. after subprocess exits).
func (p *SessionPool) Remove(projectID, role string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	delete(p.sessions, poolKey(projectID, role))
}

// List returns a snapshot of all sessions currently in the pool.
func (p *SessionPool) List() []*PooledSession {
	p.mu.Lock()
	defer p.mu.Unlock()

	out := make([]*PooledSession, 0, len(p.sessions))
	for _, ps := range p.sessions {
		out = append(out, ps)
	}
	return out
}

// Load populates the pool from sessions persisted in store for the given project.
func (p *SessionPool) Load(store *storage.Store, projectID string) error {
	records, err := store.ListSessions(projectID)
	if err != nil {
		return err
	}

	p.mu.Lock()
	defer p.mu.Unlock()

	for _, r := range records {
		key := poolKey(r.ProjectID, r.Role)
		ps := &PooledSession{
			ID:             r.ID,
			ProjectID:      r.ProjectID,
			Role:           r.Role,
			Backend:        r.Backend,
			ProcessPID:     r.ProcessPID,
			Status:         r.Status,
			ContextSummary: r.ContextSummary,
			MessageCount:   r.MessageCount,
			CreatedAt:      time.Unix(r.CreatedAt, 0),
			LastUsedAt:     time.Unix(r.LastUsedAt, 0),
		}
		p.sessions[key] = ps
	}
	return nil
}

// Flush writes all in-memory sessions back to the store.
func (p *SessionPool) Flush(store *storage.Store) error {
	p.mu.Lock()
	defer p.mu.Unlock()

	for _, ps := range p.sessions {
		r := &storage.SessionRecord{
			ID:             ps.ID,
			ProjectID:      ps.ProjectID,
			Role:           ps.Role,
			Backend:        ps.Backend,
			Status:         ps.Status,
			ProcessPID:     ps.ProcessPID,
			ContextSummary: ps.ContextSummary,
			MessageCount:   ps.MessageCount,
			LastUsedAt:     ps.LastUsedAt.Unix(),
			CreatedAt:      ps.CreatedAt.Unix(),
		}
		if err := store.UpsertSession(r); err != nil {
			return err
		}
	}
	return nil
}

// PruneIdle removes sessions that have been idle longer than timeout
// and marks dead sessions whose PID is no longer alive.
func (p *SessionPool) PruneIdle(timeout time.Duration) {
	p.mu.Lock()
	defer p.mu.Unlock()

	cutoff := time.Now().Add(-timeout)
	for key, ps := range p.sessions {
		if ps.LastUsedAt.Before(cutoff) {
			delete(p.sessions, key)
			continue
		}
		if ps.ProcessPID != 0 && !IsAlive(ps) {
			ps.Status = "dead"
			ps.ProcessPID = 0
		}
	}
}

// StartIdlePruner runs PruneIdle on interval in the background, flushing
// to store after each prune. It stops when ctx is cancelled.
func (p *SessionPool) StartIdlePruner(ctx context.Context, store *storage.Store, interval time.Duration) {
	go func() {
		t := time.NewTicker(interval)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				p.PruneIdle(idleTimeout)
				if store != nil {
					_ = p.Flush(store)
					_ = store.PurgeStaleSessions(time.Now().Add(-idleTimeout).Unix())
				}
			}
		}
	}()
}
