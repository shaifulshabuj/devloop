# DevLoop v6 — Storage Design

## 1. Three-Layer Storage

DevLoop uses three complementary storage mechanisms:

| Layer | Location | Purpose | When written |
|-------|----------|---------|-------------|
| **SQLite** | `~/.devloop/devloop.db` | Queryable index, history, learnings | Continuously |
| **Files** | `<project>/.devloop/` | Human-readable specs, outputs, configs | Per task step |
| **Git** | Project repository | Permanent audit trail, attribution | On task complete |

All three stay in sync. SQLite is the query layer; files are the source of
truth for content; git provides history and portability.

---

## 2. SQLite Schema

### 2.1 Core tables

```sql
-- Global project registry
CREATE TABLE projects (
  id          TEXT PRIMARY KEY,    -- "myapp"
  name        TEXT NOT NULL,
  path        TEXT NOT NULL UNIQUE,
  stack       TEXT,                -- JSON: ["React", "Node.js", "PostgreSQL"]
  created_at  INTEGER NOT NULL,
  last_active INTEGER NOT NULL
);

-- Tasks (one per user request)
CREATE TABLE tasks (
  id          TEXT PRIMARY KEY,    -- "TASK-20260519-2341"
  project_id  TEXT NOT NULL REFERENCES projects(id),
  description TEXT NOT NULL,       -- "add social login button"
  status      TEXT NOT NULL,       -- pending|running|complete|failed|interrupted
  complexity  TEXT,                -- low|medium|high
  task_type   TEXT,                -- feature|bugfix|refactor|analysis|docs
  plan        TEXT,                -- JSON: the approved plan
  summary     TEXT,                -- final summary (populated on complete)
  cost_usd    REAL,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);

-- Individual steps within a task
CREATE TABLE steps (
  id          TEXT PRIMARY KEY,    -- "TASK-20260519-2341-s1"
  task_id     TEXT NOT NULL REFERENCES tasks(id),
  sequence    INTEGER NOT NULL,
  persona     TEXT NOT NULL,       -- "analyst", "architect", etc.
  backend     TEXT NOT NULL,       -- "claude", "copilot"
  model       TEXT NOT NULL,       -- "claude-opus-4-7", etc.
  description TEXT NOT NULL,
  status      TEXT NOT NULL,       -- pending|running|complete|failed|skipped
  output      TEXT,                -- full agent output
  result      TEXT,                -- extracted result (summary/spec/verdict)
  cost_usd    REAL,
  started_at  INTEGER,
  completed_at INTEGER
);

-- Agent questions and answers (mid-task interaction log)
CREATE TABLE interactions (
  id          TEXT PRIMARY KEY,
  step_id     TEXT NOT NULL REFERENCES steps(id),
  question    TEXT NOT NULL,
  answer      TEXT,
  answered_at INTEGER
);

-- Learnings extracted from completed tasks
CREATE TABLE learnings (
  id          TEXT PRIMARY KEY,
  project_id  TEXT REFERENCES projects(id),  -- NULL = global learning
  persona     TEXT,                          -- NULL = applies to all
  source_task TEXT REFERENCES tasks(id),
  content     TEXT NOT NULL,                 -- the learning text
  applied     INTEGER DEFAULT 0,             -- 0/1: absorbed into persona?
  created_at  INTEGER NOT NULL
);

-- Session context snapshots (for resume)
CREATE TABLE context_snapshots (
  task_id     TEXT NOT NULL REFERENCES tasks(id),
  snapshot    TEXT NOT NULL,  -- JSON: full Context Store state
  created_at  INTEGER NOT NULL,
  PRIMARY KEY (task_id)
);

-- Global agent backends
CREATE TABLE backends (
  id          TEXT PRIMARY KEY,
  binary      TEXT NOT NULL,
  type        TEXT NOT NULL,   -- interactive-cli|api
  config      TEXT,            -- JSON: extra flags, env vars
  available   INTEGER,         -- 0/1: last health check
  checked_at  INTEGER
);

-- Skill registry
CREATE TABLE skills (
  id          TEXT PRIMARY KEY,
  project_id  TEXT REFERENCES projects(id),  -- NULL = global skill
  name        TEXT NOT NULL,
  description TEXT,
  path        TEXT NOT NULL,   -- file path to SKILL.md
  version     TEXT,
  updated_at  INTEGER
);
```

### 2.2 Full-text search

