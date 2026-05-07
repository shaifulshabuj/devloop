# DevLoop — Usage & Data Flow Graphs

---

## 1. Full Pipeline — End to End

```mermaid
flowchart TD
    USER("👤 User\n(phone / browser)")
    CLAUDE_START("claude --remote-control\n+ orchestrator agent")
    ARCH("@devloop-architect\nsubagent")
    WORK("devloop work")
    COPILOT("gh copilot")
    REVIEW("devloop review")
    CLAUDE_REVIEW("claude -p\nreviewer prompt")
    FIX("devloop fix")

    APPROVED("✅ APPROVED\nDone")
    NEEDSWORK("⚠️ NEEDS_WORK\nloop back")
    REJECTED("❌ REJECTED\nAsk user to restart")

    USER -->|"add GET /orders endpoint"| CLAUDE_START
    CLAUDE_START -->|"Design spec for: feature"| ARCH
    ARCH -->|"devloop architect feature"| ARCH
    ARCH -->|"returns TASK-ID + summary"| CLAUDE_START
    CLAUDE_START -->|"devloop work TASK-ID"| WORK
    WORK -->|"full spec + runtime context\npiped via stdin"| COPILOT
    COPILOT -->|"implements + commits"| WORK
    WORK --> CLAUDE_START
    CLAUDE_START -->|"Review task: TASK-ID"| REVIEW
    REVIEW -->|"git diff baseline..HEAD\n+ spec sections"| CLAUDE_REVIEW
    CLAUDE_REVIEW -->|"verdict + score"| REVIEW
    REVIEW --> CLAUDE_START

    CLAUDE_START -->|"APPROVED"| APPROVED
    CLAUDE_START -->|"NEEDS_WORK\ndevloop fix TASK-ID"| FIX
    FIX -->|"fix instructions\npiped to copilot"| COPILOT
    FIX --> REVIEW
    CLAUDE_START -->|"REJECTED"| REJECTED

    style APPROVED fill:#1a7a1a,color:#fff
    style REJECTED fill:#7a1a1a,color:#fff
    style NEEDSWORK fill:#7a5a00,color:#fff
    style USER fill:#1a3a7a,color:#fff
    style COPILOT fill:#2a5a2a,color:#fff
```

---

## 2. Command Reference — All Commands & Aliases

```mermaid
flowchart LR
    subgraph SETUP["⚙️  Setup"]
        INSTALL("devloop install\n[path]")
        INIT("devloop init")
        UPDATE("devloop update")
    end

    subgraph SESSION["🖥️  Session"]
        START("devloop start  · s\n[project-name]")
        DAEMON("devloop daemon  · d\n[project-name]")
        D_STOP("devloop daemon stop")
        D_STATUS("devloop daemon status")
        D_LOG("devloop daemon log")
        D_UNINSTALL("devloop daemon uninstall")
    end

    subgraph PIPELINE["🔁  Pipeline"]
        ARCH("devloop architect  · a\n\"feature\" [type] [files]")
        WORK("devloop work  · w\n[TASK-ID]")
        REVIEW("devloop review  · r\n[TASK-ID]")
        FIX("devloop fix  · f\n[TASK-ID]")
    end

    subgraph INSPECT["🔎  Inspect"]
        TASKS("devloop tasks  · t")
        STATUS("devloop status\n[TASK-ID]")
        OPEN("devloop open  · o\n[TASK-ID]")
        BLOCK("devloop block  · b\n[TASK-ID]")
    end

    subgraph MAINT["🧹  Maintenance"]
        CLEAN("devloop clean\n[--days N] [--dry-run]")
    end

    ARCH --> WORK --> REVIEW --> FIX --> REVIEW
    DAEMON --> D_STOP & D_STATUS & D_LOG & D_UNINSTALL
```

---

## 3. `devloop init` — What Gets Created

