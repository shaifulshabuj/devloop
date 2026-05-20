# DevLoop v6 — System Architecture

## 1. High-Level Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        devloop (Go binary)                      │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                      TUI Layer (Bubble Tea)              │  │
│  │  Project sidebar │ Task view (chat + stream) │ Tabs/panes│  │
│  └─────────────────────────┬────────────────────────────────┘  │
│                             │ events                            │
│  ┌──────────────────────────▼────────────────────────────────┐  │
│  │                   Orchestrator Core                       │  │
│  │  Task manager · Plan engine · Agent router · Skill loader │  │
│  └──────┬──────────────────┬──────────────────┬─────────────┘  │
│         │                  │                  │                 │
│  ┌──────▼──────┐  ┌────────▼──────┐  ┌───────▼──────┐         │
│  │ Agent Pool  │  │ Context Store │  │ Storage      │         │
│  │ (sessions)  │  │ (per-task)    │  │ SQLite+files │         │
│  └──────┬──────┘  └───────────────┘  └──────────────┘         │
└─────────┼───────────────────────────────────────────────────────┘
          │ spawns / streams
    ┌─────┴──────────────────────────────────┐
    │           Agent Backends               │
    │  ┌─────────────┐  ┌─────────────────┐  │
    │  │ Claude CLI  │  │ Copilot CLI     │  │
    │  │ (any model) │  │ (gh copilot)    │  │
    │  └─────────────┘  └─────────────────┘  │
    │  ┌─────────────────────────────────┐   │
    │  │ OpenCode · Pi · API-direct      │   │
    │  └─────────────────────────────────┘   │
    └────────────────────────────────────────┘
```

---

## 2. Components

### 2.1 TUI Layer (`internal/tui/`)

The primary user interface. Built with [Bubble Tea](https://github.com/charmbracelet/bubbletea)
and Lip Gloss for styling.

**Responsibilities:**
- Render project sidebar (all registered projects)
- Show current task: chat input + agent streaming output
- Expand to split panes when parallel agents are running
- Tab navigation between multiple active tasks
- Receive events from Orchestrator Core and re-render
- Send user input (task descriptions, approvals, answers to agent questions)
  to Orchestrator Core

**Adaptive layout:**
```
Single agent running:          Two agents running:
┌────────┬───────────────┐    ┌────────┬───────┬───────┐
│Projects│  Task stream  │    │Projects│Agent A│Agent B│
│        │               │    │        │stream │stream │
│        │  [input box]  │    │        │       │       │
└────────┴───────────────┘    └────────┴───────┴───────┘

With tabs (multiple tasks):
┌────────┬──[Task 1]─[Task 2]─[Task 3]──────────────────┐
│Projects│  Active task view                             │
│        │  agent stream + input                        │
└────────┴──────────────────────────────────────────────┘
```

### 2.2 Orchestrator Core (`internal/orchestrator/`)

The decision engine. Receives task descriptions, builds plans, routes to agents.

**Responsibilities:**
- Receive task from TUI, analyze complexity and type
- Build an execution plan: which agents, what roles, what order, what model
- Present plan to user for approval (via TUI event)
- Dispatch approved sub-tasks to Agent Pool
- Collect agent outputs, update Context Store
- Handle agent questions: surface to user, wait for answer, relay back
- Detect completion, trigger storage writes, emit done event

**Plan structure:**
```json
{
  "task": "add CSV export to the reports page",
  "analysis": {
    "complexity": "medium",
    "type": "feature",
    "affected_areas": ["frontend", "api", "backend"]
  },
  "steps": [
    {"id": "s1", "role": "analyst",   "agent": "claude/sonnet", "desc": "analyze data model and report structure"},
    {"id": "s2", "role": "architect", "agent": "claude/opus",   "desc": "design CSV generation API + download endpoint", "depends_on": ["s1"]},
    {"id": "s3", "role": "coder",     "agent": "copilot",       "desc": "implement ExportButton component + backend handler", "depends_on": ["s2"]},
    {"id": "s4", "role": "reviewer",  "agent": "claude/sonnet", "desc": "review diff", "depends_on": ["s3"]}
  ]
}
```

### 2.3 Agent Pool (`internal/agent/`)

Manages persistent agent sessions. Each session is a long-running subprocess
with bidirectional streaming.

**Responsibilities:**
- Spawn agent processes (Claude CLI, Copilot CLI) with correct flags
- Maintain streaming connection (stdout reader goroutine)
- Write new input to agent stdin
- Detect agent questions (pattern matching on output) and emit events
- Recycle idle sessions (session reuse for same model/config)
- Enforce timeouts and handle crashes

**Session lifecycle:**
```
New task sub-step
    │
    ▼
Check pool: idle session with matching config?
    ├── Yes → send context delta + new instruction
    └── No  → spawn new process with full context
              claude --permission-mode acceptEdits \
                     --append-system-prompt "$context" \
                     --model "$model"
    │
    ▼
Stream output → TUI events
    │
    ▼
