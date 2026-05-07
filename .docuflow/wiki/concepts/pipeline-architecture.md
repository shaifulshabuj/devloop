---
title: "Core Pipeline & Architecture"
category: concept
tags: [architecture, pipeline, agents, orchestration, remote-control]
created: 2026-05-06
---

# Core Pipeline & Architecture

DevLoop is a shell-script orchestration layer that connects three AI agents into a self-correcting development loop. You send a feature request from your phone or browser; your Mac executes the full design → implement → review cycle automatically.

## Big Picture

```
You (mobile / browser — remotely via claude.ai/code or Claude app)
         │
         │  "add pagination to the orders endpoint"
         ▼
┌─────────────────────────────────────────────────────┐
│  Claude Code (main thread — your Mac)               │
│  Agent: devloop-orchestrator  (model: sonnet)       │
└──────────────┬──────────────────────────────────────┘
               │
     ┌─────────▼──────────┐
     │  @devloop-architect │  (subagent — model: opus)
     │  Designs spec       │
     └─────────┬──────────┘
               │  TASK-YYYYMMDD-HHMM.md
               │
     ┌─────────▼──────────┐
     │   copilot CLI       │  (external worker)
     │   devloop work ID   │  reads spec, runs /plan, implements
     └─────────┬──────────┘
               │  git diff
               │
     ┌─────────▼──────────┐
     │  @devloop-reviewer  │  (subagent — model: sonnet)
     │  Reviews vs. spec   │
     └─────────┬──────────┘
               │
         APPROVED ✅ ──────────────────── Done
               │
         NEEDS_WORK ⚠️  ── devloop fix ID ──► back to Copilot (max 3x)
               │
         REJECTED ❌  ─────────────────── Report to user
```

## Why Three Agents?

Each agent has a distinct role and model chosen for that role's requirements:

| Agent | Model | Responsibility |
|-------|-------|----------------|
| `devloop-orchestrator` | sonnet | Coordinates the loop — no heavy reasoning needed |
| `devloop-architect` | opus | Designs precise specs — worth the stronger model |
| `devloop-reviewer` | sonnet | Structured review output — sonnet handles this well |

The separation ensures the architect never sees Copilot's output (its spec is unbiased), the reviewer can measure compliance exactly (it has both spec and git diff), and the orchestrator is the single contact point for the remote user.

## The Full Loop in Detail

### Phase 1 — Confirm (Orchestrator)

The orchestrator echoes back its understanding of the request and states the plan in one sentence. This gives you a chance to correct misunderstandings before a spec is written.

### Phase 2 — Design (Architect → `devloop architect`)

The architect subagent:

1. Reads `devloop.config.sh` and `CLAUDE.md` to load project context
2. Explores relevant files for existing patterns
3. Generates a spec via `devloop architect "feature" type "file hints"`

The spec (`TASK-YYYYMMDD-HHMM.md`) contains:
- **Summary** — 2–3 sentences
- **Files to Touch** — table of files, actions, reasons
- **Implementation Steps** — exact method signatures + rules per step
- **Acceptance Criteria** — checklist
- **Edge Cases** — enumerated
- **Test Scenarios** — table of input/expected pairs
- **Copilot Instructions Block** — machine-readable block Copilot reads directly

### Phase 3 — Implement (Copilot CLI → `devloop work`)

Copilot CLI is launched with the Copilot Instructions Block pre-loaded in `/plan` mode:

```
/plan Implement the following DevLoop task:
[Copilot Instructions Block]
After planning, implement all steps. Run tests if possible. Summarize what was done.
```

### Phase 4 — Review (Reviewer → `devloop review`)

The reviewer:

1. Reads the original spec
2. Collects `git diff HEAD`, `git diff --cached`, and new untracked files
3. Scores the implementation against criteria (priority order):
   1. Spec compliance
   2. Correctness / edge cases
   3. Error handling
   4. Code quality (SOLID)
   5. Security
   6. Test coverage

Review saved to `.devloop/specs/TASK-ID-review.md`; spec status field updated.

### Phase 5 — Verdict & Loop

| Verdict | Condition | Orchestrator action |
|---------|-----------|---------------------|
| `APPROVED` | All spec items done, no CRITICAL/HIGH issues, tests present | Summarizes what was built. Done. |
| `NEEDS_WORK` | Fixable gaps — fix instructions provided | Runs `devloop fix TASK-ID`, re-delegates to reviewer. Up to 3 iterations. |
| `REJECTED` | Wrong approach, missing core logic, or security issue | Reports with reasons. Asks user if they want to restart. |

## Remote Control

DevLoop uses Claude Code's `--remote-control` flag:

```bash
claude \
  --remote-control "DevLoop: project-name" \
  --agent devloop-orchestrator \
  --permission-mode acceptEdits
```

Find the session in the **Claude app** → `"DevLoop: project-name"` with a green dot, or at **https://claude.ai/code** → session list.

