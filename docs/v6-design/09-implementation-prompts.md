# DevLoop v6 — Implementation Prompts for GitHub Issues

Use each prompt with `devloop run "<prompt>"` or paste directly into Claude Code.
Issues are ordered by priority (Critical → High → Medium).

---

## 🔴 CRITICAL — Issue #51

### Wire TUI input box to orchestrator dispatch

```
Implement GitHub issue #51: Wire TUI input box to orchestrator dispatch in the devloop v6 Go project at /Volumes/SATECHI_WD_BLACK_2/dev/devloop.

CONTEXT:
- The TUI is built with Bubble Tea (github.com/charmbracelet/bubbletea)
- Root model is internal/tui/app.go — type Model with fields: sidebar Sidebar, output Output, input Input
- internal/tui/input.go — Input.Value() returns current text; Input already handles keystrokes
- internal/tui/output.go — Output viewport that renders streamed text
- Orchestrator is internal/orchestrator/orchestrator.go — Orchestrator.Plan(ctx, title) returns *Plan, error
- Dispatcher is internal/orchestrator/dispatcher.go — Dispatcher.Dispatch(ctx, plan) returns DispatchResult, error
- Storage: internal/storage/db.go — Store.CreateTask(id, title), Store.UpdateTaskStatus(id, status)

WHAT TO DO:
1. In internal/tui/input.go: when Enter is pressed and Value() is non-empty, emit a custom tea.Msg (e.g. SubmitMsg{Text: string}) then clear the input
2. In internal/tui/app.go: handle SubmitMsg in Update() — start a goroutine that calls Plan() then Dispatch(), streaming output lines back via tea.Cmd channel as OutputLineMsg{Line: string}
3. In internal/tui/output.go: handle OutputLineMsg — append line to viewport content
4. Show task state in the sidebar: add "Running: <task title>" while dispatch is in progress, clear on done/error
5. The orchestrator and store must be passed into tui.New() — update the constructor signature and the caller in cmd/devloop/main.go (the `start` subcommand)

RULES:
- Do NOT block the Bubble Tea event loop — all orchestration must run in goroutines with tea.Cmd
- Use the existing Orchestrator and Dispatcher types — do not create new ones
- Run go test ./... after each file change to confirm nothing is broken
- Commit with message: "feat(tui): wire input to orchestrator dispatch (#51)"
```

---

## 🟠 HIGH — Issue #52

### Plan review UI in TUI

```
Implement GitHub issue #52: Plan review UI in TUI in the devloop v6 Go project at /Volumes/SATECHI_WD_BLACK_2/dev/devloop.

CONTEXT:
- internal/tui/plan_view.go exists but is not wired to live data
- internal/orchestrator/orchestrator.go: Plan() returns *Plan{ID, Title, Steps []Step, ...}
- Step has fields: Number int, Description string, Backend string, Model string, Status string
- The TUI root model is internal/tui/app.go (type Model)
- Current flow: Plan() → immediately Dispatch() — no pause for review

WHAT TO DO:
1. Add a PlanReviewMsg{Plan *Plan} tea.Msg emitted after Plan() succeeds
2. In internal/tui/plan_view.go: render the plan steps as a numbered list with backend/model annotations; show keybinding hints: [Enter] approve  [e] edit step  [q] cancel
3. In internal/tui/app.go: when PlanReviewMsg received, switch to a planReview focus mode that shows plan_view.go and blocks dispatch
4. On Enter (approve): emit DispatchMsg{Plan *Plan} which triggers Dispatch() in a goroutine
5. On 'e': highlight the focused step for inline editing (simple text input replacing the step description)
6. On 'q': cancel — reset to idle state, show "Task cancelled" in output
7. Run go test ./... and commit: "feat(tui): add plan review UI before dispatch (#52)"
```

---

## 🟠 HIGH — Issue #57

### Verify and test webhook/API server integration

