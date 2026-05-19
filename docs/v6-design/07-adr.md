# DevLoop v6 — Architecture Decision Records

ADRs record significant decisions made during design, the options considered,
and the rationale. They are not changed after acceptance — new ADRs supersede old ones.

---

## ADR-001: Full Go Rewrite vs Incremental Bash Enhancement

**Status:** Accepted

**Context:**  
DevLoop v5 is 9,700+ lines of bash. The interactive streaming, parallel agent
panes, and Bubble Tea TUI require capabilities that bash cannot provide cleanly
(goroutines, bidirectional streaming, non-blocking UI event loop, typed data
structures). Previous attempts to add a Go TUI as a companion binary (v5.1.x)
showed the seam between Go TUI and bash engine is a source of bugs and complexity.

**Options considered:**

1. Continue extending bash + Go companion binary (v5 approach)
2. Rewrite core orchestrator in Go, keep bash for simple commands
3. Full Go rewrite — single binary

**Decision:**  
Full Go rewrite (Option 3).

**Rationale:**
- Interactive streaming with multiple concurrent agents is fundamentally
  a concurrency problem — Go's goroutines and channels are the right tool.
- A single binary eliminates the Go/bash seam (the source of "line 9712" class bugs).
- Bash's `set -euo pipefail` + empty arrays + bash 3.2 on macOS is a recurring
  source of subtle bugs that are hard to test. Go has none of these issues.
- DevLoop should be installable as a single binary download, not a bash script
  that requires the user to have bash 5+.
- The bash engine stays in the repo for reference and v5 compatibility
  (users who want the old behavior can still call the bash script directly).

---

## ADR-002: TUI Framework — Bubble Tea

**Status:** Accepted

**Context:**  
The v6 TUI needs: adaptive layouts, multiple panes, keyboard navigation,
real-time streaming content, and a chat-style input box.

**Options considered:**

1. Bubble Tea + Lip Gloss (Charmbracelet ecosystem)
2. tview (go-tview)
3. tcell (low-level)
4. Custom ncurses via cgo

**Decision:**  
Bubble Tea + Lip Gloss (Option 1).

**Rationale:**
- DevLoop v5.x already uses Bubble Tea for the companion TUI (`cmd/devloop-tui/`).
  The team has existing knowledge of the framework.
- Bubble Tea's Elm-style architecture (Model/Update/View) maps cleanly to
  DevLoop's event-driven design.
- Lip Gloss provides terminal-safe styling with automatic color capability
  detection (256-color, 16-color, no-color degradation).
- Active ecosystem with components for text input, spinners, progress bars,
  tables — reducing implementation time.
- Graceful TTY detection: when stdout is not a TTY, Bubble Tea doesn't render;
  DevLoop falls back to text output automatically.

---

## ADR-003: Agent Communication — Subprocess Streaming vs MCP

**Status:** Accepted

**Context:**  
DevLoop needs to communicate with Claude and Copilot. Two models exist:

1. **Subprocess streaming**: spawn the CLI as a child process, write to stdin,
   read stdout. This is how v5 works with `claude -p`.
2. **MCP (Model Context Protocol)**: Claude exposes tools via MCP; DevLoop acts
   as an MCP client or server.

**Decision:**  
Subprocess streaming for v6.0, with MCP as a future option for specific use cases.

**Rationale:**
- Subprocess streaming works with any CLI tool — Claude, Copilot, OpenCode, Pi.
  MCP is Claude-specific (in practice).
- The interactive mode we want (bidirectional streaming with a running Claude
  session) is exactly what `claude` without `--print` provides.
- MCP is valuable for Claude acting as a tool caller back into DevLoop (e.g.,
  "Claude calls `devloop.write_spec` as a tool"). This is captured as a Phase 4
  enhancement, not a Phase 1 requirement.
- MCP server implementation adds significant complexity to Phase 1 scope.

**Future:** In Phase 4, DevLoop may also expose itself as an MCP server so that
a Claude session can call DevLoop tools natively. This complements (not replaces)
the subprocess model.

---

## ADR-004: Storage — SQLite + Files + Git (All Three)

**Status:** Accepted

**Context:**  
Task history, context snapshots, learnings, and project registry need persistent
storage. Options: files only (v5 approach), database only, or all three.

**Decision:**  
All three layers — SQLite for queries, files for readability/portability,
git for history.

**Rationale:**
- **Files only** (v5 approach): not queryable. "What did we work on last week?"
  requires `grep` over markdown files. This is how v5 works and it's painful.
- **Database only**: specs and outputs as BLOBs in SQLite lose the human-readable,
  git-trackable, editor-openable nature of markdown files. Developers want to read
  their specs in their editor.
- **All three**: each layer serves its purpose:
  - SQLite answers structured queries ("which tasks are incomplete?", "cost this week")
  - Files are human-readable, can be version-controlled, opened in any editor
  - Git provides attribution, diffability, rollback — and it's already there

