# Changelog

All notable changes to DevLoop are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [4.2.0] — 2026-05-09

### Added
- **Smart permission gate** (`devloop hooks`): Claude `PreToolUse` hook classifies every Bash command — BLOCK dangerous commands (`rm -rf /`, `curl|bash`, etc.), ALLOW known-safe commands (git, pytest, npm test, make, linters), ESCALATE unknowns (asks user via tty → osascript dialog → queue file → auto-deny)
- **`devloop permit` command**: inspect and manage the permission gate with `status`, `watch`, `grant`, `deny`, `log`, `mode` subcommands
- **PostToolUse audit log**: every tool call recorded to `.devloop/permissions.log`
- **Permission modes**: `smart` (default), `auto`, `strict`, `off` — set via `DEVLOOP_PERMISSION_MODE`
- **Permission escalation timeout**: `DEVLOOP_PERMISSION_TIMEOUT` (default: 60s) before auto-deny

### Fixed
- **Copilot non-interactive permission wall**: all `copilot` invocations now use `--allow-all-tools --allow-all-paths -p "<prompt>"` — fixes "Permission denied and could not request permission from user" that blocked workers and reviewers in pipe mode
- **Copilot `-p` flag syntax**: corrected from `echo ... | copilot -p` (broken) to `copilot -p "$prompt"` (correct — `-p` is a required argument, not a stdin flag)
- **Claude worker tool scope**: `cmd_work` and `cmd_fix` now pass `--allowedTools` to `claude -p` workers to restrict to file ops, git, and test runners
- **Claude reviewer tool scope**: `run_provider_prompt` uses read-only tool set for architect/reviewer roles
- **Auto-recovery messaging**: removed stale "re-test after 6h" — recovery is probe-based (`DEVLOOP_PROBE_INTERVAL` minutes, default 5)

### Documentation
- README: expanded `devloop hooks` (all 7 hooks + permission tier table), new `devloop permit` section, updated file structure with hook scripts and permission files, updated `.gitignore` recommendations
- USAGE.md: new Scenario 6 — Smart Permissions end-to-end walkthrough; updated Scenario 2 hooks step; expanded Quick Reference

---

## [4.1.0] — 2026-05-09

### Changed

- `devloop init` now auto-populates stack/config values from project analysis in the first run and reports the auto-config update count.
- README and USAGE docs updated for auto-analysis-first setup flow.
- VERSION bumped to `4.1.0`.

---

## [4.0.0] — 2026-05-09

### Changed

- `devloop init` now merges/upserts existing project files instead of skipping them:
  - `devloop.config.sh`: appends missing default keys without overwriting existing values.
  - `CLAUDE.md`: updates/inserts the DevLoop-managed block (`DEVLOOP:CLAUDE` markers) while preserving custom content.
  - `.github/copilot-instructions.md`: updates/inserts the DevLoop-managed block (`DEVLOOP:COPILOT` markers) while preserving custom content.
- `devloop init` now analyzes the current project to auto-populate placeholder config fields (`PROJECT_STACK`, `PROJECT_PATTERNS`, `PROJECT_CONVENTIONS`, `TEST_FRAMEWORK`).
- VERSION bumped to `4.0.0`.

---

## [3.1.0] — Tools, Skills & MCP Management

### Added

**`devloop tools` command family — project-level tooling management**

- `devloop tools audit` — full inventory: global vs project MCP servers, skills, plugins, hooks, and Copilot instructions. Shows gaps and sync status at a glance.
- `devloop tools suggest` — reads `PROJECT_STACK` from `devloop.config.sh` and recommends MCP servers, Claude plugins, skills, and Copilot path instructions tailored to the stack.
- `devloop tools add` — interactive numbered picker; installs selected tools. Also supports non-interactive flags: `--mcp`, `--skill`, `--instruction`, `--plugin`.
- `devloop tools sync` — prompts to copy global MCP servers (`~/.claude.json`) and skills (`~/.claude/skills/`) to project level per item.

