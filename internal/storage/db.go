// Package storage implements SQLite persistence for DevLoop tasks, steps,
// and context entries.
package storage

import (
	"database/sql"
	"embed"
	"fmt"
	"io/fs"
	"sort"
	"strings"
	"time"

	_ "modernc.org/sqlite" // register pure-Go sqlite driver (CGO-free, cross-platform)
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

// Task represents a DevLoop task stored in the database.
type Task struct {
	ID        string
	Title     string
	Status    string
	CreatedAt int64
	UpdatedAt int64
	Config    string
}

// Step represents a single step belonging to a Task.
type Step struct {
	ID          string
	TaskID      string
	Description string
	Status      string
	Output      string
	CreatedAt   int64
}

// ContextEntry represents one message in a task's conversation context.
type ContextEntry struct {
	ID        string
	TaskID    string
	Role      string
	Content   string
	CreatedAt int64
}

// Store wraps a database/sql connection to a SQLite database.
type Store struct {
	db *sql.DB
}

// Open opens (or creates) the SQLite database at dbPath, enables WAL mode,
// and applies any pending versioned migrations. Use ":memory:" for tests.
func Open(dbPath string) (*Store, error) {
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, fmt.Errorf("opening database: %w", err)
	}

	if _, err = db.Exec("PRAGMA journal_mode=WAL"); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("enabling WAL mode: %w", err)
	}

	s := &Store{db: db}
	if err = s.migrate(); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("running migrations: %w", err)
	}

	return s, nil
}

// Close closes the underlying database connection.
func (s *Store) Close() error {
	return s.db.Close()
}

// migrate creates the schema_migrations tracking table and applies all SQL
// files from internal/storage/migrations/ that have not yet been applied.
// Files are applied in lexicographic (version) order.
func (s *Store) migrate() error {
	_, err := s.db.Exec(`
		CREATE TABLE IF NOT EXISTS schema_migrations (
			version    TEXT    PRIMARY KEY,
			applied_at INTEGER NOT NULL
		)
	`)
	if err != nil {
		return fmt.Errorf("creating schema_migrations: %w", err)
	}

	entries, err := fs.ReadDir(migrationsFS, "migrations")
	if err != nil {
		return fmt.Errorf("reading migrations dir: %w", err)
	}

	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".sql") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)

	for _, name := range names {
		version := strings.TrimSuffix(name, ".sql")

		var count int
		if err = s.db.QueryRow(
			"SELECT COUNT(*) FROM schema_migrations WHERE version = ?", version,
		).Scan(&count); err != nil {
			return fmt.Errorf("checking migration %s: %w", version, err)
		}
		if count > 0 {
			continue
		}

		content, err := migrationsFS.ReadFile("migrations/" + name)
		if err != nil {
			return fmt.Errorf("reading migration %s: %w", name, err)
		}

		if _, err = s.db.Exec(string(content)); err != nil {
			return fmt.Errorf("applying migration %s: %w", version, err)
		}

		if _, err = s.db.Exec(
			"INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
			version, time.Now().Unix(),
		); err != nil {
			return fmt.Errorf("recording migration %s: %w", version, err)
		}
	}

	return nil
}

// CreateTask inserts a new task with status "pending".
func (s *Store) CreateTask(id, title string) error {
	now := time.Now().Unix()
	_, err := s.db.Exec(
		"INSERT INTO tasks (id, title, status, created_at, updated_at) VALUES (?, ?, 'pending', ?, ?)",
		id, title, now, now,
	)
	return err
}

// UpdateTaskStatus sets the status and updated_at timestamp for a task.
func (s *Store) UpdateTaskStatus(id, status string) error {
	_, err := s.db.Exec(
		"UPDATE tasks SET status = ?, updated_at = ? WHERE id = ?",
		status, time.Now().Unix(), id,
	)
	return err
}

// GetTask retrieves a task by ID. Returns sql.ErrNoRows if not found.
func (s *Store) GetTask(id string) (*Task, error) {
	row := s.db.QueryRow(
		"SELECT id, title, status, created_at, updated_at, config FROM tasks WHERE id = ?",
		id,
	)

	t := &Task{}
	var config sql.NullString
	if err := row.Scan(&t.ID, &t.Title, &t.Status, &t.CreatedAt, &t.UpdatedAt, &config); err != nil {
		return nil, err
	}
	if config.Valid {
		t.Config = config.String
	}
	return t, nil
}

// ListTasks returns up to limit tasks ordered by creation time descending.
func (s *Store) ListTasks(limit int) ([]*Task, error) {
	rows, err := s.db.Query(
		"SELECT id, title, status, created_at, updated_at, config FROM tasks ORDER BY created_at DESC LIMIT ?",
		limit,
	)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()

	var tasks []*Task
	for rows.Next() {
		t := &Task{}
		var config sql.NullString
		if err = rows.Scan(&t.ID, &t.Title, &t.Status, &t.CreatedAt, &t.UpdatedAt, &config); err != nil {
			return nil, err
		}
		if config.Valid {
			t.Config = config.String
		}
		tasks = append(tasks, t)
	}
	return tasks, rows.Err()
}