```mermaid
flowchart TD
    INIT("devloop init")

    subgraph CONFIG["📄 Config"]
        C1("devloop.config.sh\nPROJECT_NAME, STACK,\nPATTERNS, TEST_FRAMEWORK\nCLAUDE_MODEL")
    end

    subgraph CLAUDE_FILES["🤖 Claude Context"]
        C2("CLAUDE.md\nProject-wide persistent\ninstructions for Claude Code")
    end

    subgraph AGENTS["🧠 Agent Definitions (.claude/agents/)"]
        A1("devloop-orchestrator.md\nmodel: sonnet\ntools: Agent, Bash, Read,\nWrite, TodoWrite")
        A2("devloop-architect.md\nmodel: ← CLAUDE_MODEL\ntools: Bash, Read, Glob, Grep")
        A3("devloop-reviewer.md\nmodel: ← CLAUDE_MODEL\ntools: Bash, Read, Glob, Grep")
    end

    subgraph COPILOT_FILES["🐙 Copilot Context"]
        CP("`.github/copilot-instructions.md`\nStack, patterns, conventions,\ntest framework, commit format,\nimplementation checklist")
    end

    subgraph DIRS["📁 Directories"]
        D1(".devloop/specs/\nTask specs + reviews + baselines")
        D2(".devloop/prompts/\nExtracted Copilot blocks")
    end

    INIT --> CONFIG & CLAUDE_FILES & AGENTS & COPILOT_FILES & DIRS

    note1["⚠️ Existing files are skipped\n— safe to re-run"]
    note2["CLAUDE_MODEL value\nbaked into both agents"]
    CONFIG -.-> note2
    note2 -.-> AGENTS
```

---

## 4. File Lifecycle — Per Task

```mermaid
flowchart TD
    A_CMD("devloop architect\n\"add feature\"")
    W_CMD("devloop work\nTASK-ID")
    R_CMD("devloop review\nTASK-ID")
    F_CMD("devloop fix\nTASK-ID")
    R2_CMD("devloop review\nTASK-ID  ← again")
    C_CMD("devloop clean")

    subgraph SPEC_FILES[".devloop/specs/"]
        SPEC("TASK-20260507-135420.md\n─────────────────\nFeature / Type\nStatus: pending ← mutated\nSummary\nFiles to Touch\nImplementation Steps\nAcceptance Criteria\nEdge Cases\nTest Scenarios\n## Copilot Instructions Block")
        PRECOMMIT("TASK-20260507-135420.pre-commit\n─────────────────\n2e20efb...  ← git SHA\n(HEAD before Copilot ran)")
        PRECOMMIT2("TASK-20260507-135420.pre-commit\n─────────────────\n2101eeb...  ← updated SHA\n(HEAD before fix ran)")
        REVIEW_FILE("TASK-20260507-135420-review.md\n─────────────────\nVerdict: NEEDS_WORK\nScore / Summary\nWhat's Good\nIssues Found\nRequired Fixes\n### Copilot Fix Instructions\n```\nFIX #1: ...\n```")
        REVIEW2_FILE("TASK-20260507-135420-review.md\n─────────────────\nVerdict: APPROVED ✅\nScore: 9/10\nNo fixes required")
    end

    subgraph PROMPT_FILES[".devloop/prompts/"]
        PROMPT("TASK-20260507-135420-copilot.txt\n─────────────────\nDEVLOOP TASK: TASK-...\nFEATURE: ...\nIMPLEMENT: ...\nRULES: ...\nEDGE CASES: ...\nTESTS REQUIRED: yes")
    end

    A_CMD -->|"writes"| SPEC
    A_CMD -->|"writes"| PROMPT
    W_CMD -->|"reads + validates"| SPEC
    W_CMD -->|"writes HEAD SHA"| PRECOMMIT
    R_CMD -->|"reads"| SPEC
    R_CMD -->|"reads SHA → git diff SHA..HEAD"| PRECOMMIT
    R_CMD -->|"writes"| REVIEW_FILE
    R_CMD -->|"updates Status → needs-work"| SPEC
    F_CMD -->|"reads fix block"| REVIEW_FILE
    F_CMD -->|"overwrites with new HEAD"| PRECOMMIT2
    R2_CMD -->|"reads"| SPEC
    R2_CMD -->|"reads new SHA → git diff"| PRECOMMIT2
    R2_CMD -->|"overwrites"| REVIEW2_FILE
    R2_CMD -->|"updates Status → approved"| SPEC
    C_CMD -->|"deletes all 4 files\nwhen approved + old enough"| SPEC
    C_CMD -->|"deletes"| PRECOMMIT2
    C_CMD -->|"deletes"| REVIEW2_FILE
    C_CMD -->|"deletes"| PROMPT

    style SPEC fill:#1a3a5a,color:#fff
    style PRECOMMIT fill:#3a1a5a,color:#fff
    style PRECOMMIT2 fill:#3a1a5a,color:#fff
    style REVIEW_FILE fill:#5a3a1a,color:#fff
    style REVIEW2_FILE fill:#1a5a1a,color:#fff
    style PROMPT fill:#1a4a4a,color:#fff