**Dual MCP config writing (Claude + Copilot)**
- `_add_mcp_to_project()` writes MCP servers to **both** `.mcp.json` (Claude; `mcpServers` key) and `.vscode/mcp.json` (Copilot/VS Code; `servers` key with `type: stdio`) in one call, auto-translating schemas.

**Claude skill scaffolding**
- `_scaffold_skill()` creates `.claude/skills/<name>/SKILL.md` with a structured template.

**Copilot path-specific instructions**
- `_add_path_instruction()` creates `.github/instructions/<name>.instructions.md` with YAML frontmatter `applyTo` glob, which Copilot applies in addition to the repo-wide instructions.

**`cmd_doctor` tools section**
- Reports MCP server count (global / project), VS Code MCP count, skill count, and path instruction count. Links to `devloop tools audit` and `devloop tools suggest`.

**Colors**
- Added `BLUE` and `MAGENTA` ANSI variables for tool-type badges in suggest/add output.

### Changed
- `devloop init` next-steps now includes step 4: "Run `devloop tools suggest` for stack-specific tool recommendations."
- VERSION bumped to `3.1.0`.

---

## [3.0.0] — 2026-05-08

### Added

**Self-improvement: `devloop learn` command**
- Extracts lessons from review cycles and appends them to `CLAUDE.md` under `## Learned Patterns`
- Claude reads these patterns in future sessions, making the pipeline progressively smarter
- CLAUDE.md template updated with `## Learned Patterns` section placeholder

**Version awareness: `devloop check` command + auto hint**
- `devloop check` — checks manifest URL for newer version and prints update instructions
- `devloop start` runs a silent background version check; shows a hint on the next start if an update is available
- New config: `DEVLOOP_VERSION_URL` pointing to a plain-text semver manifest file

**Claude Code hooks: `devloop hooks` command**
- Generates `.claude/settings.json` registering all 4 pipeline hook events
- Writes 4 executable hook scripts to `.claude/hooks/`:
  - `devloop-stop.sh` — logs task summary on `Stop` event
  - `devloop-subagent-stop.sh` — records subagent completion and verdict keywords
  - `devloop-notification.sh` — saves Claude notifications to `.devloop/notifications.log`
  - `devloop-session.sh` — records session start/end to `.devloop/sessions.log`
- Orchestrator agent updated with mobile push notification guidance

**Pipeline log viewer: `devloop logs` command**
- Views pipeline, notification, and session logs collected by hooks
- Usage: `devloop logs [pipeline|notifications|sessions]`

**Health check: `devloop doctor` command**
- Validates all DevLoop dependencies: `claude` auth, `copilot` auth, `gh` auth, git config, agent files, config validity, version currency
- Prints ✔/✖ for each check with actionable fix hints

**GitHub Actions integration: `devloop ci` command**
- Generates `.github/workflows/devloop-review.yml` for CI-triggered PR review
- Uses `anthropics/claude-code-action` — requires `ANTHROPIC_API_KEY` secret in repo

**Copilot coding agent: `github-agent` worker mode**
- New `DEVLOOP_WORKER_MODE` config: `cli` (default) or `github-agent`
- In `github-agent` mode, `devloop work` creates a GitHub Issue with the spec, waits for Copilot's cloud agent to open a PR
- `devloop init` generates `copilot-setup-steps.yml` when `DEVLOOP_WORKER_MODE=github-agent`
- New config: `DEVLOOP_VERSION_URL` for update checking

### Changed

- `devloop.config.sh` template updated with `DEVLOOP_WORKER_MODE` and `DEVLOOP_VERSION_URL` defaults
- `CLAUDE.md` template updated with cleaner system section and `## Learned Patterns` placeholder
- `cmd_help` updated with all new commands and worker mode documentation
- `README.md` updated with all new commands, worker modes, and expanded file structure
- `devloop init` next-steps guidance updated to include `devloop hooks`