The sync overhead is low: SQLite is written first (source of truth for status),
files are written per step, git commit happens once at task completion.

---

## ADR-005: Agent Roles — Any Agent, Any Role

**Status:** Accepted

**Context:**  
DevLoop v5 hardcodes: Claude = architect + reviewer, Copilot = worker.
This works but wastes capability (Claude is also excellent at writing code;
Copilot is also useful for analysis).

**Decision:**  
Any backend can fill any persona role. DevLoop routes based on task signals,
model capability, and project config. No role is hardcoded to a backend.

**Rationale:**
- Claude's tool-using capability (Read, Edit, Bash) makes it excellent for
  writing code in many situations. Copilot's integration with the active editor
  makes it better for interactive editing. Both should be available for coding.
- As new backends are added (e.g., Gemini, local models), they should slot into
  any role without code changes.
- Cost optimization: haiku for simple analysis, opus only when depth is needed.
- The routing table is configurable and overridable — project teams can enforce
  their own routing rules.

**Constraint:** Copilot cannot currently be used as a reviewer because its
output format is conversational, not structured (no APPROVED/NEEDS_WORK
verdict). DevLoop will detect this and fall back to Claude for review steps.
This constraint is documented in the routing rules, not hard-coded.

---

## ADR-006: DevLoop Does Not Touch Claude/Copilot Native Configs

**Status:** Accepted

**Context:**  
DevLoop v5 writes to CLAUDE.md and `.github/copilot-instructions.md` during
`devloop init`. This means DevLoop's instructions appear in every Claude/Copilot
session, even when the developer is not using DevLoop.

**Decision:**  
DevLoop v6 manages all its configuration internally (`.devloop/config.toml`,
`~/.devloop/`). It injects its context at agent launch time via flags
(`--append-system-prompt`, `--system-prompt`, etc.) — not by writing to files
that Claude/Copilot read unconditionally.

**Rationale:**
- Developers use Claude and Copilot for non-DevLoop work. DevLoop instructions
  in CLAUDE.md pollute those sessions with irrelevant orchestration context.
- Separation of concerns: DevLoop's knowledge of the project is DevLoop's
  responsibility, not Claude's responsibility.
- This makes DevLoop removable: delete `.devloop/` and the agents are unaffected.

**Migration:** `devloop init` in v6 will offer to migrate existing CLAUDE.md
DevLoop blocks into `.devloop/config.toml` and remove them from CLAUDE.md.

---

## ADR-008: Named Persistent Sessions Per Project

**Status:** Accepted

**Context:**  
Every DevLoop v5 agent call spawns a fresh CLI process. The agent exits after
each response. No knowledge accumulates. Agents repeatedly re-read the codebase
and ask questions the user has already answered. The quality ceiling is low.

**Options considered:**

1. Keep ephemeral sessions (v5 approach) — simpler, always consistent
2. Session pool: reuse sessions within a single DevLoop run (already in Phase 1)
3. **Named persistent sessions per project**: give each role a stable session
   that survives across DevLoop restarts, accumulates project knowledge over time

**Decision:**  
Named persistent sessions per project (Option 3).

**Rationale:**
- Claude's `--session-id <uuid>` and `--resume <uuid>` flags make this directly
  implementable. DevLoop generates a deterministic UUID per `(project, role)`.
- A reviewer session that has reviewed 50 PRs for a project knows the team's
  conventions far better than a fresh session reading docs.
- Warm sessions (process still alive) have zero startup cost — messages go
  directly to the running process.
- Resumed sessions (process died, Claude's disk persistence) restart in 1-2s
  with full context intact — far better than cold start + context injection.
- Rolling context summarization handles context window limits without losing
  accumulated knowledge.

**Trade-offs accepted:**
- Sessions can become "stale" if codebase changes dramatically. `devloop session reset`
  handles this — user explicitly requests a fresh start when needed.
- Copilot doesn't have native session persistence. We inject compressed history
  on each invocation — partial benefit, not full benefit.
- Deterministic UUIDs mean two developers on the same project would have
  conflicting session IDs. Sessions are per-developer, per-machine — the UUID
  should incorporate a machine/user identifier. (Tracked as follow-up.)

---

## ADR-007: Autonomous Mode is Opt-In

**Status:** Accepted

**Context:**  
Should agents work fully autonomously (no user checkpoints) by default?
Or should the plan approval + mid-task interaction be the default?

**Decision:**  
Interactive by default. Autonomous mode is explicitly opt-in via `--auto` flag
or `DEVLOOP_AUTO=1` env var.

**Rationale:**
- The primary complaint about v5 is that it's *too* non-interactive. Making v6
  autonomous by default would repeat the same mistake.
- An agent that can ask mid-task questions produces significantly better output.
  Forcing it to guess (e.g., "which OAuth provider?") leads to rework.
- Autonomous mode has its place: CI, overnight batch runs, low-stakes tasks.
  But it should be the exception, not the default.
- Users who always want autonomous can set `DEVLOOP_AUTO=1` in their shell profile.
