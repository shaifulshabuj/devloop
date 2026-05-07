# Changelog

All notable changes to DevLoop are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [2.1.0] — 2026-05-07

### Added

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
