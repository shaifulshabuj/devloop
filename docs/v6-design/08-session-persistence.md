# DevLoop v6 — Persistent Session Design

## 1. The Problem This Solves

In DevLoop v5 (and naive v6 without this design), every agent call starts cold:

```
Task 1: "add social login"
  → spawn Claude (cold start, 3s)
  → Claude reads codebase from scratch
  → Claude designs spec
  → process exits

Task 2: "add dark mode"
  → spawn Claude (cold start, 3s)   ← starts completely fresh
  → Claude reads codebase from scratch again ← wasted work
  → Claude has no memory of the OAuth decisions from Task 1
```

The agent never accumulates knowledge about your project. Every task starts
from zero. This caps quality — a reviewer with no memory of past reviews
will re-surface the same issues. An architect with no memory of previous
decisions will contradict them.

**The solution:** Named, persistent sessions per project. Each project has
a small set of long-running agent sessions, one per role. They accumulate
context and are reused across tasks.

---

## 2. Session Model

A **project session** is a named, persistent connection between a DevLoop
project and an agent backend for a specific role.

```
Project: myapp
Sessions:
  main        → claude/sonnet  session-uuid: 4a9f2b1c-...  status: idle
  architect   → claude/opus    session-uuid: 7d3e8a2f-...  status: idle
  reviewer    → claude/sonnet  session-uuid: 1b5c9d4e-...  status: idle
  coder       → copilot        session-uuid: n/a            status: idle
  tester      → claude/haiku   session-uuid: 9e2f7b3a-...  status: idle
```

Each session:
- Has a **stable UUID** generated from `project_id + role` (deterministic)
- Knows the project deeply — its stack, conventions, recent history
- Is resumed whenever a task needs that role
- Accumulates knowledge over time (rolling context)

---

## 3. Session Lifecycle

```
                        ┌─────────────────────────┐
                        │   Task needs "architect" │
                        └────────────┬────────────┘
                                     │
                    ┌────────────────▼──────────────────┐
                    │  Check sessions table              │
                    │  SELECT * FROM sessions            │
                    │  WHERE project_id=? AND role=?     │
                    └────┬──────────────────┬───────────┘
                         │                  │
              ┌──────────▼──────┐  ┌────────▼──────────────────┐
              │ No session yet  │  │ Session exists            │
              │ (first time)    │  │ status: idle/active       │
              └──────────┬──────┘  └────────┬──────────────────┘
                         │                  │
                         │         ┌────────▼────────────────────┐
                         │         │ Process still alive?        │
                         │         │ (ping via DEVLOOP_PING msg)  │
                         │         └───┬──────────────┬──────────┘
                         │             │              │
                         │          Alive           Dead
                         │             │              │
                         │    ┌────────▼──────┐  ┌───▼────────────────────┐
                         │    │  WARM start   │  │  RESUME start          │
                         │    │  Send new msg │  │  claude --resume <uuid>│
                         │    │  to existing  │  │  (Claude reloads       │
                         │    │  process      │  │   conversation history)│
                         │    └───────────────┘  └────────────────────────┘
                         │
              ┌───────────▼──────────────────────────────────────────┐
              │  COLD start                                          │
              │  Generate deterministic UUID for project+role        │
              │  claude --session-id <uuid>                          │
              │         --name "DevLoop: myapp/architect"            │
              │         --append-system-prompt "$project_context"   │
              │         --append-system-prompt "$persona_prompt"    │
              └──────────────────────────────────────────────────────┘
```

### Warm Start (fastest — 0 extra seconds)
Process is alive. DevLoop sends the new task instruction directly to stdin.
The agent already knows the project; no context injection needed.

### Resume Start (fast — 1-2 seconds)
Process died (DevLoop was restarted, computer slept, etc.) but Claude's
session was persisted to disk. `claude --resume <uuid>` reloads the
conversation. Claude remembers everything.

### Cold Start (slowest — 3-4 seconds + context injection)
No session exists. Spawn fresh. Inject:
1. Project context (stack, conventions, file tree summary)
2. Persona prompt (what this role does and how)
3. Context summary from previous sessions (if any — see §5)

---

## 4. Deterministic Session UUIDs

DevLoop generates stable UUIDs from `(project_id, role)` using UUID v5
(SHA-1 namespace hashing). This means:

- The architect session for "myapp" always has the same UUID
- DevLoop never needs to store "which UUID did we use?" — it recomputes it
- If the session is lost (new machine, cleared history), DevLoop cold-starts
  with the same UUID — Claude creates a new session with that ID

```go
import "github.com/google/uuid"

// Namespace UUID for DevLoop sessions
var devloopNS = uuid.MustParse("d3loop000-0000-0000-0000-000000000001")

func sessionUUID(projectID, role string) uuid.UUID {
    return uuid.NewSHA1(devloopNS, []byte(projectID+"/"+role))
}

// Example:
// sessionUUID("myapp", "architect")
// → always: "7d3e8a2f-4b1c-5a9d-8e2f-3b7c9a4d1e6f"
```

---

## 5. Rolling Context (Context Window Management)

