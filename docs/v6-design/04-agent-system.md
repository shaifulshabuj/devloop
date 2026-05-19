# DevLoop v6 — Agent System

## 1. Agent Model

In DevLoop v6, an **agent** is a combination of:

1. **Backend** — which CLI/API to use (Claude, Copilot, API-direct, etc.)
2. **Model** — which LLM within that backend (opus, sonnet, haiku, gpt-4, etc.)
3. **Persona** — what role it plays, what it knows, what tools it has
4. **Session** — a persistent, reusable subprocess connection

These are composable. `claude/opus + architect persona` and
`claude/haiku + analyst persona` are different agents using the same backend.

---

## 2. Backends

A backend is a CLI tool or API that DevLoop can launch and stream.

```toml
# ~/.devloop/config.toml

[[backend]]
id       = "claude"
binary   = "claude"
type     = "interactive-cli"
flags    = ["--permission-mode", "acceptEdits"]

[[backend]]
id       = "copilot"
binary   = "gh"
args     = ["copilot", "suggest"]
type     = "interactive-cli"

[[backend]]
id       = "claude-api"
type     = "api"
provider = "anthropic"
# API key from keychain or env ANTHROPIC_API_KEY
```

DevLoop ships with `claude` and `copilot` backends built-in. New backends can
be added via config without code changes.

---

## 3. Personas

A persona is a named role definition. It contains:

- A **system prompt** describing the role, constraints, and output format
- A list of **tools** the agent may use
- **Preferred models** (ordered — DevLoop picks the first available)
- **Context requirements** — what parts of the Context Store this persona reads

### 3.1 Built-in Personas

#### analyst
Reads existing code, identifies patterns, summarizes architecture.
- Preferred models: `claude/haiku`, `claude/sonnet`
- Context reads: project stack, file tree, recent git log
- Output: structured analysis (markdown)

#### architect
Designs specs, API contracts, database schemas.
- Preferred models: `claude/opus`, `claude/sonnet`
- Context reads: analysis output, project conventions, existing specs
- Output: task spec in DevLoop spec format

#### coder
Writes code from a spec.
- Preferred models: `copilot`, `claude/sonnet`, `claude/haiku`
- Context reads: task spec, affected file contents
- Output: code changes (applied directly via Edit tool)

#### reviewer
Reviews a git diff and decides APPROVED / NEEDS_WORK.
- Preferred models: `claude/sonnet`, `claude/opus`
- Context reads: task spec, git diff, project conventions
- Output: verdict + specific issues (if NEEDS_WORK)

#### debugger
Given an error or failing test, diagnoses and fixes.
- Preferred models: `claude/opus`, `claude/sonnet`
- Context reads: error output, relevant source files, recent changes
- Output: diagnosis + fix

#### tester
Writes tests for new or modified code.
- Preferred models: `copilot`, `claude/haiku`
- Context reads: implementation code, test framework conventions
- Output: test files

### 3.2 Custom Personas

Projects can define their own personas in `.devloop/agents/`:

```toml
# .devloop/agents/db-migrator.toml

[persona]
id          = "db-migrator"
description = "Writes and validates PostgreSQL migrations"
preferred_models = ["claude/sonnet", "copilot"]

system_prompt = """
You are a PostgreSQL migration specialist for this project.
This project uses Flyway for migrations. All migration files must:
- Follow naming: V{version}__{description}.sql
- Be idempotent (use IF NOT EXISTS, IF EXISTS)
- Include a rollback comment at the top
Never use CASCADE DELETE. Always prefer soft deletes.
"""

[persona.context]
reads = ["stack", "existing_migrations", "db_schema"]
```

### 3.3 Persona Improvement

Personas are versioned and can improve over time. When a reviewer finds issues,
DevLoop records them as **learnings** in SQLite. Periodically (or on demand with
`devloop learn`), learnings are summarized and appended to the relevant persona's
system prompt.

```
devloop learn --persona coder     # distill recent learnings into coder persona
devloop learn --all               # update all personas
```

---

## 4. Model Routing