---

## [2.1.0] — 2026-05-07

### Added

**Architecture & data flow diagrams**
- Added [`DEVLOOP-GRAPH.md`](./DEVLOOP-GRAPH.md) — 11 detailed Mermaid diagrams covering the full pipeline, every command, file lifecycle, git baseline mechanism, `devloop work` and `devloop review` prompt structure, daemon auto-restart loop, status state machine, agent collaboration map, and `devloop clean` selection logic

**Linux systemd support (FIX #15)**
- `devloop daemon` now registers a `~/.config/systemd/user/devloop-<project>.service` unit on Linux
- Service starts automatically on user login (`WantedBy=default.target`) and restarts on crash (`Restart=on-failure`)
- `devloop daemon uninstall` removes the unit on both macOS and Linux
- Internal helpers `_write_systemd` and `_remove_systemd` added alongside existing `_write_launchd` / `_remove_launchd`

**`devloop open` command · alias `o` (FIX #12)**
- Opens the task spec file in `$EDITOR` (falls back to `$VISUAL`, then `vi`)
- Works with latest task or a named `TASK-ID`

**`devloop block` command · alias `b` (FIX #12)**
- Prints the Copilot Instructions Block extracted from a spec
- Useful for manually pasting into Copilot chat without running the full pipeline
- Reads from the pre-extracted `.devloop/prompts/TASK-ID-copilot.txt` when available

**`devloop clean` command (FIX #13)**
- Removes finalized (approved/rejected) specs older than N days (default: 30)
- `--days N` flag to customize the age threshold
- `--dry-run` flag to preview removals without making changes
- Pending and needs-work tasks are always preserved
- Cleans all related files per task: spec `.md`, review `.md`, `.pre-commit` baseline, `-copilot.txt` prompt

**`devloop update` command (FIX #14)**
- Self-upgrades the devloop binary from `DEVLOOP_SOURCE_URL`
- Shows a diff before applying so you can review what changed
- Backs up current binary to `devloop.sh.bak`
- Prints clear setup instructions when `DEVLOOP_SOURCE_URL` is not configured

**Git baseline for precise review diffs (FIX #1)**
- `devloop work` now records the current `HEAD` hash to `.devloop/specs/TASK-ID.pre-commit` before launching Copilot
- `devloop review` uses this baseline to `git diff base..HEAD` — sees exactly what Copilot changed across one or more commits
- `devloop fix` updates the baseline after Copilot's fix commit so the next review only diffs the new changes
- Falls back to uncommitted `git diff` if no baseline file exists

**Full spec delivered to Copilot (FIX #10)**
- `devloop work` now sends the complete spec file (all sections) instead of only the condensed Instructions Block
- Copilot now receives: Files to Touch, Implementation Steps, Edge Cases, Test Scenarios, and the Instructions Block

**Runtime context prepended to Copilot prompt (FIX #11)**
- `devloop work` prepends live project context from `devloop.config.sh` (stack, patterns, conventions, test framework, commit format) at the top of every Copilot prompt
- Context is printed to the terminal as `Runtime context → Stack: ... | Tests: ...` so it is visible in devloop output
- Ensures Copilot always has up-to-date conventions even on re-runs after config changes

**Rich `.github/copilot-instructions.md` template (FIX #9 + FIX #11)**
- `devloop init` now writes a detailed Copilot instructions file with live stack values, commit format, and a pre-flight checklist
- Includes: stack, patterns, conventions, test framework, commit message format (`feat(TASK-ID): ...`), and implementation checklist

**Spec completeness validation (FIX #7)**
- `devloop work` refuses to launch Copilot if the spec is missing the `## Copilot Instructions Block` section
- Prints a clear error with the regeneration command

**Seconds-precision task IDs (FIX #3)**
- Task IDs now use `TASK-YYYYMMDD-HHMMSS` format (6-digit time) instead of `TASK-YYYYMMDD-HHMM`
- Eliminates collisions when two specs are created in the same minute

**Dynamic agent model from config (FIX #5)**
- `devloop-architect.md` and `devloop-reviewer.md` are generated with the `CLAUDE_MODEL` value from `devloop.config.sh`
- Changing `CLAUDE_MODEL` and re-running `devloop init` regenerates both agent files with the new model
- Agent front matter (model field) uses an unquoted heredoc for variable expansion while the body uses a quoted heredoc to preserve literal `$` signs

**TodoWrite in orchestrator agent (FIX #8)**
- The `devloop-orchestrator` agent now lists `TodoWrite` in its tools
- Orchestrator tracks task progress with per-step todo items: Architect spec → Copilot implement → Review → Done

### Fixed

**`devloop daemon` subcommand argument parsing (FIX #4)**
- `stop`, `status`, `log`, and `uninstall` now work without specifying a project name: `devloop daemon stop`
- Previously required `devloop daemon <project-name> stop`
- Bare subcommands use the project name from `devloop.config.sh`

**Fenced code block extraction with language tags (FIX #2)**
- Copilot Instructions Block extraction and fix instruction extraction now match ```` ``` ```` with or without a language identifier (e.g. ```` ```python ````)
- Previously only matched bare ```` ``` ```` lines, causing extraction to silently return empty on language-tagged blocks

**`devloop clean` "preserved" message when count = 0 (FIX #13)**
- When no specs are old enough to clean but some are skipped (pending/needs-work), now prints:
  `"No finalized specs removed, N pending/needs-work preserved"`
- Previously only printed the generic "none found" message, hiding the fact that tasks were preserved

**bash 3.2 heredoc compatibility in `cmd_review`**
- Replaced `review_prompt="$(cat <<HEREDOC...HEREDOC)"` with a `mktemp` + `printf` approach
- The old pattern caused `"bad substitution: no closing ')'"` on macOS bash 3.2 when the git diff contained backtick characters (common in markdown code blocks in agent `.md` files)

**`cmd_review` output capture under `set -euo pipefail`**
- Replaced `echo ... | claude -p | tee "$review_file"` with `echo ... | claude -p > "$review_file" && cat "$review_file"`
- The `tee` pipeline's exit code was unreliable under `pipefail`, causing the review file to never be written

### Changed

- `devloop init` skips existing files instead of overwriting — safe to re-run after config changes
- `devloop architect` writes the extracted Copilot block to `.devloop/prompts/TASK-ID-copilot.txt` for use by `devloop block`
- `devloop tasks` output updated to show seconds in task IDs
- Orchestrator agent workflow updated with `TodoWrite` tracking steps and clearer phase indicators

---

## [2.0.0] — 2026-05-01

### Added
- Three-agent pipeline: orchestrator + architect + reviewer
- `devloop init` — project setup with agent definitions, CLAUDE.md, config file
- `devloop start` — Claude Code with remote control and `caffeinate -is`
- `devloop daemon` — background mode with auto-restart and launchd registration (macOS)
- `devloop architect` — Claude designs implementation spec for Copilot
- `devloop work` — Copilot implements with `/plan` mode
- `devloop review` — Claude reviews `git diff` against spec
- `devloop fix` — Copilot applies Claude's fix instructions
- `devloop tasks` — list all specs with status
- `devloop status` — show spec + review for a task
- Embedded agent definitions written by `devloop init`
- Exponential backoff daemon restarts (5s → 60s, 20 retries max)
- Per-project launchd `.plist` auto-registered on daemon start

### Changed
- Single-file distribution — everything in `devloop.sh`

---

## [1.0.0] — 2026-04-15

### Added
- Initial release: single `devloop.sh` script
- Basic architect → work → review loop
- `devloop init`, `devloop start`, `devloop architect`, `devloop work`, `devloop review`, `devloop fix`
- `devloop.config.sh` for project stack configuration