`--permission-mode acceptEdits` lets the orchestrator write files and run shell commands without prompting — required for unattended operation.

## Session Modes

### Foreground (`devloop start`)
Runs in your terminal. Ctrl+C stops everything. `caffeinate -is` keeps Mac awake for the session duration.

### Background Daemon (`devloop daemon`)
Runs Claude in a detached background process. You can close the terminal. Features:
- **Auto-restart** on crash or connection drop (exponential backoff: 5s → 10s → … → 60s max, stops after 20 attempts)
- **caffeinate -is** restarted fresh on each attempt — survives wake from sleep
- **launchd agent** registered so DevLoop auto-starts on login/reboot (macOS); **systemd user service** on Linux
- All output logged to `.devloop/daemon.log`

## Worker Modes

### `cli` (default)

Worker runs via the local CLI tool. Copilot uses `gh copilot suggest`; Claude uses `claude -p`.

### `github-agent`

Worker creates a GitHub Issue containing the spec, and the Copilot cloud coding agent picks it up, opens a PR. DevLoop polls every 30 seconds (up to 20 minutes). When the PR appears, it auto-triggers `devloop review`.

```bash
DEVLOOP_WORKER_MODE="github-agent"
```

Requirements: `gh` CLI authenticated, Copilot coding agent enabled on the repo.

## Pipeline Hooks

`devloop hooks` installs four Claude Code hook scripts that auto-execute during every session:

| Hook | Event | Log |
|------|-------|-----|
| `devloop-stop.sh` | `Stop` | `.devloop/pipeline.log` |
| `devloop-subagent-stop.sh` | `SubagentStop` | `.devloop/pipeline.log` |
| `devloop-notification.sh` | `Notification` | `.devloop/notifications.log` |
| `devloop-session.sh` | `PreToolUse(Bash)` | `.devloop/sessions.log` |

## Self-Improvement Loop

`devloop learn` extracts lessons from reviews and prepends them to `CLAUDE.md` under `## Learned Patterns`. The architect and reviewer read these patterns in every subsequent session, making the pipeline progressively smarter.

`devloop check` + `DEVLOOP_VERSION_URL` keeps DevLoop itself up to date: a background version check runs on `devloop start` and hints when a new version is available.

## Tools Ecosystem (v3.1.0)

`devloop tools` manages the AI tool layer for both Claude and Copilot:

```
Global (user-wide)                  Project-level
────────────────────────────────    ────────────────────────────────
~/.claude.json (mcpServers)    →    .mcp.json (mcpServers)
~/.claude/skills/              →    .claude/skills/
~/.claude/settings.json            .claude/settings.json (hooks)
                                    .vscode/mcp.json (servers)
                                    .github/instructions/*.md
```

DevLoop writes both `.mcp.json` and `.vscode/mcp.json` in a single `devloop tools add --mcp` call, translating schema automatically (Claude uses `mcpServers`, VS Code uses `servers` + `type`).

## Data Flow & File Layout

```
your-project/
├── devloop.config.sh                         ← project context + provider routing
├── CLAUDE.md                                 ← Claude Code persistent context + learned patterns
├── .github/
│   ├── copilot-instructions.md               ← Copilot persistent context
│   ├── instructions/                         ← path-specific Copilot instructions
│   │   └── tests.instructions.md
│   └── workflows/
│       └── devloop-review.yml                ← CI (devloop ci)
├── .claude/
│   ├── agents/
│   │   ├── devloop-orchestrator.md
│   │   ├── devloop-architect.md
│   │   └── devloop-reviewer.md
│   ├── hooks/                                ← devloop hooks
│   │   ├── devloop-stop.sh
│   │   ├── devloop-subagent-stop.sh
│   │   ├── devloop-notification.sh
│   │   └── devloop-session.sh
│   ├── settings.json                         ← hook registrations
│   └── skills/                               ← project-level Claude skills
│       └── code-review/SKILL.md
├── .mcp.json                                 ← Claude MCP servers (mcpServers)
├── .vscode/
│   └── mcp.json                              ← VS Code/Copilot MCP servers (servers)
└── .devloop/
    ├── daemon.pid                            ← gitignored
    ├── daemon.log                            ← gitignored
    ├── pipeline.log                          ← hook-generated
    ├── notifications.log                     ← hook-generated
    ├── sessions.log                          ← hook-generated
    ├── specs/
    │   ├── TASK-20260504-0930.md             ← commit this
    │   └── TASK-20260504-0930-review.md      ← commit this
    └── prompts/
        └── TASK-20260504-0930-copilot.txt
```

## Key Invariants

- The architect generates specs via `claude -p` (print mode) — it does not modify files
- The reviewer also uses `claude -p` — it only reads git state, never applies fixes
- Only the worker (Copilot or Claude CLI) modifies source files (during `devloop work` and `devloop fix`)
- The orchestrator is the single contact point for the remote user
- `devloop tools add --mcp` always writes both `.mcp.json` and `.vscode/mcp.json`
