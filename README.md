# 🔁 DevLoop

**Claude Code (Architect) + GitHub Copilot CLI (Worker)**

A pure shell script that wires both CLIs together natively — no Node.js, no API keys, no copy-pasting.

```
devloop architect "add order filtering by date range"
         ↓
  claude -p (non-interactive) → generates spec + Copilot instructions
         ↓
devloop work
         ↓
  copilot (interactive) → implements with /plan mode
         ↓
devloop review
         ↓
  claude -p (non-interactive) → reviews git diff → APPROVED / NEEDS_WORK
         ↓
devloop fix  (if needed)
         ↓
  copilot (interactive) → applies Claude's fix instructions
         ↓
devloop review  (repeat until APPROVED)
```

---

## Prerequisites

```bash
# Claude Code CLI
curl -fsSL https://claude.ai/install.sh | bash

# GitHub Copilot CLI (requires gh CLI first)
brew install gh
gh auth login
gh extension install github/gh-copilot
gh copilot auth

# Verify
claude --version
copilot --version
```

---

## Install DevLoop

```bash
# Option A: Global symlink (recommended)
chmod +x devloop.sh
sudo ln -s "$(pwd)/devloop.sh" /usr/local/bin/devloop

# Option B: Add to PATH
echo 'export PATH="$PATH:/path/to/devloop-shell"' >> ~/.zshrc
source ~/.zshrc

# Option C: Alias
echo 'alias devloop="/path/to/devloop-shell/devloop.sh"' >> ~/.zshrc
```

---

## Setup Per Project

```bash
cd your-project/
devloop init
```

Creates:
- `devloop.config.sh` — your stack, patterns, conventions
- `CLAUDE.md` — Claude Code persistent instructions (read every session)
- `.github/copilot-instructions.md` — Copilot persistent instructions
- `.devloop/specs/` — task specs and reviews
- `.devloop/prompts/` — extracted Copilot instruction blocks

**Edit `devloop.config.sh`:**
```bash
PROJECT_NAME="MyProject"
PROJECT_STACK="C#, .NET 8, ASP.NET Web API, MSSQL"
PROJECT_PATTERNS="SOLID, Repository Pattern, Clean Architecture"
PROJECT_CONVENTIONS="Use async/await, Custom exception classes, No magic strings"
TEST_FRAMEWORK="xUnit"
CLAUDE_MODEL="opus"  # or "sonnet" for faster/cheaper
```

---

## The Full Loop

### Step 1 — Claude designs the spec

```bash
devloop architect "add GET /orders endpoint with date range filter"

# With type and file hints:
devloop architect "null ref in OrderService.GetActive()" bugfix "OrderService.cs"

# Aliases work:
devloop a "add pagination to product listing"
```

**What happens:**
- Runs `claude -p` (print mode, non-interactive, exits)
- Saves full spec to `.devloop/specs/TASK-YYYYMMDD-HHMM.md`
- Prints the **Copilot Instructions Block** ready to use
- Saves instructions to `.devloop/prompts/TASK-ID-copilot.txt`

---

### Step 2 — Copilot implements

```bash
devloop work
# or: devloop work TASK-20260504-0930
# alias: devloop w
```

**What happens:**
- Reads spec + instructions
- Launches `copilot` interactively with the task pre-loaded
- Copilot uses `/plan` mode — creates checklist, asks clarifying questions, implements
- You supervise and can interact if needed

---

### Step 3 — Claude reviews

```bash
devloop review
# alias: devloop r
```

**What happens:**
- Reads git diff (staged + unstaged + new files)
- Runs `claude -p` with spec + diff
- Outputs: `✅ APPROVED`, `⚠️ NEEDS WORK`, or `❌ REJECTED`
- Saves review to `.devloop/specs/TASK-ID-review.md`
- If NEEDS_WORK: prints **Copilot Fix Instructions**

---

### Step 4 — Copilot fixes (if needed)

```bash
devloop fix
# alias: devloop f
```

- Reads Claude's review
- Launches `copilot` with fix instructions pre-loaded
- Go back to Step 3 until APPROVED

---

## Manage Tasks

```bash
devloop tasks          # List all specs with status icons
devloop status         # Show latest spec + review in full
devloop status TASK-ID # Show specific task
```

---

## How Each CLI Is Used

| Tool | Mode | Command | Purpose |
|------|------|---------|---------|
| `claude` | Print (non-interactive) | `claude -p "..."` | Architect: generate spec |
| `claude` | Print (non-interactive) | `claude -p "..."` | Reviewer: analyze git diff |
| `copilot` | Interactive | `copilot` with piped prompt | Worker: implement with /plan |
| `copilot` | Interactive | `copilot` with piped prompt | Worker: apply fix instructions |

**Key insight from docs:**
- `claude -p` runs in print mode — it responds and exits without interactive mode, perfect for architect/review tasks that need no supervision
- Copilot CLI's true power is agentic autonomous work — it stays interactive so you can supervise implementation

---

## File Structure

```
your-project/
├── devloop.config.sh                    # Project config
├── CLAUDE.md                            # Claude Code instructions
├── .github/
│   └── copilot-instructions.md          # Copilot instructions
└── .devloop/
    ├── specs/
    │   ├── TASK-20260504-0930.md        # Full spec
    │   ├── TASK-20260504-0930-review.md # Claude's review
    │   └── ...
    └── prompts/
        ├── TASK-20260504-0930-copilot.txt  # Extracted instructions
        └── ...
```

---

## Tips

**Use CLAUDE.md for persistent architect context:**
Claude Code reads `CLAUDE.md` at the start of every session, so your stack and patterns don't need to be re-explained each time.

**Use `.github/copilot-instructions.md` for persistent worker context:**
Copilot CLI automatically reads instructions from `.github/copilot-instructions.md` — so your code standards are always in scope.

**Use plan mode for complex tasks:**
Models achieve higher success rates when given a concrete plan to follow — `devloop work` pre-loads `/plan` mode automatically.

**Switch Claude model for cost control:**
```bash
# In devloop.config.sh:
CLAUDE_MODEL="sonnet"  # Faster, cheaper for simpler features
CLAUDE_MODEL="opus"    # Strongest for architecture and review
```
