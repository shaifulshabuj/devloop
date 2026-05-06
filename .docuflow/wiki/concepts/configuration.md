---
title: "Configuration Reference"
category: concept
tags: [configuration, devloop.config.sh, settings, model, stack]
created: 2026-05-06
---

# Configuration Reference

DevLoop project configuration lives in `devloop.config.sh` at the project root. This file is sourced as a shell script at the start of every command that needs project context.

---

## devloop.config.sh

Created by `devloop init` with sensible defaults. Edit it before running `devloop start` for the first time.

### Full example

```bash
# DevLoop Project Configuration — edit to match your stack

PROJECT_NAME="$(basename "$PWD")"
PROJECT_STACK="C#, .NET 8, ASP.NET Web API, MSSQL"
PROJECT_PATTERNS="SOLID, Repository Pattern, Clean Architecture"
PROJECT_CONVENTIONS="async/await throughout, custom exception classes, no magic strings, XML doc comments on public APIs"
TEST_FRAMEWORK="xUnit"

# Model for architect/reviewer calls via claude -p
# "sonnet" = faster/cheaper   "opus" = more capable
CLAUDE_MODEL="sonnet"
```

---

### `PROJECT_NAME`

**Type:** string  
**Default:** `"$(basename "$PWD")"` (current directory name)

The session name shown in the Claude app and at https://claude.ai/code. Appears as `"DevLoop: PROJECT_NAME"`.

```bash
PROJECT_NAME="Avail OMS"
```

---

### `PROJECT_STACK`

**Type:** string  
**Default:** `"C#, .NET 8, ASP.NET Web API, MSSQL"`

Injected into every `claude -p` prompt sent to the architect and reviewer. Be specific — this is the primary signal Claude uses to generate stack-appropriate code.

```bash
PROJECT_STACK="TypeScript, Node.js 20, Express, PostgreSQL, Prisma"
PROJECT_STACK="Python 3.12, FastAPI, SQLAlchemy, Redis"
PROJECT_STACK="Go 1.22, Gin, PostgreSQL, Docker"
```

---

### `PROJECT_PATTERNS`

**Type:** string  
**Default:** `"SOLID, Repository Pattern, Clean Architecture"`

Architectural patterns the architect should follow when designing specs. Listed in the prompt so the architect enforces them in generated specs.

```bash
PROJECT_PATTERNS="SOLID, Hexagonal Architecture, CQRS, Event Sourcing"
PROJECT_PATTERNS="MVC, Repository Pattern, Unit of Work"
PROJECT_PATTERNS="Microservices, Domain-Driven Design, Saga Pattern"
```

---

### `PROJECT_CONVENTIONS`

**Type:** string  
**Default:** `"async/await throughout, custom exception classes, no magic strings, XML doc comments on public APIs"`

Coding conventions the architect must encode into specs and the reviewer must check for. Be explicit — vague conventions produce inconsistent implementations.

```bash
# Good — specific and checkable
PROJECT_CONVENTIONS="async/await throughout, Result<T> return type (no exceptions for business errors), snake_case DB columns, JSDoc on all exported functions"

# Too vague — architect cannot enforce these
PROJECT_CONVENTIONS="write good code, follow best practices"
```

---

### `TEST_FRAMEWORK`

**Type:** string  
**Default:** `"xUnit"`

Test framework injected into the spec prompt. The architect includes this in the Copilot Instructions Block so Copilot generates tests using the correct framework.

```bash
TEST_FRAMEWORK="xUnit"
TEST_FRAMEWORK="Jest"
TEST_FRAMEWORK="pytest"
TEST_FRAMEWORK="Go testing"
TEST_FRAMEWORK="RSpec"
```

Set to `"none"` or leave as default if your project has no test framework yet — the architect will still include test scenarios in table format even if Copilot cannot run them.

---

### `CLAUDE_MODEL`

**Type:** `"sonnet"` | `"opus"`  
**Default:** `"sonnet"`

Controls the model used in `claude -p` shell calls made by `devloop architect` and `devloop review`. This is separate from the model set in each agent's `.md` frontmatter (which controls the Claude Code subagent calls).

```bash
CLAUDE_MODEL="sonnet"   # faster, cheaper — fine for most features
CLAUDE_MODEL="opus"     # more capable — use for complex architecture tasks
```

**Cost guidance:**
- Use `sonnet` for routine feature work
- Switch to `opus` only for complex tasks (DDD refactors, security-sensitive APIs, multi-service changes)
- The architect agent frontmatter already uses `opus` by default for the subagent invocation — `CLAUDE_MODEL` only affects the `claude -p` shell calls

---

## Internal Variables (read-only)

These are set by `devloop` itself after loading config. Do not set them in `devloop.config.sh`.

| Variable | Value | Purpose |
|----------|-------|---------|
| `DEVLOOP_DIR` | `.devloop` | Root of devloop's working directory |
| `SPECS_DIR` | `.devloop/specs` | Task spec storage |
| `PROMPTS_DIR` | `.devloop/prompts` | Copilot instruction block storage |
| `AGENTS_DIR` | `.claude/agents` | Agent definition files |
| `CONFIG_FILE` | `devloop.config.sh` | Config file name |
| `VERSION` | `2.0.0` | Script version |

---

## Multiple Projects

Each project has its own `devloop.config.sh`. Running `devloop daemon` in each project directory creates separate launchd agents with unique labels:

```
com.devloop.avail_oms.plist
com.devloop.myapi.plist
```

So multiple projects can run simultaneously on the same Mac.

---

## Per-Agent Model Override

To override the model for a specific agent independent of `CLAUDE_MODEL`, edit the agent's `.md` file directly:

```bash
# Change the architect to sonnet to reduce cost
nano .claude/agents/devloop-architect.md
# Edit: model: sonnet
```

Changes take effect on the next `devloop start` or `devloop daemon` session.

---

## .github/copilot-instructions.md

Also created by `devloop init`. Not a devloop config file, but Copilot reads it for persistent instructions in every session.

Key directives it sets for Copilot:
- Read the task spec and Copilot Instructions Block carefully
- Use `/plan` to create an implementation checklist
- Implement each step in order
- Run tests if the framework is available
- Summarize what was implemented
- Never skip error handling
- Commit with a descriptive message when done

You can extend this file with project-specific Copilot guidance (e.g. "always use the Result pattern", "never import lodash").