```
Implement GitHub issue #57: Verify and test the devloop serve webhook/API server in the devloop v6 Go project at /Volumes/SATECHI_WD_BLACK_2/dev/devloop.

CONTEXT:
- internal/server/server.go and internal/server/remote.go exist
- The server package is supposed to expose an HTTP endpoint for remote task submission
- cmd/devloop/main.go may or may not have a `serve` subcommand wired up

WHAT TO DO:
1. Read internal/server/server.go and remote.go fully to understand current state
2. Ensure `devloop serve` subcommand exists in cmd/devloop/main.go (add if missing) — starts HTTP on :7331
3. Verify these endpoints work end-to-end:
   - POST /task  body: {"title": "..."}  → creates task, dispatches, returns task ID
   - GET  /task/{id}  → returns task status + output
   - GET  /task/{id}/stream  → SSE stream of output lines while running
4. Fix any gaps in routing, dispatch wiring, or response format
5. Add an integration test in tests/ that:
   - Starts the server in-process on a random port
   - POSTs a task
   - Polls /task/{id} until done
   - Asserts non-empty output
6. Run go test ./... including the new integration test
7. Commit: "feat(server): verify and fix devloop serve integration (#57)"
```

---

## 🟡 MEDIUM — Issue #53

### devloop history command

```
Implement GitHub issue #53: Add devloop history command in the devloop v6 Go project at /Volumes/SATECHI_WD_BLACK_2/dev/devloop.

CONTEXT:
- cmd/devloop/main.go uses cobra for CLI — follow pattern of existing commands like statusCmd(), resumeCmd()
- internal/storage/db.go has Store.ListTasks(limit int) []*Task — Task has: ID, Title, Status, CreatedAt, UpdatedAt
- Task.Status values: "pending", "running", "done", "failed", "interrupted"
- Storage is opened in main() and passed to commands via closure

WHAT TO DO:
1. Add historyCmd() in cmd/devloop/main.go following the same pattern as statusCmd()
2. Flags:
   - --limit N  (default 20)
   - --status <status>  (filter by status: done|failed|interrupted|all, default all)
   - --project <path>  (filter by project path, default current directory)
3. Extend Store.ListTasks() in internal/storage/db.go to accept optional status filter (add ListTasksFiltered(limit int, status string) if needed)
4. Output format (table):
   ID (short 8 chars)  |  Title (truncated 50)  |  Status  |  Backend  |  Created
5. Register in main() with root.AddCommand(historyCmd())
6. Run go test ./... and commit: "feat(cli): add devloop history command (#53)"
```

---

## 🟡 MEDIUM — Issue #55

### TUI skill management UI

```
Implement GitHub issue #55: Wire TUI skill management panel to live data in the devloop v6 Go project at /Volumes/SATECHI_WD_BLACK_2/dev/devloop.

CONTEXT:
- internal/tui/skill_view.go exists but shows placeholder/static content
- internal/agent/skills.go has the skill loading logic — read it to find the public API
- Skills are loaded from global (~/.devloop/skills/) and project (.devloop/skills/) directories
- The TUI root model is internal/tui/app.go (type Model)

WHAT TO DO:
1. Read internal/agent/skills.go to understand the Skill type and how skills are listed
2. In internal/tui/skill_view.go: replace placeholder with a real list that calls the skill loader on Init
3. Display per skill: name, description, source (global/project), tool count
4. On selection (Enter): show skill detail pane with full description and tool list
5. Add a keyboard shortcut 's' in app.go to toggle the skill panel visible/hidden
6. Wire a SkillsLoadedMsg that fires on startup to populate the list asynchronously
7. Run go test ./... and commit: "feat(tui): wire skill management panel to live data (#55)"
```

---

## 🟡 MEDIUM — Issue #56

### TUI project switcher dashboard

```
Implement GitHub issue #56: TUI project switcher dashboard in the devloop v6 Go project at /Volumes/SATECHI_WD_BLACK_2/dev/devloop.

CONTEXT:
- internal/config/registry.go manages the project registry (~/.devloop/projects.toml)
- internal/tui/sidebar.go renders the sidebar — currently shows single project name
- internal/tui/dashboard.go exists — read to understand current dashboard state
- Switching project context means: reload config for new project path, update sidebar title, reload task list

WHAT TO DO:
1. Read internal/config/registry.go to find the Project type and list/get functions
2. In internal/tui/sidebar.go: show a list of all registered projects (from registry), highlight active one
3. Up/Down arrows navigate project list; Enter selects — emits ProjectSwitchMsg{Path: string}
4. In internal/tui/app.go: handle ProjectSwitchMsg — reload config and task list for new project, update sidebar title
5. Show recent tasks for the selected project in the output area on switch
6. Run go test ./... and commit: "feat(tui): add project switcher to sidebar (#56)"
```

---

## 🟡 MEDIUM — Issue #54

### TUI agent/persona management UI

