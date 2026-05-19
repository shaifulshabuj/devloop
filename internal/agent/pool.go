package agent

import (
	"sync"
	"time"

	"github.com/google/uuid"
)

// SessionPool maintains a set of named, reusable sessions keyed by (projectID, role).
type SessionPool struct {
	mu       sync.Mutex
	sessions map[string]*PooledSession
	runner   *Runner
}

// PooledSession wraps a Session with a deterministic ID and reuse tracking.
type PooledSession struct {
	ID         string // UUID v5 from projectID+role
	ProjectID  string
	Role       string // e.g. "orchestrator", "worker", "reviewer"
	Backend    string
	CreatedAt  time.Time
	LastUsedAt time.Time
	UseCount   int
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
		CreatedAt:  now,
		LastUsedAt: now,
		UseCount:   1,
	}
	p.sessions[key] = ps
	return ps
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