```

---

## 5. Git Baseline Mechanism

```mermaid
gitGraph
   commit id: "initial commit"
   commit id: "2e20efb ← pre-commit saved here (devloop work)"
   commit id: "5b60428 Copilot: add POST /todos"
   commit id: "2101eeb ← pre-commit updated here (devloop fix)"
   commit id: "80a9a78 Copilot: fix whitespace test"
```

```mermaid
flowchart LR
    subgraph WORK_PHASE["devloop work"]
        W1("record HEAD\n→ 2e20efb\nwrite .pre-commit")
        W2("pipe full spec\n+ runtime context\nto copilot")
        W3("Copilot commits\n5b60428")
    end

    subgraph REVIEW_PHASE["devloop review"]
        R1("read .pre-commit\n= 2e20efb")
        R2("git diff 2e20efb..HEAD\n= everything Copilot added")
        R3("Claude reviews diff\nvs spec sections")
        R4("writes review.md\nVerdict: NEEDS_WORK")
    end

    subgraph FIX_PHASE["devloop fix"]
        F1("read review.md\nextract fix block")
        F2("pipe fix instructions\nto copilot")
        F3("Copilot commits\n2101eeb")
        F4("overwrite .pre-commit\n= 2101eeb")
    end

    subgraph REVIEW2_PHASE["devloop review (2nd)"]
        R5("read .pre-commit\n= 2101eeb")
        R6("git diff 2101eeb..HEAD\n= only the fix changes")
        R7("Claude reviews\nnew diff only")
        R8("Verdict: APPROVED ✅")
    end

    W1 --> W2 --> W3 --> R1
    R1 --> R2 --> R3 --> R4 --> F1
    F1 --> F2 --> F3 --> F4 --> R5
    R5 --> R6 --> R7 --> R8

    style R8 fill:#1a7a1a,color:#fff
    style R4 fill:#7a5a00,color:#fff
```

---

## 6. `devloop work` — What Gets Sent to Copilot

```mermaid
flowchart TD
    SPEC_FILE("TASK-ID.md\n(full spec)")
    CONFIG("devloop.config.sh")

    subgraph PROMPT["Copilot stdin prompt"]
        P1("/plan  ← triggers plan mode")
        P2("## Runtime Project Context\nStack: Python, Flask, PostgreSQL\nPatterns: SOLID, Repository Pattern\nConventions: type hints everywhere\nTest framework: pytest\nCommit format: feat(TASK-ID): ...")
        P3("## Full Task Spec\n[entire TASK-ID.md contents\nincluding all sections]")
        P4("After planning, implement all steps.\nRun tests if possible.\nStage ALL changed files and commit\nwith TASK ID in message.\nSummarize what was implemented.")
        P1 --> P2 --> P3 --> P4
    end

    SPEC_FILE -->|"cat task file"| P3
    CONFIG -->|"live values"| P2

    COPILOT("gh copilot\n/plan mode")
    PROMPT -->|"piped via stdin"| COPILOT
    COPILOT -->|"implements + stages + commits"| GIT("git repo")
