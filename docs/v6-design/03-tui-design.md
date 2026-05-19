# DevLoop v6 — TUI Design

## 1. Design Principles

- **Information density over decoration** — every pixel of terminal space is
  useful. No ASCII art banners.
- **Adaptive layout** — the screen reconfigures itself based on what's happening
  (1 agent, 2 agents, 3 tasks, etc.). You never have to manually resize.
- **Always know the state** — at any moment the user can see: what task is
  running, which agents are active, what phase we're in, and what input is expected.
- **Keyboard-first, mouse-optional** — all interactions are keyboard-navigable.

---

## 2. Layout States

### 2.1 Launch / Dashboard (no project scoped)

```
╔═══════════════════════════════════════════════════════════════════╗
║  devloop  v6.0.0                              [?] help  [q] quit  ║
╠══════════════════╦════════════════════════════════════════════════╣
║  PROJECTS        ║  RECENT TASKS                                  ║
║  ──────────────  ║  ──────────────────────────────────────────    ║
║  ▶ myapp         ║  myapp        add social login     2h ago  ✓   ║
║    devloop       ║  devloop      fix empty-array bug  1d ago  ✓   ║
║    api-service   ║  myapp        add dark mode        3d ago  ✓   ║
║    frontend      ║                                               ║
║                  ║                                               ║
║  [n] new project ║                                               ║
║  [i] init here   ║                                               ║
╠══════════════════╩════════════════════════════════════════════════╣
║  Type a task or select a project to start                         ║
║  > _                                                              ║
╚═══════════════════════════════════════════════════════════════════╝
```

### 2.2 Project Scoped — Idle

```
╔═══════════════════════════════════════════════════════════════════╗
║  devloop  myapp                               [?] help  [q] quit  ║
╠══════════════════╦════════════════════════════════════════════════╣
║  PROJECTS        ║  myapp — No active task                        ║
║  ──────────────  ║                                               ║
║  ▶ myapp         ║  Last task: add social login button  (done ✓)  ║
║    devloop       ║                                               ║
║    api-service   ║  Stack: React, Node.js, PostgreSQL             ║
║                  ║  Branch: main (clean)                         ║
║  TASKS           ║                                               ║
║  ──────────────  ║                                               ║
║    add social ✓  ║                                               ║
║    dark mode  ✓  ║                                               ║
║    [h] history   ║                                               ║
╠══════════════════╩════════════════════════════════════════════════╣
║  What do you want to build?                                       ║
║  > _                                                              ║
╚═══════════════════════════════════════════════════════════════════╝
```

### 2.3 Plan Review

After user types a task, DevLoop analyzes and presents the plan:

```
╔═══════════════════════════════════════════════════════════════════╗
║  devloop  myapp  ·  TASK-20260519-2341                            ║
╠══════════════════╦════════════════════════════════════════════════╣
║  PROJECTS        ║  Plan: "add social login button"               ║
║                  ║  ─────────────────────────────────────────     ║
║  ▶ myapp         ║  Complexity: medium  Type: feature             ║
║    devloop       ║  Affected: frontend, auth, backend             ║
║                  ║                                               ║
║  THIS TASK       ║  Steps:                                        ║
║  ──────────────  ║  1. [claude/haiku]   Analyze auth codebase     ║
║    PLAN REVIEW   ║  2. [claude/opus]    Design OAuth spec         ║
║                  ║  3. [copilot]        Implement UI + handler    ║
║                  ║  4. [claude/sonnet]  Review diff               ║
║                  ║                                               ║
║                  ║  Estimated: ~8 min  Cost: ~$0.04              ║
╠══════════════════╩════════════════════════════════════════════════╣
║  [Enter] Approve  [e] Edit plan  [r] Regenerate  [Esc] Cancel     ║
╚═══════════════════════════════════════════════════════════════════╝
```

### 2.4 Single Agent Working

```
╔═══════════════════════════════════════════════════════════════════╗
║  devloop  myapp  ·  TASK-20260519-2341  ·  Step 2/4              ║
╠══════════════════╦════════════════════════════════════════════════╣
║  PROJECTS        ║  [arch ✓] [analyst ✓] [design ⠙] [code ·]    ║
║                  ║  ─────────────────────────────────────────     ║
║  ▶ myapp         ║  claude/opus — Designing OAuth spec...         ║
║                  ║                                               ║
║  STEPS           ║  I'll analyze the existing auth patterns       ║
║  ─────────────   ║  before designing the OAuth flow.             ║
║  ✓ 1. Analyze    ║                                               ║
║  ⠙ 2. Design     ║  Looking at src/auth/... I can see you're      ║
║  · 3. Code       ║  using JWT with refresh tokens. The social     ║
║  · 4. Review     ║  login should integrate with the existing      ║
║                  ║  token pipeline rather than creating a         ║
║  [s] skip step   ║  separate auth path.                          ║
║  [p] pause       ║                                               ║
║  [i] intervene   ║  Designing: GitHub OAuth → JWT bridge...       ║
╠══════════════════╩════════════════════════════════════════════════╣
║  [i] Send message to agent  [p] Pause  [s] Skip  [Esc] Abort     ║
╚═══════════════════════════════════════════════════════════════════╝
```

