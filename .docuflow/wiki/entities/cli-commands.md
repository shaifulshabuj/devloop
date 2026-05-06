---
title: "CLI Command Reference"
category: entity
tags: [cli, commands, devloop, shell]
created: 2026-05-06
---

# CLI Command Reference

All commands are run as `devloop <command> [args]`. Short aliases are listed where available.

---

## `devloop install [path]`

Copies the `devloop.sh` script to a system PATH location.

```bash
devloop install                    # installs to /usr/local/bin/devloop
devloop install ~/bin/devloop      # custom path
```

Uses `sudo` automatically if the target directory is not writable. Skips if the script is already at the target path.

---

## `devloop init`

Sets up DevLoop in the current project directory. **Run once per project.**

```bash
devloop init
```

Creates the following files (skips any that already exist):

| File | Purpose |
|------|---------|
| `devloop.config.sh` | Project stack, patterns, conventions |
| `CLAUDE.md` | Persistent context for Claude Code sessions |
| `.github/copilot-instructions.md` | Persistent context for Copilot |
| `.claude/agents/devloop-orchestrator.md` | Main agent — coordinates the loop |
| `.claude/agents/devloop-architect.md` | Subagent — designs specs |
| `.claude/agents/devloop-reviewer.md` | Subagent — reviews implementation |
| `.devloop/specs/` | Directory for task specs and reviews |
| `.devloop/prompts/` | Directory for extracted Copilot instruction blocks |

**After init, always edit `devloop.config.sh`** to describe your actual stack before running `devloop start`.

---

## `devloop start [project-name]` · alias: `s`

Launches Claude Code in the foreground with remote control and the orchestrator agent.

```bash
devloop start
devloop start "Avail OMS"    # custom session name shown in app
```

- Prevents Mac sleep via `caffeinate -is` for the entire session duration
- Sleep prevention is stopped automatically when you press Ctrl+C
- Runs agent with `--permission-mode acceptEdits` (no per-action prompts)

**Connect from:**
- Claude app → find `"DevLoop: project-name"` with a green dot
- https://claude.ai/code → session list

**Under the hood:**
```bash
caffeinate -is &
claude \
  --remote-control "DevLoop: project-name" \
  --agent devloop-orchestrator \
  --permission-mode acceptEdits
```

---

## `devloop daemon [project-name]` · alias: `d`

Runs DevLoop in the **background** with auto-restart and sleep prevention. Best for long sessions or when you want to close the terminal.

```bash
devloop daemon                  # start daemon
devloop daemon status           # check running state + last 10 log lines
devloop daemon log              # tail live logs (Ctrl+C to stop)
devloop daemon stop             # stop the daemon
devloop daemon uninstall        # remove launchd entry
```

**Differences from `start`:**
- Runs Claude in a detached background process — you can close the terminal
- Auto-restarts if Claude crashes or the connection drops
- Exponential backoff between restarts: 5s → 10s → … → 60s max (stops after 20 attempts)
- Restarts `caffeinate -is` fresh on each attempt — survives wake from sleep
- Registers a macOS **launchd agent** so DevLoop starts automatically on login/reboot

**Log files:**
```
.devloop/daemon.log           ← session events + restart history
.devloop/launchd.log          ← stdout from launchd-managed process
.devloop/launchd-error.log    ← stderr from launchd-managed process
```

**launchd agent** (`~/Library/LaunchAgents/com.devloop.<projectname>.plist`):
- `RunAtLoad: true` — starts when you log in
- `KeepAlive: true` — macOS restarts it if it crashes
- `ThrottleInterval: 10` — 10s wait before macOS restart
- `ProcessType: Interactive` — hints to macOS not to aggressively suspend

Remove with: `devloop daemon uninstall`

---

## `devloop architect "feature" [type] [files]` · alias: `a`

Claude designs a precise implementation spec for Copilot.

```bash
devloop architect "add GET /orders endpoint with date range filter"
devloop architect "null ref in OrderService.GetActive()" bugfix "OrderService.cs"
devloop architect "extract IOrderRepository interface" refactor
```

