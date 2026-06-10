# DevLoop TUI — Redesign Brief

> ## ✅ Status — Shipped in v5.3.0 (2026-05-22)
>
> All four phases of this redesign are complete and merged to `main`.
> See [`CHANGELOG.md`](../CHANGELOG.md) for the full release notes and
> [`cmd/devloop-tui/README.md`](../cmd/devloop-tui/README.md) for the
> live architecture reference.
>
> This document is kept for historical reasons. Some details below were
> wrong (filename = command, `worker.state`, `DEVLOOP_*_OVERRIDE`, etc.)
> and the corrections are documented in both the changelog and the TUI
> README's "Spec correction history" section.
>
> **For new work** start from `cmd/devloop-tui/README.md`, not this brief.

---

## What is devloop?

`devloop` is a bash-script-based multi-agent AI development pipeline that orchestrates Claude Code, GitHub Copilot, OpenCode, and Pi into a fully automated design→implement→review loop.

The core loop:
```
User sends feature request (from phone/terminal)
    ↓
devloop architect "feature"   → produces .devloop/specs/TASK-ID.md
devloop work [TASK-ID]        → worker implements and commits
devloop review [TASK-ID]      → main provider diffs vs spec → APPROVED / NEEDS_WORK / REJECTED
devloop fix [TASK-ID]         → worker applies fix instructions
devloop learn [TASK-ID]       → lessons extracted to CLAUDE.md
```

## What is devloop-tui?

`cmd/devloop-tui/` is a Go TUI (Bubble Tea + Lipgloss) with three existing views:
- **Dashboard** (`internal/views/dashboard.go`) — split pane: task list left, session detail right
- **Chat** (`internal/views/chat.go`) — slash-command REPL (`/plan`, `/run`, `/fix`, `/status`, `/diff`, etc.)
- **Run/Status** (`internal/views/run.go`) — single-session live view

The TUI currently works but is rough: no provider health display, no collapsible panels, no command palette, no focus mode, and the onboarding (init + doctor) is raw terminal output.

## What we are building

A redesigned devloop-tui combining four concepts from the wireframes:

| View | What | Priority |
|------|------|----------|
| Dashboard (Split Pane+) | Refactor existing — add provider health bar, fuzzy filter, collapsible SPEC/DIFF panels | Phase 1 |
| Focus Mode | NEW — single task full-screen, ← → navigation, SPEC/DIFF/LOG tabs | Phase 2 |
| Command Palette | NEW — SPACE overlay anywhere to fuzzy-search and run actions | Phase 2 |
| Onboarding Wizard | NEW — structured init+doctor output, first-run experience | Phase 3 |

## Design reference files

Both files are in the `design/` folder alongside this CLAUDE.md:

- `design/DevLoop TUI Wireframes.html` — open in a browser to see all 5 wireframe artboards
- `design/DevLoop TUI — Implementation Spec.html` — full engineering spec with model structs, keybindings, and implementation checklists

**Read the spec before writing any code.** It contains exact struct definitions, lipgloss style decisions, and keybindings that must be followed.

## Repository structure (existing)

```
cmd/devloop-tui/
├── main.go
├── internal/
│   ├── app/app.go              ← root model, view routing
│   ├── components/
│   │   ├── pipeline_grid.go    ← phase rendering (keep as-is)
│   │   └── task_picker.go      ← list component (keep as-is)
│   ├── views/
│   │   ├── dashboard.go        ← REFACTOR in Phase 1
│   │   ├── chat.go             ← keep as-is (minor style only)
│   │   └── run.go              ← keep as-is
│   └── stream/                 ← NDJSON tailer, session scan (DO NOT MODIFY)
```

## New files to create

```
cmd/devloop-tui/internal/
├── theme/
│   └── colors.go          ← starter file included in starter/ folder
├── components/
│   ├── panel.go            ← collapsible SPEC/DIFF panel component
│   └── palette.go          ← command palette overlay component
└── views/
    ├── focus.go            ← single-task focus view
    └── onboard.go          ← init+doctor wizard view
```

A starter `colors.go` is in `starter/cmd/devloop-tui/internal/theme/colors.go` — copy it to the right location before starting.

## Code conventions

- **Go 1.22+**
- Use `github.com/charmbracelet/bubbletea` for all TUI models
- Use `github.com/charmbracelet/lipgloss` for all styling — never use raw ANSI escape codes
- Use `github.com/charmbracelet/bubbles/viewport` for scrollable content (log, spec, diff)
- Use `github.com/charmbracelet/bubbles/textinput` for text inputs (filter, palette search)
- Color tokens live in `internal/theme/colors.go` — import `theme` and use `theme.Green`, `theme.Blue`, etc.
- Messages between models use named types (`openFocusMsg`, `closeFocusMsg`, etc.) — no raw strings
- Never modify files under `internal/stream/` — that package is stable and tested
- `pipeline_grid.go` and `task_picker.go` are also stable — do not modify, only extend if necessary

## Coverage matrix (from design review)

A review of devloop v5.2.0 features against the redesigned TUI found:

| Area | Fully covered | Partial | Not present |
|------|--------------|---------|-------------|
| Core loop (architect/work/review/fix/learn) | ✅ 6/6 | 1 | 0 |
| Provider / failover | ⚠ 2/6 | 0 | 4 |
| Permission / safety | ⚠ 1/2 | 0 | 1 |
| Task management | ⚠ 2/8 | 3 | 3 |
| Daemon / remote | ⚠ 1/5 | 0 | 4 |

**Three gaps pulled into Phase 4 (high priority):**
1. **Permit queue surface** — hooks is in the palette but no UI to approve/deny queued commands
2. **Daemon control** — top bar shows liveness only; need start/stop/log in palette
3. **Resume / stuck pipeline** — stuck-phase indicator in Focus Mode + Z resume action

**Deferred (reasonable to skip for now):**
- `tools audit/suggest/add/sync` (MCP, skills, plugins) — complex sub-system
- `queue add/run` — batch spec workflow
- `agent-sync` — provider docs refresh
- `clean --days N` — spec hygiene
- `history/replay/respec/audit/stats` — past-task operations
- `ci` — one-shot GitHub Actions scaffolding

## Phase order

Work in this order:

1. **Phase 1** — Dashboard refactor (prompt in `prompts/phase-1.md`)
2. **Phase 2** — Focus Mode + Command Palette (prompt in `prompts/phase-2.md`)
3. **Phase 3** — Onboarding Wizard (prompt in `prompts/phase-3.md`)
4. **Phase 4** — Permit queue + Daemon control + Resume (prompt in `prompts/phase-4.md`)

Each phase has a checklist in the implementation spec. Tick off items as you complete them.

## Running the TUI

```bash
cd cmd/devloop-tui
go build -o devloop-tui .
./devloop-tui              # dashboard (default)
./devloop-tui chat         # chat REPL
./devloop-tui status       # newest session
./devloop-tui onboard      # onboarding wizard (Phase 3)
```

## Key file paths at runtime

| Path | Purpose |
|------|---------|
| `.devloop/provider-health.sh` | Provider failover state — parse for health bar |
| `.devloop/daemon.pid` | Daemon PID — exists = daemon running |
| `.devloop/pipeline.log` | NDJSON event stream — already tailed by stream.Tailer |
| `.devloop/specs/TASK-ID.md` | Full task spec — load for SPEC panel |
| `.devloop/specs/TASK-ID.pre-commit` | Git baseline hash — use for DIFF panel |
| `devloop.config.sh` | Project config — absence triggers onboarding |
