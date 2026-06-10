# DocuFlow — AI Documentation Assistant

DocuFlow is an MCP server that gives you structured access to this codebase and maintains a living wiki.
It is registered in your Claude Desktop config and available as MCP tools in every session.

## Codebase Scanner Tools

- **read_module** — Analyse a single source file. Returns language, classes, functions, dependencies, DB tables, endpoints, config refs, and raw content (first 8 KB).
  - Example: `read_module({ path: "src/UserService.cs" })`
- **list_modules** — Walk a directory and extract facts for every non-binary file. Use this to understand the full project in one call.
  - Example: `list_modules({ path: "/Volumes/SATECHI_WD_BLACK_2/dev/devloop" })`
- **write_spec** — Persist a markdown spec to `.docuflow/specs/<filename>.md` and update the index.
  - Example: `write_spec({ project_path: "/Volumes/SATECHI_WD_BLACK_2/dev/devloop", filename: "UserService", content: "# UserService\n..." })`
- **read_specs** — Read previously written specs, optionally filtered by name.
  - Example: `read_specs({ project_path: "/Volumes/SATECHI_WD_BLACK_2/dev/devloop" })`

## Wiki Pipeline Tools

- **ingest_source** — Ingest a markdown file from `.docuflow/sources/` and generate wiki pages (entities, concepts).
- **update_index** — Rebuild `.docuflow/index.md` from all wiki pages.
- **list_wiki** — List all wiki pages, optionally filtered by category (entity/concept/timeline/synthesis).
- **wiki_search** — BM25 search across all wiki pages. Returns ranked results with previews.
- **query_wiki** — One-stop Q&A: searches wiki, synthesises an answer, returns source citations.
- **synthesize_answer** — Generate a markdown synthesis from a list of specific wiki page IDs.
- **save_answer_as_page** — Persist a synthesised answer back into the wiki (knowledge compounding).

## Health & Guidance Tools

- **lint_wiki** — Health check: orphan pages, broken refs, stale content, metadata gaps. Returns a 0–100 health score.
- **get_schema_guidance** — Analyse what wiki pages should exist based on the schema and current state.
- **preview_generation** — Preview what a tool will do before running it.

## Common Workflows

### First time — understand the codebase
```
list_modules({ path: "/Volumes/SATECHI_WD_BLACK_2/dev/devloop" })
→ read the language breakdown and dependency map
→ write_spec each important module
```

### Ongoing — answer a question
```
query_wiki({ project_path: "/Volumes/SATECHI_WD_BLACK_2/dev/devloop", question: "How does authentication work?" })
→ save_answer_as_page if the answer is worth keeping
```

### Maintenance — check wiki health
```
lint_wiki({ project_path: "/Volumes/SATECHI_WD_BLACK_2/dev/devloop" })
→ fix orphans and broken refs
```

## Storage Layout

```
.docuflow/
├── specs/           Legacy spec files written by write_spec
├── wiki/            LLM-generated wiki pages
│   ├── entities/    Named things (services, APIs, databases)
│   ├── concepts/    Design patterns, principles, integrations
│   ├── timelines/   Chronological pages
│   └── syntheses/   Cross-cutting synthesis pages
├── sources/         Raw input files for ingest_source
├── schema.md        Wiki configuration (edit to customise)
├── index.md         Auto-maintained catalog
└── log.md           Operation log
```

## Agent Provider Context
_See `.devloop/agent-docs/provider-context.md` for the full provider reference._
_Run `devloop agent-sync` to refresh docs and check for provider updates._


<!-- DEVLOOP:CLAUDE:START -->
# Claude Code — DevLoop Project

## Session history — read on demand

Substantial past work is summarised under [`docs/session-history/`](./docs/session-history/).
Each entry is a single-file record of what was attempted, what shipped,
what was decided, and what was deferred.