```sql
-- FTS5 index over task descriptions, step outputs, learnings
CREATE VIRTUAL TABLE search_index USING fts5(
  content,
  source_type,   -- "task"|"step"|"learning"|"spec"
  source_id,
  project_id
);
```

Example queries:
```sql
-- "What did we build last week?"
SELECT t.description, t.status, datetime(t.created_at,'unixepoch') as created
FROM tasks t
WHERE t.created_at > unixepoch('now', '-7 days')
ORDER BY t.created_at DESC;

-- "Have we solved this kind of problem before?"
SELECT content, source_type, source_id
FROM search_index
WHERE search_index MATCH 'OAuth login social'
LIMIT 10;

-- Cost breakdown by project
SELECT p.name, SUM(t.cost_usd) as total_cost
FROM tasks t JOIN projects p ON t.project_id = p.id
GROUP BY p.id ORDER BY total_cost DESC;
```

---

## 3. File Layout

```
~/.devloop/
├── config.toml             Global DevLoop config
├── devloop.db              SQLite database
├── projects.toml           Project registry
├── skills/                 Global skills
│   ├── devloop-release/
│   │   ├── SKILL.md
│   │   └── lessons-learned.md
│   └── blog-posting/
│       └── SKILL.md
└── agents/                 Global agent/persona definitions
    ├── analyst.toml
    ├── architect.toml
    ├── coder.toml
    └── reviewer.toml

<project>/
└── .devloop/
    ├── config.toml         Project config (overrides global)
    ├── agents/             Project-specific personas
    │   └── db-migrator.toml
    ├── skills/             Project skill overrides
    │   └── deploy.md
    ├── sessions/           Per-task session directories
    │   └── TASK-20260519-2341/
    │       ├── plan.json       Approved execution plan
    │       ├── context.json    Context Store snapshot
    │       ├── spec.md         Architect's output
    │       ├── review.md       Reviewer's output
    │       ├── events.ndjson   Event stream (for resume)
    │       └── steps/
    │           ├── s1-output.md
    │           ├── s2-output.md
    │           └── s3-output.md
    └── learnings/          Pending learnings not yet absorbed
        └── 2026-05-19.md
```

---

## 4. Git Integration

### 4.1 Automatic commit on task complete

When a task reaches `complete` status, DevLoop creates a git commit:

```
feat: add social login button

Implemented via DevLoop TASK-20260519-2341.
Agents: claude/opus (design), copilot (implementation), claude/sonnet (review)

- Added SocialLogin component with GitHub OAuth flow
- Integrated with existing JWT token pipeline
- Added callback handler at /auth/github/callback
- 14 tests added (all passing)

Co-authored-by: claude/opus <claude@anthropic.com>
Co-authored-by: copilot <copilot@github.com>
Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
```

### 4.2 Branch strategy

By default, DevLoop works on the current branch. Optional per-task branching:

```toml
# .devloop/config.toml
[git]
auto_branch = true           # create a branch per task
branch_prefix = "devloop/"   # devloop/TASK-20260519-2341
auto_commit = true           # commit on complete
auto_push = false            # push to remote (opt-in)
```

### 4.3 Interrupted task recovery

If DevLoop is quit mid-task, the session state is snapshotted to SQLite.
On next launch, interrupted tasks appear in the sidebar with `~` status.
Resuming replays from the last completed step:

```
devloop resume TASK-20260519-2341
```

---

## 5. Config Format

### 5.1 Global config (`~/.devloop/config.toml`)

```toml
[devloop]
version = "6.0.0"

[ui]
theme = "dark"   # dark|light|auto

[routing]
max_cost_per_task_usd = 1.00
prefer_cheap = false

[backends]
default_main   = "claude"
default_worker = "copilot"

[git]
auto_commit  = true
auto_push    = false
auto_branch  = false

[skills]
# Global skills resolved from ~/.devloop/skills/
auto_detect = true   # auto-invoke matching skill for recognized task patterns
```

### 5.2 Project config (`.devloop/config.toml`)

```toml
[project]
name  = "myapp"
stack = ["React", "Node.js", "PostgreSQL"]

[routing]
# Override global: this project always uses opus for architecture
architect_model = "claude/opus"
coder_model     = "copilot"

[git]
auto_branch  = true
branch_prefix = "ai/"
auto_push    = true

[context]
# Files always included in context (relative to project root)
always_include = ["README.md", "ARCHITECTURE.md", "src/auth/"]
# Files never included
exclude = ["node_modules/", "dist/", ".env*"]
```