```

---

## 7. `devloop review` — What Gets Sent to Claude

```mermaid
flowchart TD
    PRE("TASK-ID.pre-commit\n= git SHA")
    SPEC("TASK-ID.md")
    GIT("git repo")

    DIFF_CALC{"baseline\nexists?"}
    DIFF_A("git diff SHA..HEAD\n← precise: all Copilot commits")
    DIFF_B("git diff HEAD\n+ git diff --cached\n+ new untracked files\n← fallback: uncommitted only")

    COMPACT_SPEC("compact spec\n─────────────\nHeader + Status\nSummary\nFiles to Touch\nImplementation Steps\nAcceptance Criteria\nEdge Cases\nTest Scenarios\n─────────────\n(Copilot Instructions Block\nstripped — ~40% smaller)")

    subgraph REVIEW_PROMPT["Claude -p prompt"]
        RP1("You are a strict senior code reviewer.")
        RP2("## Project\nStack / Patterns / Conventions")
        RP3("## Original Spec\n[compact spec]")
        RP4("## Implementation (git diff)\n[diff output]")
        RP5("## Review criteria\n1. Spec compliance\n2. Correctness / edge cases\n3. Error handling\n4. Code quality (SOLID)\n5. Security\n6. Test coverage")
        RP6("## Required output format\nVerdict: APPROVED | NEEDS_WORK | REJECTED\nScore / Summary / Issues / Fixes\nCopilot Fix Instructions block")
    end

    CLAUDE("claude -p\nreviewer")
    REVIEW_OUT("TASK-ID-review.md\n+ spec Status updated")

    PRE --> DIFF_CALC
    DIFF_CALC -->|"yes"| DIFF_A
    DIFF_CALC -->|"no"| DIFF_B
    GIT --> DIFF_A & DIFF_B
    SPEC -->|"awk: strip Instructions Block"| COMPACT_SPEC
    COMPACT_SPEC --> RP3
    DIFF_A & DIFF_B --> RP4
    RP1 --> RP2 --> RP3 --> RP4 --> RP5 --> RP6
    REVIEW_PROMPT -->|"piped via stdin"| CLAUDE
    CLAUDE --> REVIEW_OUT
```

---

## 8. `devloop daemon` — Background Session & Auto-Restart

```mermaid
flowchart TD
    DAEMON("devloop daemon\n[project-name]")

    subgraph BACKGROUND["Background process (subshell)"]
        LOOP{"restart\nloop"}
        CAFF("caffeinate -is &\nprevent Mac sleep")
        CLAUDE_PROC("claude --remote-control\n\"DevLoop: project\"\n--agent devloop-orchestrator\n--permission-mode acceptEdits")
        WAIT("wait for claude exit")
        BACKOFF("exponential backoff\n5s → 10s → ... → 60s max\n20 retries then stop")
        LOG("append to\n.devloop/daemon.log")
    end

    subgraph AUTOSTART["Auto-start registration"]
        LAUNCHD("macOS: launchd\n~/Library/LaunchAgents/\ncom.devloop.project.plist\nRunAtLoad + KeepAlive")
        SYSTEMD("Linux: systemd user\n~/.config/systemd/user/\ndevloop-project.service\nWantedBy=default.target\nRestart=on-failure")
    end

    subgraph MGMT["Management commands"]
        STATUS("daemon status\ncheck PID + last 10 log lines")
        LOGCMD("daemon log\ntail -f daemon.log")
        STOP("daemon stop\nkill PID")
        UNINSTALL("daemon uninstall\nremove launchd/systemd entry")
    end

    DAEMON -->|"fork to background"| LOOP
    DAEMON --> AUTOSTART
    LOOP --> CAFF
    CAFF --> CLAUDE_PROC
    CLAUDE_PROC --> WAIT
    WAIT -->|"crash / disconnect"| LOG
    LOG --> BACKOFF
    BACKOFF -->|"retry < 20"| LOOP
    BACKOFF -->|"retry = 20"| EXIT("daemon exits")

    DAEMON --> MGMT
    STATUS & LOGCMD & STOP & UNINSTALL -.->|"reads/writes\ndaemon.pid"| DAEMON

    style EXIT fill:#7a1a1a,color:#fff
    style LAUNCHD fill:#1a3a5a,color:#fff
    style SYSTEMD fill:#1a4a2a,color:#fff
