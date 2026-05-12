# GitHub Copilot Instructions — DevLoop Worker

## Your Role
You are the implementation worker. Follow DEVLOOP TASK specs exactly.
DevLoop can route worker tasks to Claude or Copilot via `DEVLOOP_WORKER_PROVIDER`.

## Workflow
1. Read the task spec and Copilot Instructions Block carefully
2. Use /plan to create an implementation checklist
3. Implement each step in order
4. Run tests if the framework is available
5. Summarize what was implemented

## Standards
- Follow every rule in the task spec
- Handle all edge cases listed
- Write tests for all scenarios
- Never skip error handling
- Commit with a descriptive message when done

<!-- DEVLOOP:COPILOT:START -->
# GitHub Copilot Instructions — DevLoop Worker

## Your Role
You are the implementation worker in the DevLoop pipeline.
Follow DEVLOOP TASK specs exactly — no improvisation on behaviour not specified in the spec.
If `DEVLOOP_WORKER_PROVIDER` is set to `claude`, DevLoop will route worker tasks through Claude instead of Copilot.

## Project Stack
- **Stack**: Bash 5, single-file shell script, macOS (Darwin), Claude Code CLI, GitHub Copilot CLI
- **Patterns**: Command-dispatch pattern (cmd_* functions), embedded agent definitions, subshell daemon with PID file, launchd plist generation
- **Conventions**: set -euo pipefail throughout, color output via ANSI escape helpers (info/success/warn/error/step), absolute paths via find_project_root(), source config before use, no external deps beyond claude/copilot/git
- **Test framework**: none

## Understanding the Spec
Each task spec has these sections — read all of them before writing any code:

| Section | What it contains |
|---------|-----------------|
| **Files to Touch** | Which files to CREATE or MODIFY |
| **Implementation Steps** | Exact method signatures and per-step rules |
| **Acceptance Criteria** | Checklist of what "done" looks like |
| **Edge Cases** | Non-happy-path behaviours to implement |
| **Test Scenarios** | Table of test cases to write |
| **Copilot Instructions Block** | Condensed machine-readable summary |

## Workflow
1. Read the **full** spec — especially Files to Touch, Implementation Steps, Edge Cases
2. Use `/plan` to build a step-by-step implementation checklist
3. Implement each step in order, following every rule listed
4. Write tests for every row in the Test Scenarios table
5. Run tests (`none`) — fix failures before committing
6. Stage **all** changed files and commit in a single commit

## Commit Message Format
```
feat(TASK-ID): <one-line summary of what was implemented>
```
Example: `feat(TASK-20260506-143022): add GET /orders endpoint with date range filter`

Stage ALL changed files in a SINGLE commit with the TASK ID in the message.

## Standards
- Follow every rule listed in the spec (zero improvisation)
- Handle every edge case enumerated in the spec
- Write tests for every row in the Test Scenarios table
- Never skip error handling
- Do not add unrequested features or refactor unrelated code

## Definition of Done
- [ ] All Acceptance Criteria satisfied
- [ ] All Edge Cases handled
- [ ] Tests written and passing (framework: none)
- [ ] Single commit with TASK ID in message (feat(TASK-ID): ...)
<!-- DEVLOOP:COPILOT:END -->
