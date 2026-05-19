# DevLoop v6 — Vision & Goals

## 1. Problem Statement

DevLoop v5.x solved a real problem — wiring Claude and Copilot together into a
pipeline — but the solution has fundamental architectural limits:

### 1.1 The Three Core Problems

**Non-interactive agents**  
Every agent call uses `claude -p` (print mode) or equivalent. The agent exits
after each response. There is no persistent session, no tool use across turns,
no ability for the agent to ask follow-up questions mid-task. This caps the
quality of work the agent can do.

**No shared context**  
Each pipeline phase (architect → worker → reviewer) is a fresh CLI process.
Context accumulated during analysis is lost when the next phase starts. The
architect's understanding of the codebase is not passed to the worker. The
reviewer has no memory of why a design decision was made.

**Rigid, script-driven pipeline**  
DevLoop v5 is the "brain" — it decides the flow (always: architect → work →
review → fix). Real development is not this linear. Some tasks need codebase
analysis first. Some skip design entirely. Some need multiple reviewers. The AI
should decide the workflow, not a bash script.

**DevLoop is non-interactive**  
The tool itself has no live UI. Output scrolls past. There is no way to steer
an agent mid-task, approve a partial plan, or watch two agents work in parallel.
The only interaction model is: wait for the pipeline to finish, then read a file.

### 1.2 Secondary Problems

- Claude/Copilot configs scattered across CLAUDE.md, copilot-instructions.md,
  devloop.config.sh — no single source of truth
- No project registry — must `cd` to the right directory before doing anything
- Skills and agent definitions siloed in `~/.copilot/skills/` with no management UI
- Sessions/history spread across `.devloop/specs/` with no queryable index

---

## 2. Vision

> **DevLoop v6 is a standalone AI development platform — a single Go binary that
> owns its UI, projects, agents, skills, and history. Claude and Copilot are
> engines. DevLoop is the cockpit.**

The experience: you run `devloop`, a TUI opens, you describe what you want in
plain language, DevLoop and its agents figure out how to build it, you watch
and steer. The AI decides the workflow. You decide when to approve, redirect,
or stop.

---

## 3. Design Goals

### G1 — Interactive by default
Every agent session is a persistent, streaming, interactive connection. Agents
can ask questions. Users can respond. No session resets between phases.

### G2 — AI-driven workflow
DevLoop proposes a plan (which agents, what tasks, in what order), the user
approves, agents execute. The AI decides whether to analyze first, design, code,
test, or review — based on the task, not a hardcoded script.

### G3 — Single platform, independent of Claude/Copilot native settings
DevLoop manages its own agent configs. Claude and Copilot remain usable
independently — DevLoop does not touch CLAUDE.md or copilot-instructions.md
unless explicitly asked. DevLoop injects its context at launch time.

### G4 — Any agent, any role
Claude, Copilot, or any future LLM can play any role (architect, coder,
reviewer, debugger). DevLoop routes tasks based on:
- Task type and complexity
- Model capability and cost
- Project-defined preferences
- Availability

### G5 — Live, steerable UI
The TUI is the primary interface. Agents stream output in real time. Users can
intervene mid-task. Multiple agents appear in parallel panes. Tasks are tabbed.

### G6 — Queryable history
All tasks, decisions, agent outputs, and learnings are stored in SQLite.
Files remain for portability. Git records history. All three are synchronized.

### G7 — Hybrid project model
`devloop` from any directory shows the global dashboard with all registered
projects. `cd my-project && devloop` scopes the session to that project.

### G8 — Skills: global + project-level
Global skills (available in all projects) and project-level skills (override
globals for this project). Skills are versioned and improvable.

---

## 4. Non-Goals (v6.0)

- **Not a code editor** — DevLoop does not replace VS Code, Zed, or Neovim.
  It orchestrates agents; you use your own editor for manual changes.
- **Not a CI/CD system** — DevLoop is a development tool, not a deployment
  pipeline. It can run tests, but not manage production deploys.
- **Not an LLM provider** — DevLoop uses existing Claude, Copilot, or API-key
  models. It does not host or fine-tune models.
- **Not a cloud service** — v6.0 is a local binary. Remote control (the
  DevLoop start → claude.ai/code mobile pattern) is a future capability.
- **Not backward-incompatible by design** — The `.devloop/` directory format
  will be evolved carefully; existing specs and sessions should remain readable.

---

## 5. Success Criteria

DevLoop v6.0 is successful when:

1. A developer can type `devloop` and have a TUI open within 200ms.
2. "Add social login button" → plan appears → approved → agents work → PR-ready
   commit, with no manual copy-pasting between CLI tools.
3. Two agents can work in parallel on separate sub-tasks, visible simultaneously.
4. An agent can ask "which OAuth provider?" mid-task and wait for the answer.
5. All task history is queryable: "what did we build last week?" returns results.
6. `claude` and `gh copilot` continue working exactly as before (no breakage).