DevLoop selects models automatically based on task characteristics:

### 4.1 Routing Rules (default)

| Task signal | Selected model |
|-------------|---------------|
| Quick analysis, classification | `claude/haiku` or `copilot` |
| Architecture, spec design | `claude/opus` |
| Code writing, implementation | `copilot` (first choice), `claude/sonnet` (fallback) |
| Code review | `claude/sonnet` |
| Debugging complex issues | `claude/opus` |
| Writing tests | `copilot`, `claude/haiku` |
| Complexity = "low" | downgrade one tier (opus→sonnet, sonnet→haiku) |
| Complexity = "high" | upgrade one tier (haiku→sonnet, sonnet→opus) |

### 4.2 Cost Awareness

DevLoop tracks estimated token cost per step and shows it in the plan. Users can
set a budget cap:

```toml
# .devloop/config.toml
[routing]
max_cost_per_task_usd = 0.50     # abort if estimated cost exceeds this
prefer_cheap          = false     # if true, always route to cheapest capable model
```

### 4.3 Availability Fallback

If the preferred model/backend is unavailable (rate limit, not installed):

```
claude/opus unavailable → try claude/sonnet → try copilot → error
```

Configured per persona in `preferred_models` list.

### 4.4 User Override

Always overridable:

```
devloop run "add social login" --agent claude/opus   # force specific model
devloop run "add social login" --persona architect   # force persona
```

---

## 5. Session Management

### 5.1 Session Reuse

Spawning a new Claude/Copilot process is expensive (2-4s startup). DevLoop
maintains an **idle session pool** and reuses sessions when the backend and
model match.

Context delta injection: when reusing a session, DevLoop sends a brief context
update message before the new instruction, so the agent understands what changed.

### 5.2 Session Persistence

Sessions are not persisted across DevLoop restarts (the CLI processes die when
DevLoop exits). However, the Context Store snapshot is saved to SQLite and
re-injected when a task is resumed.

### 5.3 Parallel Sessions

Multiple sub-tasks can run in parallel sessions simultaneously. Each gets its
own process and its own TUI pane. The Context Store is shared (read-only for
agents; write via Orchestrator).

---

## 6. Skills

Skills are reusable procedures — markdown files that teach an agent how to do
a specific recurring task.

### 6.1 Skill Resolution Order

```
.devloop/skills/<name>.md         (project-level, highest priority)
~/.devloop/skills/<name>/SKILL.md (global, lower priority)
```

### 6.2 Skill Invocation

Skills are automatically invoked when the Orchestrator recognizes a known
pattern, or explicitly:

```
devloop run "release the project"    # auto-invokes devloop-release-skill
devloop run "write a blog post"      # auto-invokes blog-posting-skill
devloop skill use release            # explicit invocation
```

### 6.3 Skill Management

```
devloop skill list               # show all available skills
devloop skill list --project     # show project-level skills only
devloop skill add <name>         # scaffold a new skill
devloop skill edit <name>        # open skill in $EDITOR
devloop skill learn <name>       # append learnings from recent tasks
devloop skill sync               # check for updates to built-in skills
```

---

## 7. Agent Interaction Protocol

When an agent is running, DevLoop monitors its output stream for structured
signals using lightweight pattern matching:

```
DEVLOOP_QUESTION: Which OAuth provider? [GitHub|Google|Both]
DEVLOOP_DECISION: I'll implement the GitHub flow first
DEVLOOP_DONE: Spec written to context
DEVLOOP_ERROR: Cannot find auth module — need more context
```

These are injected into the agent's system prompt as a convention. Agents
that don't support them (e.g., older Copilot versions) degrade gracefully —
DevLoop falls back to watching for natural-language completion signals.

Agents can also ask DevLoop to run a tool on their behalf:

```
DEVLOOP_TOOL: read_file src/auth/handler.ts
DEVLOOP_TOOL: run_tests npm test
DEVLOOP_TOOL: get_git_diff HEAD~1
```

This gives agents tool access without requiring full MCP setup — DevLoop acts
as a simple tool proxy.