```

---

## 9. Status State Machine

```mermaid
stateDiagram-v2
    [*] --> pending : devloop architect

    pending --> in_progress : devloop work\n(Copilot starts)

    in_progress --> needs_work : devloop review\nVerdict: NEEDS_WORK

    in_progress --> approved : devloop review\nVerdict: APPROVED

    in_progress --> rejected : devloop review\nVerdict: REJECTED

    needs_work --> in_progress : devloop fix\n(Copilot applies fixes)

    approved --> [*] : devloop clean\n(after N days)
    rejected --> [*] : devloop clean\n(after N days)

    note right of needs_work
        Max 3 fix loops
        in orchestrator
    end note

    note right of approved
        .pre-commit preserved
        review.md preserved
        until devloop clean
    end note
```

---

## 10. Agent Collaboration Map

```mermaid
flowchart TD
    USER("👤 User\nmobile / browser")
    ORCH("devloop-orchestrator\nmodel: sonnet\ntools: Agent · Bash · Read\nWrite · TodoWrite")
    ARCH("devloop-architect\nmodel: CLAUDE_MODEL\ntools: Bash · Read · Glob · Grep")
    REVI("devloop-reviewer\nmodel: CLAUDE_MODEL\ntools: Bash · Read · Glob · Grep")
    COPILOT("gh copilot\n/plan mode")
    GIT("git repo")

    subgraph TODO["TodoWrite — per task"]
        T1("📋 Architect spec")
        T2("📋 Copilot implement")
        T3("📋 Review")
        T4("📋 Done")
    end

    USER -->|"feature request"| ORCH
    ORCH -->|"tracks progress"| TODO
    ORCH -->|"Design spec for: feature\nType / Files"| ARCH
    ARCH -->|"devloop architect cmd"| ARCH
    ARCH -->|"TASK-ID + summary\n+ key signatures"| ORCH
    ORCH -->|"devloop work TASK-ID"| COPILOT
    COPILOT -->|"commits to"| GIT
    ORCH -->|"Review task: TASK-ID"| REVI
    REVI -->|"devloop review cmd"| REVI
    REVI -->|"APPROVED / NEEDS_WORK / REJECTED\n+ score + issues"| ORCH
    ORCH -->|"NEEDS_WORK:\ndevloop fix TASK-ID"| COPILOT
    COPILOT -->|"fix commits to"| GIT
    ORCH -->|"summary of what was built"| USER

    style ORCH fill:#1a3a5a,color:#fff
    style ARCH fill:#1a4a6a,color:#fff
    style REVI fill:#4a3a1a,color:#fff
    style COPILOT fill:#1a5a2a,color:#fff
    style USER fill:#3a1a5a,color:#fff
```

---

## 11. `devloop clean` — What Gets Removed

```mermaid
flowchart TD
    CLEAN("devloop clean\n[--days N] [--dry-run]")
    FIND("find .devloop/specs/\nTASK-*.md\nnot -review.md\nmtime +N days")

    CLEAN --> FIND

    CHECK{"Status\nin spec?"}
    FIND --> CHECK

    KEEP("skip — preserve\n⏳ pending\n⚠️ needs-work")
    REMOVE("remove all related files")

    CHECK -->|"pending / needs-work"| KEEP
    CHECK -->|"approved / rejected"| REMOVE

    subgraph FILES_REMOVED["Files deleted per task"]
        F1("specs/TASK-ID.md")
        F2("specs/TASK-ID-review.md")
        F3("specs/TASK-ID.pre-commit")
        F4("prompts/TASK-ID-copilot.txt")
    end

    REMOVE --> FILES_REMOVED

    DRYRUN{"--dry-run?"}
    REMOVE --> DRYRUN
    DRYRUN -->|"yes"| PRINT("[dry-run] would remove: TASK-ID")
    DRYRUN -->|"no"| DELETE("rm -f each file")

    style KEEP fill:#1a5a1a,color:#fff
    style DELETE fill:#5a1a1a,color:#fff
```