### 2.5 Agent Mid-Task Question

```
╔═══════════════════════════════════════════════════════════════════╗
║  devloop  myapp  ·  TASK-20260519-2341  ·  Step 2/4  ⏸ WAITING   ║
╠══════════════════╦════════════════════════════════════════════════╣
║  PROJECTS        ║  [arch ✓] [analyst ✓] [design ⏸] [code ·]    ║
║                  ║  ─────────────────────────────────────────     ║
║  ▶ myapp         ║  claude/opus is waiting for your input:        ║
║                  ║                                               ║
║  STEPS           ║  ┌─────────────────────────────────────────┐  ║
║  ─────────────   ║  │  Which OAuth provider(s) should be      │  ║
║  ✓ 1. Analyze    ║  │  supported for social login?            │  ║
║  ⏸ 2. Design     ║  │                                         │  ║
║  · 3. Code       ║  │  [1] GitHub only                        │  ║
║  · 4. Review     ║  │  [2] Google only                        │  ║
║                  ║  │  [3] Both GitHub and Google             │  ║
║                  ║  │  [4] Type custom answer...              │  ║
║                  ║  └─────────────────────────────────────────┘  ║
╠══════════════════╩════════════════════════════════════════════════╣
║  > _                                                              ║
╚═══════════════════════════════════════════════════════════════════╝
```

### 2.6 Parallel Agents (Split Pane)

When two steps run concurrently:

```
╔═══════════════════════════════════════════════════════════════════╗
║  devloop  myapp  ·  TASK-20260519-2341  ·  Steps 3a+3b/4         ║
╠═════════╦═════════════════════════╦═════════════════════════════╣
║ PROJECTS ║ copilot — Writing code  ║ claude/haiku — Writing tests ║
║          ║ ─────────────────────── ║ ─────────────────────────── ║
║ ▶ myapp  ║ Creating                ║ Writing test cases for       ║
║   devloop║ src/components/         ║ OAuth callback handler...    ║
║          ║   SocialLogin.tsx...    ║                             ║
║ STEPS    ║                         ║ test('GitHub OAuth          ║
║ ───────  ║ import { useState }     ║ callback', async () => {    ║
║ ✓ Analyze║ from 'react';           ║   const result = await      ║
║ ✓ Design ║                         ║   handleOAuthCallback(...)  ║
║ ⠙ Code   ║ export function         ║   expect(result.token)...  ║
║ ⠙ Test   ║ SocialLogin() {         ║                             ║
║ · Review ║   ...                   ║ [Tab] focus this pane       ║
╠═════════╩═════════════════════════╩═════════════════════════════╣
║  [Tab] Switch focus  [i] Message focused agent  [p] Pause all    ║
╚═══════════════════════════════════════════════════════════════════╝
```

### 2.7 Multi-Task Tabs

```
╔══════════════════════════════════════════════════════════════════╗
║  devloop  myapp  [Task 1: social login ⠙][Task 2: dark mode ·]  ║
╠═════════╦════════════════════════════════════════════════════════╣
║         ║  Task 1: add social login button                       ║
║  ...    ║  (active task view as above)                           ║
╚═════════╩════════════════════════════════════════════════════════╝
```

---

## 3. Keyboard Map

| Key | Action |
|-----|--------|
| `Enter` | Submit input / Approve plan |
| `Esc` | Cancel / back |
| `Tab` | Switch focus between panes or task tabs |
| `i` | Intervene — send a message to the active agent |
| `p` | Pause active agent(s) |
| `s` | Skip current step |
| `e` | Edit (plan, spec, config) |
| `h` | Task history for current project |
| `?` | Help overlay |
| `q` | Quit (tasks marked interrupted, resumable) |
| `1-9` | Switch task tabs |
| `Ctrl+C` | Force quit |

---

## 4. Status Indicators

| Glyph | Meaning |
|-------|---------|
| `⠙` (spinner) | Running |
| `✓` | Completed successfully |
| `✗` | Failed |
| `⏸` | Paused / waiting for input |
| `·` | Pending (not started) |
| `↷` | Retrying |
| `~` | Interrupted (resumable) |

---

## 5. Color Palette

Using ANSI 256 colors with graceful degradation to 16 colors:

| Element | Color |
|---------|-------|
| DevLoop brand | Cyan `#00D7FF` |
| Success | Green `#00FF87` |
| Warning | Yellow `#FFD700` |
| Error | Red `#FF5F5F` |
| Agent: Claude | Purple `#AF87FF` |
| Agent: Copilot | Blue `#5F87FF` |
| Dimmed/inactive | Gray `#626262` |
| Input box | White on dark background |

---

## 6. No-TUI Fallback

When stdout is not a TTY (piped, CI, scripted):

```bash
devloop run "add social login button" --auto
```

Falls back to the v5-style text output: no TUI, sequential progress lines,
`--auto` skips approval gates. This ensures DevLoop remains scriptable.
