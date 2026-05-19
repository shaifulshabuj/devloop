# DevLoop v6 — Build Phases

## Overview

The rewrite is divided into 4 phases. Each phase is independently releasable
and adds value over the previous. Phase 1 alone is a significant improvement
over DevLoop v5.

```
Phase 1: Foundation       → working Go binary, basic TUI, interactive agents
Phase 2: Intelligence     → AI-driven planning, model routing, context sharing
Phase 3: Platform         → skills UI, persona management, project registry
Phase 4: Advanced         → parallel agents, learning loop, remote control
```

During the rewrite, DevLoop v5 (the bash script) remains installable and
usable. The Go binary is a new command, gradually superseding the bash engine.

---

## Phase 1 — Foundation

**Goal:** Replace the bash pipeline with a Go binary that launches interactive
agent sessions and streams their output to a basic TUI.

### Deliverables

- [ ] Go project scaffold (`cmd/devloop/`, `internal/`)
- [ ] Config loader (global + project `config.toml`)
- [ ] Project registry (`~/.devloop/projects.toml`)
- [ ] Basic TUI: project sidebar + single agent stream pane + input box
- [ ] Agent runner: spawn Claude/Copilot subprocess, stream stdout to TUI
- [ ] Context injection: prepend project stack/conventions to agent system prompt
- [ ] Storage: SQLite schema + migrations, task CRUD
- [ ] `devloop` (no args) → TUI opens with project list
- [ ] `devloop run "task"` → non-interactive fallback (v5 compatibility)

### CLI surface (Phase 1)

```
devloop                    → open TUI
devloop run "task"         → non-interactive (v5 mode)
devloop init               → register project, create .devloop/config.toml
devloop status             → show current/recent tasks (text)
devloop version            → show version
```

### Success criteria

User types a task in the TUI → Claude/Copilot session spawns → output streams
to the TUI in real time → user can send a message mid-task → task completes
and result is saved to SQLite.

---

## Phase 2 — Intelligence

**Goal:** The Orchestrator makes decisions. DevLoop analyzes tasks, builds
plans, routes to the right model, and shares context between steps.

### Deliverables

- [ ] Orchestrator Core: task analysis → plan generation
- [ ] Plan review UI: show plan, wait for approval, support edit
- [ ] Step dispatch: execute plan steps in sequence
- [ ] Context Store: shared in-memory store, persisted to `.devloop/sessions/`
- [ ] Model router: pick backend+model based on task type, complexity, cost
- [ ] Agent question detection: pattern match output, surface to TUI, relay answer
- [ ] Session pool: reuse idle sessions for same backend+model
- [ ] Git integration: auto-commit on task complete
- [ ] Resume: interrupted tasks → reload context → continue from last step

### CLI surface (Phase 2)

```
devloop resume [task-id]   → resume interrupted task
devloop history            → recent tasks (queryable)
devloop task <task-id>     → show task detail
```

### Success criteria

"Add CSV export to the reports page" → plan with 4 steps appears → user approves →
steps execute with correct model routing → agent asks mid-task question →
user answers → task completes → git commit created with attribution.

---

## Phase 3 — Platform

**Goal:** DevLoop manages agents, personas, and skills as first-class objects.
The TUI becomes the full platform UI.

### Deliverables

- [ ] Persona system: load `.toml` persona definitions, apply to agent sessions
- [ ] Skill system: global + project skills, auto-detection, `devloop skill` commands
- [ ] Agent management UI: list, create, edit, test personas from TUI
- [ ] Skill management UI: list, install, edit skills from TUI
- [ ] Learning loop: extract learnings from reviews, propose to personas
- [ ] TUI tabs: multiple simultaneous tasks
- [ ] Project dashboard: all projects visible, switch without `cd`
- [ ] `devloop learn` command: distill learnings into personas

### CLI surface (Phase 3)

```
devloop agent list         → list personas
devloop agent add          → scaffold new persona
devloop agent edit <name>  → edit persona
devloop skill list         → list skills
devloop skill add <name>   → scaffold skill
devloop skill learn <name> → append learnings to skill
devloop learn              → distill all pending learnings
```

### Success criteria

User creates a custom `db-migrator` persona from the TUI → assigns it to
"write migration for new users table" task → persona is used automatically
for database-related steps → learning from a failed migration is captured
and proposed for absorption into the persona.

---

## Phase 4 — Advanced

**Goal:** Parallel agents, full learning automation, remote control.

### Deliverables

- [ ] Parallel step execution: run independent steps concurrently
- [ ] Split-pane TUI: show multiple agent streams simultaneously
- [ ] Autonomous mode: `devloop run "task" --auto` with no interruptions
- [ ] Remote control: re-integrate `--remote-control` so tasks can be assigned
      from Claude.ai/code or GitHub mobile
- [ ] Webhook/API: optional local HTTP server for external task submission
- [ ] Learning automation: periodic background persona improvement
- [ ] Cost dashboard: per-project/per-task cost tracking in TUI

### CLI surface (Phase 4)

```
devloop start              → open TUI + enable remote control
devloop serve              → optional local API server (port 7331)
devloop costs              → cost breakdown
```

### Success criteria

User runs `devloop start` → two tasks are assigned (one from TUI, one from
Claude.ai mobile) → both run in parallel in split panes → user watches both
streams → both complete, both committed.

---

## Technical Milestones

| Milestone | Phase | Description |
|-----------|-------|-------------|
| M1 | 1 | First Go binary: `devloop` opens TUI, Claude streams to it |
| M2 | 1 | SQLite + project registry working |
| M3 | 2 | Orchestrator: plan → approve → execute → git commit |
| M4 | 2 | Context sharing across steps; session reuse |
| M5 | 3 | Persona + skill system fully functional |
| M6 | 3 | TUI tabs + project switcher |
| M7 | 4 | Parallel agents in split panes |
| M8 | 4 | Remote control + local API |

---

## Compatibility Bridge

During the transition period:
- DevLoop v5 bash script remains at `/usr/local/bin/devloop` (or v5)
- DevLoop v6 Go binary installs alongside as `/usr/local/bin/devloop6` initially
- Once Phase 2 is complete, v6 becomes the default `devloop` binary
- v5's `devloop run` (non-interactive) remains as a fallback mode in v6

---

## Repository Structure (Go)

```
devloop/
├── cmd/
│   └── devloop/
│       └── main.go
├── internal/
│   ├── tui/           Bubble Tea UI components
│   ├── orchestrator/  Task analysis, plan generation, dispatch
│   ├── agent/         Agent session pool, streaming
│   ├── context/       Context Store
│   ├── storage/       SQLite + file I/O
│   ├── config/        Config loading (global + project)
│   ├── persona/       Persona definitions and loading
│   ├── skill/         Skill resolution and invocation
│   ├── router/        Model routing logic
│   └── git/           Git operations
├── docs/
│   └── v6-design/     This directory
├── devloop.sh          v5 bash engine (kept for reference + compat)
├── go.mod
├── go.sum
└── Makefile
```