// ListTasksFiltered returns up to limit tasks ordered by creation time descending.
// If status is non-empty, only tasks with that status are returned.
func (s *Store) ListTasksFiltered(limit int, status string) ([]*Task, error) {
	var (
		rows *sql.Rows
		err  error
	)
	if status == "" {
		rows, err = s.db.Query(
			"SELECT id, title, status, created_at, updated_at, config FROM tasks ORDER BY created_at DESC LIMIT ?",
			limit,
		)
	} else {
		rows, err = s.db.Query(
			"SELECT id, title, status, created_at, updated_at, config FROM tasks WHERE status = ? ORDER BY created_at DESC LIMIT ?",
			status, limit,
		)
	}
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()

	var tasks []*Task
	for rows.Next() {
		t := &Task{}
		var config sql.NullString
		if err = rows.Scan(&t.ID, &t.Title, &t.Status, &t.CreatedAt, &t.UpdatedAt, &config); err != nil {
			return nil, err
		}
		if config.Valid {
			t.Config = config.String
		}
		tasks = append(tasks, t)
	}
	return tasks, rows.Err()
}

// CreateStep inserts a new step with status "pending" linked to taskID.
func (s *Store) CreateStep(id, taskID, description string) error {
	_, err := s.db.Exec(
		"INSERT INTO steps (id, task_id, description, status, created_at) VALUES (?, ?, ?, 'pending', ?)",
		id, taskID, description, time.Now().Unix(),
	)
	return err
}

// UpdateStep sets the status and output text for a step.
func (s *Store) UpdateStep(id, status, output string) error {
	_, err := s.db.Exec(
		"UPDATE steps SET status = ?, output = ? WHERE id = ?",
		status, output, id,
	)
	return err
}

// AppendContext inserts a new context entry linked to taskID.
func (s *Store) AppendContext(id, taskID, role, content string) error {
	_, err := s.db.Exec(
		"INSERT INTO context_entries (id, task_id, role, content, created_at) VALUES (?, ?, ?, ?, ?)",
		id, taskID, role, content, time.Now().Unix(),
	)
	return err
}

// SessionRecord represents a persisted agent session.
type SessionRecord struct {
	ID             string
	ProjectID      string
	Role           string
	Backend        string
	Status         string // idle | warm | archived | dead
	ProcessPID     int
	ContextSummary string
	MessageCount   int
	LastUsedAt     int64
	CreatedAt      int64
}

// UpsertSession inserts or replaces a session record.
func (s *Store) UpsertSession(r *SessionRecord) error {
	_, err := s.db.Exec(`
		INSERT INTO sessions
			(id, project_id, role, backend, status, process_pid, context_summary, message_count, last_used_at, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			status          = excluded.status,
			process_pid     = excluded.process_pid,
			context_summary = excluded.context_summary,
			message_count   = excluded.message_count,
			last_used_at    = excluded.last_used_at`,
		r.ID, r.ProjectID, r.Role, r.Backend, r.Status, r.ProcessPID,
		r.ContextSummary, r.MessageCount, r.LastUsedAt, r.CreatedAt,
	)
	return err
}

// GetSession retrieves a session by ID. Returns sql.ErrNoRows if not found.
func (s *Store) GetSession(id string) (*SessionRecord, error) {
	row := s.db.QueryRow(`
		SELECT id, project_id, role, backend, status, process_pid,
		       context_summary, message_count, last_used_at, created_at
		FROM sessions WHERE id = ?`, id)
	return scanSession(row)
}

// ListSessions returns all sessions for a project (all projects if projectID is empty).
func (s *Store) ListSessions(projectID string) ([]*SessionRecord, error) {
	var rows *sql.Rows
	var err error
	if projectID == "" {
		rows, err = s.db.Query(`
			SELECT id, project_id, role, backend, status, process_pid,
			       context_summary, message_count, last_used_at, created_at
			FROM sessions ORDER BY last_used_at DESC`)
	} else {
		rows, err = s.db.Query(`
			SELECT id, project_id, role, backend, status, process_pid,
			       context_summary, message_count, last_used_at, created_at
			FROM sessions WHERE project_id = ? ORDER BY last_used_at DESC`, projectID)
	}
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()

	var out []*SessionRecord
	for rows.Next() {
		r, err := scanSession(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// DeleteSession removes a session (and its copilot_history via CASCADE).
func (s *Store) DeleteSession(id string) error {
	_, err := s.db.Exec("DELETE FROM sessions WHERE id = ?", id)
	return err
}

// PurgeStaleSessions deletes sessions whose last_used_at is older than cutoff (unix seconds).
func (s *Store) PurgeStaleSessions(cutoff int64) error {
	_, err := s.db.Exec("DELETE FROM sessions WHERE last_used_at < ?", cutoff)
	return err
}

type scanner interface {
	Scan(dest ...any) error
}

func scanSession(r scanner) (*SessionRecord, error) {
	s := &SessionRecord{}
	var pid sql.NullInt64
	var summary sql.NullString
	err := r.Scan(&s.ID, &s.ProjectID, &s.Role, &s.Backend, &s.Status,
		&pid, &summary, &s.MessageCount, &s.LastUsedAt, &s.CreatedAt)
	if err != nil {
		return nil, err
	}
	if pid.Valid {
		s.ProcessPID = int(pid.Int64)
	}
	if summary.Valid {
		s.ContextSummary = summary.String
	}
	return s, nil
}

// GetContext retrieves all context entries for taskID ordered by creation time.
func (s *Store) GetContext(taskID string) ([]*ContextEntry, error) {
	rows, err := s.db.Query(
		"SELECT id, task_id, role, content, created_at FROM context_entries WHERE task_id = ? ORDER BY created_at ASC",
		taskID,
	)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()

	var entries []*ContextEntry
	for rows.Next() {
		e := &ContextEntry{}
		if err = rows.Scan(&e.ID, &e.TaskID, &e.Role, &e.Content, &e.CreatedAt); err != nil {
			return nil, err
		}
		entries = append(entries, e)
	}
	return entries, rows.Err()
}
