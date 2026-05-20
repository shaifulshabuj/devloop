# DevLoop v6 — Autonomous Implementation Agent Instructions

> **Hand this file to a Claude Code or GitHub Copilot Coding Agent as its starting instructions.**
> The agent should read this fully, then work through all 36 issues autonomously.

---

## Mission

You are an autonomous coding agent implementing **DevLoop v6** — a complete Go rewrite of the DevLoop
multi-agent development pipeline. Your goal is to implement all 36 GitHub issues in priority order,
using sub-agents for parallel work, and continue without stopping until every issue is closed and
the project builds and passes all tests.

**Repository:** `shaifulshabuj/devloop`
**Branch:** create and work on `feat/v6-implementation`
**Design docs:** `docs/v6-design/` (read these — they are your spec)
**GitHub Project:** https://github.com/users/shaifulshabuj/projects/6

---

## Environment Prerequisites

Before touching any code, verify these are available. If any are missing, install them first:

```bash
go version          # need Go 1.22+
golangci-lint --version
gh auth status      # must be authenticated
git --version
```

Install golangci-lint if missing:
```bash
brew install golangci-lint   # macOS
# or: go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest
```

---

## Startup Protocol (run once)

```bash
# 1. Clone / enter the repo
cd /path/to/devloop

# 2. Create the implementation branch
git checkout -b feat/v6-implementation

# 3. Read ALL design docs before writing any code
cat docs/v6-design/01-vision-and-goals.md
cat docs/v6-design/02-architecture.md
cat docs/v6-design/04-agent-system.md
cat docs/v6-design/06-build-phases.md
cat docs/v6-design/07-adr.md
cat docs/v6-design/08-session-persistence.md
```

---

## Issue Execution Order (Critical Path)

Work through issues in this exact sequence. Issues on the same "wave" can be parallelized
using sub-agents. Never start a wave until all issues in the previous wave are ✅.

### Wave 0 — Repository foundation (do this yourself, no sub-agents)
| Issue | Title | Notes |
|-------|-------|-------|
| #14 | Go project scaffold | Everything depends on this. Do it first, alone. |
| #49 | Developer setup guide | Can be done anytime after #14 |

### Wave 1 — Core subsystems (3 sub-agents in parallel after #14 merges)
| Issue | Title | Sub-agent |
|-------|-------|-----------|
| #15 | Config system | sub-agent A |
| #17 | SQLite storage layer | sub-agent B |
| #18 | Basic TUI shell | sub-agent C |

### Wave 2 — Agent layer (after Wave 1)
| Issue | Title | Sub-agent |
|-------|-------|-----------|
| #16 | Project registry + devloop init | sub-agent A (depends on #15) |
| #19 | Agent subprocess runner | sub-agent B (depends on #15) |
| #47 | Backend adapters (OpenCode + Pi) | sub-agent C (depends on #19) |

### Wave 3 — Context + CLI (after Wave 2)
| Issue | Title | Sub-agent |
|-------|-------|-----------|
| #20 | Context injection | sub-agent A (depends on #15, #19) |
| #21 | Phase 1 CLI commands | orchestrate yourself (depends on all Wave 1+2) |

### Wave 4 — Intelligence layer (Phase 2, after Wave 3)
| Issue | Title | Sub-agent |
|-------|-------|-----------|
| #22 | Orchestrator core | sub-agent A |
| #25 | Context Store | sub-agent B |
| #26 | Model router | sub-agent C |

### Wave 5 — Execution layer (after Wave 4)
| Issue | Title | Sub-agent |
|-------|-------|-----------|
| #23 | Plan generation + review UI | sub-agent A |
| #24 | Step dispatcher | sub-agent B |
| #27 | Agent question detection | sub-agent C |

### Wave 6 — Session + persistence (after Wave 5)
| Issue | Title | Sub-agent |
|-------|-------|-----------|
| #28 | Named session pool | sub-agent A |
| #29 | Git integration | sub-agent B |
| #48 | v5 compatibility bridge | sub-agent C |

### Wave 7 — Resume + Phase 2 CLI (after Wave 6)
| Issue | Title | Notes |
|-------|-------|-------|
| #30 | Task resume | depends on #24, #25, #28 |
| #31 | Phase 2 CLI commands | depends on #30, #13, #26 |

