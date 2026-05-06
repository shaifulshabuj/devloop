---
title: "Agent Definitions"
category: entity
tags: [agents, orchestrator, architect, reviewer, claude-code]
created: 2026-05-06
---

# Agent Definitions

DevLoop installs three Claude Code agent definitions into `.claude/agents/` during `devloop init`. Each agent is a Markdown file with a YAML frontmatter block that controls its name, model, tools, and behavior prompt.

---

## devloop-orchestrator

**File:** `.claude/agents/devloop-orchestrator.md`  
**Model:** `sonnet`  
**Color:** cyan  
**Tools:** `Agent(devloop-architect, devloop-reviewer)`, `Bash`, `Read`, `Write`

The orchestrator is the **main thread**. It is the only agent the remote user communicates with directly. When `devloop start` or `devloop daemon` runs, Claude Code loads this agent as the entry point.

### Responsibilities

1. **Confirm** — echo back the user's request and state the plan in one line
2. **Design** — delegate to `@devloop-architect` with the feature description, type, and file hints; wait for the Task ID
3. **Implement** — run `devloop work TASK-ID`
4. **Review** — delegate to `@devloop-reviewer` with the Task ID
5. **Handle verdict** — approve, loop (up to 3x on `NEEDS_WORK`), or escalate rejection to user

### Delegation pattern to architect

```
@devloop-architect Design spec for: [feature]
Type: [feature|bugfix|refactor|test]
Files: [any file hints, or omit]
```

Expects back: Task ID + 2-sentence summary + key signatures.

### Phase indicators shown to user

| Symbol | Phase |
|--------|-------|
| 📐 | Designing spec… |
| 🤖 | Copilot implementing… |
| 🔍 | Reviewing implementation… |
| ✅ | Approved! |
| ⚠️ | Needs fixes — looping… |
| ❌ | Rejected |

### Error handling built in

| Error | Response |
|-------|----------|
| `devloop: not found` | Tell user: `sudo devloop install` |
| `copilot: not found` | Tell user: `gh extension install github/gh-copilot` |
| No git changes after `devloop work` | Ask user to confirm Copilot finished |

---

## devloop-architect

**File:** `.claude/agents/devloop-architect.md`  
**Model:** `opus`  
**Color:** blue  
**Tools:** `Bash`, `Read`, `Glob`, `Grep`

The architect is a **subagent** — invoked by the orchestrator via `@devloop-architect`. It never interacts with the remote user directly. It uses the stronger `opus` model because spec design requires nuanced reasoning about project context and implementation details.

### Responsibilities

1. Load project context (`devloop.config.sh`, `CLAUDE.md`)
2. Explore relevant files to understand existing patterns
3. Generate a spec via `devloop architect "[feature]" [type] "[file hints]"`
4. Return Task ID, 2-sentence summary, and key signatures to the orchestrator

### Spec requirements

The architect must produce specs that include:
- **Exact method signatures** with full types
- **Explicit business rules** — no ambiguity
- **All edge cases** enumerated
- **Test scenarios** in table format (input → expected)
- **Copilot Instructions Block** — a machine-readable block Copilot reads directly

The spec is saved to `.devloop/specs/TASK-YYYYMMDD-HHMM.md`. The Copilot Instructions Block is also extracted to `.devloop/prompts/TASK-ID-copilot.txt`.

### Why opus?

The architect's output quality directly determines whether Copilot implements the right thing. Vague specs produce wrong implementations that burn review cycles. The `opus` model cost is worth it at this stage.

---

## devloop-reviewer

**File:** `.claude/agents/devloop-reviewer.md`  
**Model:** `sonnet`  
**Color:** yellow  
**Tools:** `Bash`, `Read`, `Glob`, `Grep`

The reviewer is a **subagent** — invoked by the orchestrator via `@devloop-reviewer`. It measures Copilot's implementation against the original spec using git diff output. It never modifies files.

### Responsibilities

1. Load the spec via `devloop status TASK-ID`
2. Run `devloop review TASK-ID` to collect git changes
3. Return a structured verdict to the orchestrator

### Review criteria (priority order)

1. Spec compliance
2. Correctness / edge cases
3. Error handling
4. Code quality (SOLID)
5. Security
6. Test coverage

### Verdict rules

| Verdict | Conditions |
|---------|------------|
| `APPROVED` | All spec items done, no CRITICAL or HIGH severity issues, tests present |
| `NEEDS_WORK` | Fixable gaps — provides a `### Copilot Fix Instructions` block |
| `REJECTED` | Wrong approach, missing core logic, or security issue |

### Output format

```
### Verdict: APPROVED | NEEDS_WORK | REJECTED

**Score**: X/10
**Summary**: [one sentence]

### What's Good
- [specific positive]

### Issues Found
| # | Severity | File/Area | Issue |
|---|----------|-----------|-------|

### Required Fixes
**Fix 1**: description
[exact code]

### Copilot Fix Instructions
DEVLOOP REVIEW: TASK-ID
VERDICT: [verdict]
FIX #1:
  IN: [file/method]
  PROBLEM: [what's wrong]
  SOLUTION: [what to do]
```

### Edge case: no git changes

If no git changes are detected, the reviewer tells the orchestrator: "No git changes found — ask user to confirm Copilot finished." This prevents false APPROVED verdicts on no-op runs.

---

## Agent Lifecycle

```
devloop init          → writes all three agent .md files to .claude/agents/
devloop start/daemon  → loads orchestrator as main thread via --agent devloop-orchestrator
                        orchestrator invokes architect/reviewer as subagents on demand
```

The agent files are re-created from embedded templates each time `devloop init` runs (only if they don't already exist). To customize agent behavior — such as changing the model, adding tools, or modifying the prompt — edit the `.md` files directly in `.claude/agents/`.

## Customizing Agent Models

The model for each agent is set in its frontmatter:

```yaml
---
name: devloop-architect
model: opus        # change to sonnet to reduce cost
---
```

You can also control the model used in `claude -p` calls (architect and reviewer's shell invocations) via `devloop.config.sh`:

```bash
CLAUDE_MODEL="sonnet"   # or "opus"
```

See [Configuration Reference](../concepts/configuration.md) for all config options.