Claude's context window is finite. A session that's been running for weeks
will eventually fill up. DevLoop manages this with a **rolling context** pattern:

```
Session message count approaches limit (e.g., 80% of context window)
    │
    ▼
DevLoop sends: "DEVLOOP_SUMMARIZE: Summarize everything you know about
this project and your work so far. Include: architecture decisions,
key files, patterns you've learned, recent work done, open questions."
    │
    ▼
Agent produces summary
    │
    ▼
DevLoop saves summary to sessions.context_summary in SQLite
    │
    ▼
DevLoop starts a NEW session (new UUID or fork)
New session receives:
  - Project context (always)
  - Persona prompt (always)
  - Previous session's context_summary (the accumulated knowledge)
    │
    ▼
Old session marked as "archived"
New session is now the active session for this role
```

The summary acts as "long-term memory" — the agent doesn't lose its
accumulated knowledge about the project when the context window fills.

---

## 6. Copilot Sessions

Copilot's CLI is more stateless than Claude's — it does not have a native
session persistence mechanism equivalent to Claude's `--resume`. For Copilot:

**Strategy: Context injection on each invocation**

```
First task (coder role):
  copilot --allow-all --name "DevLoop: myapp/coder"
  [inject]: project context + task spec
  [result]: code written, conversation stored as copilot_history.json

Subsequent tasks:
  copilot --allow-all
  [inject]: project context + task spec + recent_summary (from SQLite)
```

DevLoop stores the last N turns of Copilot conversation in SQLite and
prepends a compressed summary on each new session. Less seamless than
Claude's native resume, but preserves important project knowledge.

If Copilot adds native session persistence in a future version, DevLoop
will adopt it automatically via the backend plugin system.

---

## 7. Storage Schema (addition to 05-storage.md)

```sql
-- Named project sessions
CREATE TABLE sessions (
  id              TEXT PRIMARY KEY,  -- deterministic UUID (project_id + role)
  project_id      TEXT NOT NULL REFERENCES projects(id),
  role            TEXT NOT NULL,     -- "main", "architect", "reviewer", "coder", "tester", custom
  backend         TEXT NOT NULL,     -- "claude", "copilot"
  model           TEXT NOT NULL,     -- "claude-opus-4-7", etc.
  display_name    TEXT,              -- "DevLoop: myapp/architect"
  status          TEXT NOT NULL,     -- warm|idle|archived|dead
  process_pid     INTEGER,           -- PID if warm (process alive)
  context_summary TEXT,              -- rolling summary (from DEVLOOP_SUMMARIZE)
  message_count   INTEGER DEFAULT 0, -- total messages sent to this session
  token_count     INTEGER DEFAULT 0, -- estimated total tokens consumed
  last_used_at    INTEGER,
  created_at      INTEGER NOT NULL,

  UNIQUE(project_id, role)          -- one active session per project+role
);

-- Copilot conversation history (for context re-injection)
CREATE TABLE copilot_history (
  id          TEXT PRIMARY KEY,
  session_id  TEXT NOT NULL REFERENCES sessions(id),
  role        TEXT NOT NULL,   -- "user" | "assistant"
  content     TEXT NOT NULL,
  created_at  INTEGER NOT NULL
);
```

---

## 8. Session Commands (User Facing)

```
devloop sessions                   → list all sessions for current project
devloop sessions --all             → list sessions for all projects
devloop session reset <role>       → archive current session, force cold start
devloop session reset --all        → reset all project sessions
devloop session show <role>        → show session info + context summary
devloop session summarize <role>   → manually trigger context summarization
```

Example output of `devloop sessions`:

```
Sessions for: myapp
────────────────────────────────────────────────────────────
  main       claude/sonnet   warm    214 msgs   last: 2 min ago
  architect  claude/opus     idle    87 msgs    last: 3 hrs ago
  reviewer   claude/sonnet   idle    143 msgs   last: 1 hr ago
  coder      copilot         idle    312 msgs   last: 30 min ago
  tester     claude/haiku    idle    56 msgs    last: 2 hrs ago
────────────────────────────────────────────────────────────
  [r] reset a session   [s] show context summary   [q] back
```

---

## 9. Why This Matters — Concrete Examples

**Without persistent sessions (v5 / naive v6):**
```
Task: "fix the OAuth token expiry bug"
  Architect: "What OAuth flow are you using?" ← has to ask
  Coder: "What test framework do you use?" ← has to ask
  Reviewer: "You have a no-CASCADE-DELETE rule?" ← has to ask
```

**With persistent sessions (v6 with this design):**
```
Task: "fix the OAuth token expiry bug"
  Architect: "I see the GitHub OAuth flow I designed last week.
              The token expiry is handled in auth/handler.ts.
              Let me check the refresh token logic..." ← already knows
  Coder: "Writing fix in auth/handler.ts using vitest as usual..." ← already knows
  Reviewer: "Checking no-CASCADE-DELETE compliance (as always)..." ← already knows
```

The agents get smarter about your project over time. The first task on a
new project is slower (cold start, learning). By the 10th task, agents
are fast and precise — they know the codebase, conventions, and history.