### Wave 8 — Platform layer (Phase 3, after Wave 7)
| Issue | Title | Sub-agent |
|-------|-------|-----------|
| #32 | Persona system | sub-agent A |
| #33 | Skill system | sub-agent B |
| #36 | Learning loop | sub-agent C |

### Wave 9 — Platform TUI (after Wave 8)
| Issue | Title | Sub-agent |
|-------|-------|-----------|
| #34 | Agent management TUI | sub-agent A |
| #35 | Skill management TUI | sub-agent B |
| #37 | TUI tabs (parallel tasks) | sub-agent C |

### Wave 10 — Platform CLI + Dashboard (after Wave 9)
| Issue | Title | Notes |
|-------|-------|-------|
| #38 | Project dashboard | depends on #25 (registry), #18 (TUI) |
| #39 | Phase 3 CLI commands | depends on #32–#38 |

### Wave 11 — Advanced layer (Phase 4, after Wave 10)
| Issue | Title | Sub-agent |
|-------|-------|-----------|
| #40 | Parallel step execution | sub-agent A |
| #42 | Autonomous mode | sub-agent B |
| #44 | Local API server | sub-agent C |

### Wave 12 — Advanced TUI + CLI (after Wave 11)
| Issue | Title | Sub-agent |
|-------|-------|-----------|
| #41 | Split-pane TUI | sub-agent A |
| #43 | Remote control | sub-agent B |
| #45 | Learning automation | sub-agent C |
| #46 | Cost tracking dashboard | sub-agent D |

---

## Per-Issue Workflow (follow this for every issue)

```
1. READ  → gh issue view <number> --repo shaifulshabuj/devloop
2. READ  → relevant design doc section (referenced in issue body)
3. PLAN  → write a brief implementation checklist (in your reasoning, not in a file)
4. CODE  → implement all acceptance criteria
5. TEST  → go test ./... (must pass)
6. LINT  → golangci-lint run ./... (must pass, warnings OK)
7. BUILD → make build (binary must compile)
8. COMMIT→ git add -A && git commit -m "feat(#<N>): <title>\n\nCo-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
9. CLOSE → gh issue close <number> --repo shaifulshabuj/devloop --comment "Implemented in feat/v6-implementation. All acceptance criteria met."
10. NEXT → move to the next issue in the wave sequence
```

---

## Sub-Agent Delegation Protocol

When a wave has multiple independent issues, spawn sub-agents like this:

```
To sub-agent working on issue #N:

You are implementing a single GitHub issue for DevLoop v6 (Go).
Repository: shaifulshabuj/devloop
Branch: feat/v6-implementation (already exists — checkout and pull before starting)

Issue to implement: #N — [title]
Full issue spec: run `gh issue view N --repo shaifulshabuj/devloop`
Design reference: docs/v6-design/<relevant-file>.md

Your job:
1. Read the issue and design docs carefully
2. Implement ALL acceptance criteria
3. Write unit tests for all behaviours listed
4. Run `go test ./...` — must pass
5. Run `golangci-lint run ./...` — must pass
6. Commit: feat(#N): <title> (include Co-authored-by trailer)
7. Close the issue with a comment confirming all criteria are met

Do NOT open PRs. Commit directly to feat/v6-implementation.
Do NOT implement features not in the issue spec.
Report back: DONE or FAILED with reason.
```

**Conflict avoidance:** Each issue should touch different packages. The wave ordering guarantees
this — issues in the same wave work in different `internal/` subdirectories.

---

## Go Package Layout

Each issue maps to one or more packages. Reference this to avoid conflicts:

```
cmd/devloop/          → #14 (scaffold), #21 (Phase 1 CLI), #31 (Phase 2 CLI), #39 (Phase 3 CLI)
internal/config/      → #15 (config), #16 (registry)
internal/storage/     → #17 (SQLite), #25 (Context Store), #46 (cost)
internal/tui/         → #18 (basic TUI), #23 (plan UI), #27 (question relay),
                         #34 (agent mgmt), #35 (skill mgmt), #37 (tabs),
                         #38 (dashboard), #41 (split-pane), #46 (cost widget)
internal/agent/       → #19 (runner), #20 (context injection), #28 (session pool),
                         #32 (personas), #33 (skills)
internal/agent/backends/ → #47 (OpenCode/Pi adapters)
internal/orchestrator/   → #22 (core), #24 (dispatcher), #26 (router),
                            #29 (git), #30 (resume), #36 (learner),
                            #40 (parallel), #42 (autonomous), #45 (automation)
internal/git/         → #29 (git integration)
internal/server/      → #44 (local API server)
```

