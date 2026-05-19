CREATE TABLE IF NOT EXISTS sessions (
    id              TEXT    PRIMARY KEY,
    project_id      TEXT    NOT NULL,
    role            TEXT    NOT NULL,
    backend         TEXT    NOT NULL,
    status          TEXT    NOT NULL DEFAULT 'idle',
    process_pid     INTEGER,
    context_summary TEXT,
    message_count   INTEGER NOT NULL DEFAULT 0,
    last_used_at    INTEGER NOT NULL,
    created_at      INTEGER NOT NULL,
    UNIQUE(project_id, role)
);

CREATE TABLE IF NOT EXISTS copilot_history (
    id         TEXT    PRIMARY KEY,
    session_id TEXT    NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    role       TEXT    NOT NULL,
    content    TEXT    NOT NULL,
    created_at INTEGER NOT NULL
);