**When to consult**:
- The user asks about prior work ("what did we do last session?", "why is X
  the way it is?")
- You encounter a file or pattern that looks unfamiliar — check the latest
  entry first; it may explain why
- Picking up an in-flight effort (open issues / PRs / deferred follow-ups)

**Latest entry**: [`docs/session-history/2026-05-22-tui-v5.3-release.md`](./docs/session-history/2026-05-22-tui-v5.3-release.md)
— TUI Redesign v5.3 shipped (Phases 1–4, 24 commits, full doc pass, MCP
cleanup, v5.3.0 + v5.3.0-rc.1 released).

Do NOT pre-load these on every session — read on demand only.

## System
This project uses the DevLoop multi-agent pipeline:
- `devloop-orchestrator` — main thread, receives remote instructions
- `devloop-architect`    — subagent, designs implementation specs
- `devloop-reviewer`     — subagent, reviews the worker's implementation
- Worker — implements specs (CLI or cloud Copilot coding agent)
- Provider routing and worker mode are controlled in `devloop.config.sh`

## Start the system
```bash
devloop start
```
Then connect from claude.ai/code or the Claude mobile app (when main provider is claude).
If main provider is copilot, the session runs locally in the terminal.

## DevLoop commands — Quick (full pipeline in one shot)
- `devloop run "feature"`       — **full pipeline**: architect → work → review → fix loop → learn
- `devloop go  "feature"`       — alias for run
- `devloop queue add "task"`    — add to batch queue
- `devloop queue run`           — process all queued tasks sequentially

## DevLoop commands — Step-by-step
- `devloop architect "feature"` — design a spec
- `devloop work [TASK-ID]`      — launch worker to implement
- `devloop review [TASK-ID]`    — review implementation
- `devloop fix [TASK-ID]`       — launch worker with fix instructions

## DevLoop commands — Management
- `devloop tasks`               — list all specs
- `devloop status [TASK-ID]`    — show spec + review
- `devloop open [TASK-ID]`      — open spec in $EDITOR
- `devloop block [TASK-ID]`     — print Copilot Instructions Block
- `devloop clean [--days N]`    — remove old specs
- `devloop learn [TASK-ID]`     — extract lessons from review and save to CLAUDE.md
- `devloop agent-sync`          — refresh provider docs cache + analyse with AI (24h TTL)
- `devloop hooks`               — install Claude pipeline hooks
- `devloop logs [TYPE]`         — show pipeline/notification/session logs
- `devloop doctor`              — validate dependencies and configuration
- `devloop ci`                  — generate GitHub Actions review workflow
- `devloop check`               — check for DevLoop updates (works out-of-the-box)
- `devloop update`              — self-upgrade devloop (pulls from GitHub, refreshes project configs)

## Agent Provider Context
_See `.devloop/agent-docs/provider-context.md` for the full provider reference._
_Run `devloop agent-sync` to refresh docs and check for provider updates._

## Stack
See devloop.config.sh for project-specific stack details.

## TUI — `cmd/devloop-tui` (shipped v5.3)

A Go TUI (Bubble Tea + Lipgloss) sits beside the bash engine, watching the
same `.devloop/` directory it reads and writes. CLI behaviour is unchanged;
the TUI is opt-in.

### Package layout

```
cmd/devloop-tui/
├── main.go                            ← subcommand dispatch
└── internal/
    ├── theme/      colors.go          ← single source of truth for colour
    ├── health/     health.go          ← parses provider-health.sh
    ├── permit/     permit.go          ← parses permission-queue UUIDs
    ├── uimsg/      uimsg.go           ← cross-package tea.Msg (no cycles)
    ├── stream/     events, tailer, session_scan   (DO NOT MODIFY — stable)
    ├── components/ filter, panel, palette, task_picker, pipeline_grid
    ├── views/      dashboard, focus, chat, run, onboard
    └── app/        app.go              ← root router + palette overlay
```

### Hard reuse rules (enforced by review)

- Subprocess execution flows through `chat.dispatchShell` — no new
  `exec.Command` paths in view code.
- NDJSON events come via `stream.Tailer` — no ad-hoc re-reads of
  `events.ndjson`.
- All colours via `theme.*`. Zero raw `lipgloss.Color("…")` literals
  outside the theme package.
- Cross-package messages live in `internal/uimsg` so `app` can route them
  without creating an import cycle with `views`.

### Key files agents will touch

| File | Purpose |
|------|---------|
| `internal/views/dashboard.go` | Split pane + top bar + SPEC/DIFF panels |
| `internal/views/focus.go` | Single-task view with LOG/SPEC/DIFF/PERMIT tabs |
| `internal/views/onboard.go` | First-run wizard (init + doctor) |
| `internal/components/palette.go` | Command palette with 18 default actions |
| `internal/app/app.go` | Router; intercepts `space`, OpenFocus, CloseFocus, PaletteRun |

### File paths the TUI consumes (read-only, written by `devloop.sh`)

| Path | Used by |
|------|---------|
| `.devloop/events.ndjson` | Live event stream (dashboard, focus) |
| `.devloop/sessions/<TASK-ID>/events.ndjson` | Per-session events |
| `.devloop/sessions/<TASK-ID>/status` | Gate-timeout detection |
| `.devloop/specs/<TASK-ID>.md` | SPEC panel content |
| `.devloop/specs/<TASK-ID>.pre-commit` | DIFF panel baseline hash |
| `.devloop/permission-queue/<UUID>.json` | Permit queue items |
| `.devloop/provider-health.sh` | Provider failover snapshot |
| `.devloop/daemon.pid`, `daemon.log` | Daemon liveness + restart count |

→ Full TUI reference: [README — TUI section](./README.md#tui--devloop-tui)
→ TUI deep dive: [cmd/devloop-tui/README.md](./cmd/devloop-tui/README.md)

## Learned Patterns
<!-- devloop learn appends dated lessons here -->
<!-- DEVLOOP:CLAUDE:END -->