---

## Quality Gates (mandatory before closing any issue)

```bash
# All must pass:
go build ./...
go test ./... -race -count=1
golangci-lint run ./...

# Verify the specific acceptance criteria in the issue body
# Every checkbox in "Acceptance Criteria" must be checked off
```

If tests fail: fix before closing. Do not close with failing tests.
If lint fails on *your* new code: fix. If it fails on pre-existing code: add a `//nolint` comment
with justification and note it in the issue close comment.

---

## Commit Message Format

```
feat(#<issue-number>): <issue title, lowercase>

- <what was implemented>
- <key design decisions>
- <any deviations from spec and why>

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
```

Example:
```
feat(#14): go project scaffold

- initialized go module github.com/shaifulshabuj/devloop
- added Bubble Tea, Cobra, go-sqlite3 dependencies
- Makefile with build/test/lint/install targets
- GitHub Actions CI on push

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
```

---

## Key Dependencies (Go modules)

Add these in Wave 0 (#14):

```go
// go.mod
require (
    github.com/charmbracelet/bubbletea  v0.26.0   // TUI framework
    github.com/charmbracelet/lipgloss   v0.10.0   // TUI styling
    github.com/charmbracelet/bubbles    v0.18.0   // TUI components
    github.com/spf13/cobra              v1.8.0    // CLI commands
    github.com/BurntSushi/toml          v1.3.2    // TOML config
    github.com/mattn/go-sqlite3         v1.14.22  // SQLite (CGO)
    github.com/google/uuid              v1.6.0    // UUID generation
    go.uber.org/zap                     v1.27.0   // Structured logging
)
```

---

## Autonomous Continuation Logic

After completing each issue, determine what to do next:

```
1. Check if current wave is complete:
   gh issue list --repo shaifulshabuj/devloop --label "phase/1-foundation" --state open

2. If wave is complete → start next wave (spawn sub-agents for parallel issues)

3. If wave has remaining open issues → wait (or investigate if a sub-agent failed)

4. After all 36 issues are closed:
   - Run full build: make build
   - Run full tests: go test ./... -race
   - Create PR: gh pr create --base main --head feat/v6-implementation
     --title "feat: DevLoop v6 — complete Go rewrite"
     --body "Closes #14, #15, #16, #17, #18, #19, #20, #21, #22, #23, #24, #25, #26, #27, #28, #29, #30, #31, #32, #33, #34, #35, #36, #37, #38, #39, #40, #41, #42, #43, #44, #45, #46, #47, #48, #49"
```

---

## Design Principles (from ADRs — follow these, do not deviate)

1. **Subprocess streaming** — agent communication is via `os/exec` + stdout streaming, NOT MCP/HTTP
2. **No auth required** — DevLoop itself needs no accounts; backends handle their own auth
3. **4 first-class backends** — Claude, Copilot (`gh copilot`), OpenCode, Pi — all equal priority
4. **Backend detection at startup** — silently skip missing binaries via `exec.LookPath`
5. **Named sessions** — deterministic session IDs from `SHA1(project+role+backend)`
6. **SQLite + JSONL** — SQLite for structured data, JSONL files for conversation history
7. **Single binary** — `make build` produces one `devloop` binary with all features
8. **Go 1.22+** — use modern Go: `range-over-int`, `slices`, `maps` stdlib packages

Full ADR context: `docs/v6-design/07-adr.md`

---

## Final Checklist (when all 36 issues are closed)

- [ ] `make build` succeeds producing `./devloop` binary
- [ ] `./devloop --version` prints `devloop v6.0.0`
- [ ] `go test ./... -race` passes with 0 failures
- [ ] `golangci-lint run ./...` passes
- [ ] All 36 GitHub issues are closed
- [ ] PR opened to merge `feat/v6-implementation` → `main`
- [ ] PR description links all 36 closed issues

---

*Generated by DevLoop v5 pipeline. Design docs: `docs/v6-design/`. GitHub Project: #6.*