Detect completion marker → return result to Orchestrator
    │
    ▼
Session → idle pool (or close if at capacity)
```

### 2.4 Context Store (`internal/context/`)

Shared knowledge for all agents within a task session.

**Contents:**
- Project metadata (stack, patterns, conventions)
- Source file summaries (generated on task start, cached)
- Running summary of what each completed step produced
- User answers to mid-task questions
- Active spec (if one has been generated)

**Context is additive**: each step receives the full context + results of all
prior steps. Agents are never context-blind.

### 2.5 Storage (`internal/storage/`)

Three-layer persistence. See [05-storage.md](./05-storage.md) for full schema.

| Layer | Purpose |
|-------|---------|
| SQLite (`~/.devloop/devloop.db`) | Queryable index: projects, tasks, agents, history, learnings |
| Files (`.devloop/` in project) | Human-readable specs, outputs — portable, git-friendly |
| Git | Automatic commit when task completes (with agent attribution in message) |

### 2.6 Config System (`internal/config/`)

DevLoop owns its configuration. Does not touch Claude or Copilot native configs.

**Config hierarchy:**
```
~/.devloop/config.toml          Global config (default models, global skills)
<project>/.devloop/config.toml  Project config (overrides global, project skills)
<project>/.devloop/agents/      Project agent definitions (personas)
<project>/.devloop/skills/      Project skill overrides
```

---

## 3. Data Flow — "Add CSV export to the reports page"

```
1. User types "add CSV export to the reports page" in TUI input box
         │
2. TUI → Orchestrator: TaskRequest{description: "add CSV export to the reports page"}
         │
3. Orchestrator spawns quick analysis agent (claude/haiku):
   "Given this project context, classify this task and identify affected areas"
         │
4. Analysis result → Orchestrator builds Plan
         │
5. Orchestrator → TUI: PlanReady{steps: [...]}
   TUI shows plan, waits for user approval
         │
6. User approves → TUI → Orchestrator: PlanApproved{}
         │
7. Orchestrator dispatches Step 1 (analyst) to Agent Pool
   Agent Pool spawns/reuses claude/sonnet session
   Agent reads data model and report code, streams output to TUI
         │
8. Step 1 done → result stored in Context Store
         │
9. Orchestrator dispatches Step 2 (architect) with full context
   Agent designs CSV API, streams to TUI
   Agent asks: "Which columns should the export include?"
         │
10. Agent Pool detects question → Orchestrator → TUI: AgentQuestion{...}
    TUI shows question in input box, user types "all visible columns + row ID"
    TUI → Orchestrator → Agent Pool: answer relayed to agent stdin
         │
11. Agent continues, produces spec → Context Store
         │
12. Orchestrator dispatches Step 3 (coder) to Copilot session
    Copilot implements ExportButton + /api/reports/export endpoint, streams to TUI
         │
13. Step 3 done → Orchestrator dispatches Step 4 (reviewer)
         │
14. Review: APPROVED
    Orchestrator → Storage: write spec file, update SQLite, git commit
    Orchestrator → TUI: TaskComplete{}
    TUI shows summary, returns to idle state
```

---

## 4. Process Model

DevLoop runs as a **single foreground process** with internal goroutines:

```
main goroutine          → Bubble Tea event loop (TUI)
orchestrator goroutine  → plan/dispatch loop
agent goroutines        → one per active agent session (stdout reader)
storage goroutine       → async DB writes
```

No daemon. No PID files. No launchd. DevLoop starts when you run it, stops
when you quit (Ctrl+C or `q`). Tasks that were running are marked
`interrupted` in SQLite and can be resumed next launch.

---

## 5. External Interfaces

### 5.1 Agent CLI interfaces

| Backend | Launch command | Input | Output |
|---------|---------------|-------|--------|
| Claude  | `claude --permission-mode acceptEdits --model <m>` | stdin (interactive) | stdout stream |
| Copilot | `gh copilot suggest --target shell` or `copilot --allow-all` | stdin | stdout stream |

### 5.2 Event bus (internal)

All components communicate through a typed event channel:

```go
type Event interface{ eventType() string }

// Examples:
TaskRequested     { Description string }
PlanReady         { Plan Plan }
PlanApproved      {}
StepStarted       { StepID string; AgentID string }
AgentOutput       { StepID string; Chunk string }
AgentQuestion     { StepID string; Question string }
UserAnswer        { StepID string; Answer string }
StepComplete      { StepID string; Result string }
TaskComplete      { TaskID string; Summary string }
TaskInterrupted   { TaskID string; Reason string }
```

### 5.3 Project registry

```
~/.devloop/projects.toml

[[project]]
name = "myapp"
path = "/Users/me/code/myapp"
last_active = "2026-05-19T23:00:00Z"

[[project]]
name = "devloop"
path = "/Volumes/SATECHI_WD_BLACK_2/dev/devloop"
last_active = "2026-05-19T23:41:00Z"
```

Auto-registered when `devloop init` is run in a project directory.