**Arguments:**
| Argument | Required | Values | Default |
|----------|----------|--------|---------|
| `feature` | yes | any string | — |
| `type` | no | `feature`, `bugfix`, `refactor`, `test` | `feature` |
| `files` | no | comma-separated file hints | — |

**Produces:**
- Full spec → `.devloop/specs/TASK-YYYYMMDD-HHMM.md`
- Copilot Instructions Block printed to terminal
- Instructions saved → `.devloop/prompts/TASK-ID-copilot.txt`

The spec includes exact method signatures, business rules, edge cases, test scenarios, and a machine-readable Copilot Instructions Block. See [Core Pipeline & Architecture](../concepts/pipeline-architecture.md) for the full spec structure.

> Normally called automatically by the orchestrator. Use manually to design a spec without starting a full session.

---

## `devloop work [TASK-ID]` · alias: `w`

Launches Copilot CLI with the task spec pre-loaded in `/plan` mode.

```bash
devloop work                          # uses latest task
devloop work TASK-20260504-0930
```

If no Task ID is given, uses the most recently created spec. Errors if no specs exist.

Copilot:
1. Reads the Copilot Instructions Block (falls back to full spec if block missing)
2. Creates an implementation plan (`/plan` mode)
3. Implements each step
4. Runs tests if the framework is available
5. Summarizes what was implemented

You can supervise the Copilot session interactively in your terminal.

---

## `devloop review [TASK-ID]` · alias: `r`

Claude reviews Copilot's implementation against the original spec using `git diff`.

```bash
devloop review
devloop review TASK-20260504-0930
```

**Reads:**
- `git diff HEAD` — all changes since last commit
- `git diff --cached` — staged changes
- New untracked files (up to 8)

**Verdict outputs:**

| Verdict | Meaning | Next step |
|---------|---------|-----------|
| `✅ APPROVED` | Matches spec, tests present, no CRITICAL/HIGH issues | Done |
| `⚠️ NEEDS_WORK` | Fixable gaps — Copilot Fix Instructions block provided | `devloop fix TASK-ID` |
| `❌ REJECTED` | Wrong approach, missing core logic, or security issue | Consider restarting |

Review saved to `.devloop/specs/TASK-ID-review.md`. Spec status field updated automatically.

---

## `devloop fix [TASK-ID]` · alias: `f`

Launches Copilot CLI with Claude's fix instructions from the latest review.

```bash
devloop fix
devloop fix TASK-20260504-0930
```

Extracts the `### Copilot Fix Instructions` block from the review file and feeds it to Copilot. Falls back to the full review if the block is not found.

After Copilot finishes fixing, run `devloop review` again. Repeat until `APPROVED`. The orchestrator agent does this loop automatically (up to 3 iterations).

---

## `devloop tasks` · alias: `t`

Lists all task specs with status icons.

```bash
devloop tasks

# Output:
# ✅ TASK-20260504-0930   add order filtering by date range   ✅ approved
# ⚠️  TASK-20260503-1415   paginate product listing            ⚠️ needs-work
# ⏳ TASK-20260503-1100   add auth middleware                  pending
```

Status icons:
| Icon | Status |
|------|--------|
| ✅ | approved |
| ⚠️ | needs-work |
| ❌ | rejected |
| ⏳ | pending (no review yet) |

---

## `devloop status [TASK-ID]`

Shows the full spec and latest review for a task.

```bash
devloop status                        # latest task
devloop status TASK-20260504-0930
```

Prints the full `.md` spec file followed by the review file (if one exists).

---

## `devloop --version`

Prints the current version string (e.g. `2.0.0`).

---

## Typical Manual Workflow

```bash
# 1. Design a spec
devloop architect "add user export to CSV" feature "UserService.cs"

# 2. Implement it
devloop work TASK-20260506-1430

# 3. Review the result
devloop review TASK-20260506-1430

# 4. Fix if needed
devloop fix TASK-20260506-1430
devloop review TASK-20260506-1430

# 5. Check all tasks
devloop tasks
```

In practice the orchestrator agent (launched by `devloop start` or `devloop daemon`) runs steps 1–4 automatically when you send a message remotely.