```
Implement GitHub issue #54: TUI agent/persona management UI in the devloop v6 Go project at /Volumes/SATECHI_WD_BLACK_2/dev/devloop.

CONTEXT:
- internal/agent/persona.go has the Persona type and loading logic — read it for the public API
- Personas are .toml files in ~/.devloop/personas/ and .devloop/personas/
- internal/tui/app.go is the root model — currently has no persona panel
- internal/tui/dashboard.go — may have a suitable placeholder section

WHAT TO DO:
1. Read internal/agent/persona.go to understand Persona fields (name, description, backend, model, systemPrompt)
2. Create internal/tui/persona_view.go — a Bubble Tea component that:
   - Lists loaded personas (name, backend, model, source)
   - Shows detail pane on selection
   - Has keybinding 'n' to scaffold a new persona (open $EDITOR with a TOML template)
3. Add keyboard shortcut 'p' in app.go to toggle persona panel
4. Wire PersonasLoadedMsg on startup to populate the list asynchronously
5. Run go test ./... and commit: "feat(tui): add persona management panel (#54)"
```

---

## 🟡 MEDIUM — Issue #58

### Wire split-pane TUI for parallel agent streams

```
Implement GitHub issue #58: Wire split-pane TUI for parallel agent streams in the devloop v6 Go project at /Volumes/SATECHI_WD_BLACK_2/dev/devloop.

CONTEXT:
- internal/tui/split.go exists — read it to understand the split pane component
- internal/orchestrator/parallel.go exists — read it to understand how parallel steps are dispatched
- Parallel steps run concurrently; each produces its own output stream
- internal/tui/app.go is the root model — currently only has a single Output viewport

WHAT TO DO:
1. Read internal/tui/split.go and internal/orchestrator/parallel.go fully
2. When Dispatch detects >1 parallel step group, emit a SplitViewMsg{Count: int} to the TUI
3. In internal/tui/split.go: implement a component that holds N viewports side by side (N=2: 50/50, N=3: thirds)
4. Wire each parallel step's output to its own pane via PaneOutputMsg{PaneIndex: int, Line: string}
5. Left/Right arrow keys move focus between panes
6. When all parallel steps complete, collapse back to single output view showing merged summary
7. Run go test ./... and commit: "feat(tui): wire split-pane for parallel agent streams (#58)"
```

---

## 🟡 MEDIUM — Issue #59

### Wire cost dashboard TUI to live storage data

```
Implement GitHub issue #59: Wire cost dashboard TUI to live storage data in the devloop v6 Go project at /Volumes/SATECHI_WD_BLACK_2/dev/devloop.

CONTEXT:
- internal/tui/cost_view.go exists — read it to see current placeholder state
- internal/storage/cost.go has EstimateCost(taskID, model string, entries []*ContextEntry) TaskCost
- internal/storage/db.go has ListTasks(limit) and GetContext(taskID) for loading cost inputs
- Keyboard shortcut '$' or 'c' should toggle cost view

WHAT TO DO:
1. Read internal/tui/cost_view.go and internal/storage/cost.go fully
2. Add a StoreCostSummary(taskID string) method to internal/storage/cost.go (or db.go) that:
   - Loads context entries for a task
   - Calls EstimateCost()
   - Returns a CostSummary{ByTask map[string]TaskCost, TotalUSD float64}
3. In internal/tui/cost_view.go: on Init, load cost summary via a CostSummaryMsg async
4. Show per-task cost table: task title | backend/model | tokens in | tokens out | estimated USD
5. Show totals row at bottom
6. Refresh on TaskCompleteMsg (re-query after each task finishes)
7. Add keyboard shortcut '$' in app.go to toggle cost view
8. Run go test ./... and commit: "feat(tui): wire cost dashboard to live storage data (#59)"
```

---

## Usage

### Run a single issue with devloop:
```bash
devloop run "$(sed -n '/## 🔴 CRITICAL/,/^---/p' .devloop/v6-issue-prompts.md | grep -A100 '^\`\`\`$' | tail -n +2 | head -n -1)"
```

### Or paste any prompt block directly into Claude Code (claude).

### Recommended order:
1. #51 (Critical — makes TUI interactive, unblocks all other TUI work)
2. #52 (High — plan review, builds on #51)
3. #57 (High — server integration, independent)
4. #53 (Medium — history CLI, independent)
5. #55, #56, #54 (Medium — TUI panels, can be done in parallel)
6. #58, #59 (Medium — advanced TUI, depends on #51)
