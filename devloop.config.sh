# DevLoop Project Configuration — edit to match your stack

PROJECT_NAME="DevLoop"
PROJECT_STACK="Bash 5, single-file shell script, macOS (Darwin), Claude Code CLI, GitHub Copilot CLI"
PROJECT_PATTERNS="Command-dispatch pattern (cmd_* functions), embedded agent definitions, subshell daemon with PID file, launchd plist generation"
PROJECT_CONVENTIONS="set -euo pipefail throughout, color output via ANSI escape helpers (info/success/warn/error/step), absolute paths via find_project_root(), source config before use, no external deps beyond claude/copilot/git"
TEST_FRAMEWORK="none"

# Provider routing
# main = orchestrator / architect / reviewer
# worker = work / fix
# Valid values: claude, copilot
DEVLOOP_MAIN_PROVIDER="claude"
DEVLOOP_WORKER_PROVIDER="copilot"

# Model for claude -p calls when a role uses Claude
# "sonnet" = faster/cheaper, "opus" = more capable
CLAUDE_MODEL="sonnet"
