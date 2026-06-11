# Github's new AI Credit Usage Report — DevLoop Session

**Session:** `waymark-devloop-controlled`  
  
**Date:** 2026-06-03 (22:18–01:14 KST / 13:18–16:14 UTC)  
**Model:** claude-sonnet-4.6  
**Extra cost incurred:** ~$10 USD overage  
**Devloop:** Custom multi-agent AI development pipeline for software development tasks, built on top of Copilot and Claude.  
**Teststop:** A tool that runs the full test suite and returns results as context for the next assistant turn using Claude.  
**Summary:** This report analyzes the root causes of the unexpectedly high AI credit usage during a single DevLoop session, which ran for ~3 hours and consumed approximately 36.4 million tokens, leading to a ~$10 overage charge on top of the monthly Copilot plan.

---

## Total Token Consumption

| Metric | Value |
|--------|-------|
| Input tokens | 35,952,200 |
| Output tokens | 451,307 |
| **Total tokens** | **36,403,507 (~36.4M)** |
| User messages sent | 7 |
| Assistant events generated | 870 |
| Session duration | ~3 hours |

---

## Tool Call Breakdown

| Tool | Calls | Impact |
|------|-------|--------|
| `bash` | 766 | Command output added to context each time |
| `view` | 233 | Large source files read into context |
| `task` (subagents) | 32 | Each returned 500–2,000 lines of output |
| `read_agent` | 31 | Full reviewer/architect output injected back |
| `read_bash` | 36 | Worker output read back into context |
| `grep` | 21 | File search results added to context |
| `glob` | 16 | File listings added to context |

---

## Root Causes (Ranked by Impact)

### 🔴 1. Context Snowball — ~80% of tokens

Copilot re-sends the **entire accumulated conversation history** on every assistant turn. With 870 events over 3 hours, the context grew exponentially:

- Turn 1: ~10K tokens in context
- Turn 100: ~100K tokens in context
- Turn 870: millions of tokens re-sent every time

A single never-reset session running 10+ architect → implement → review → fix loops caused this.

### 🔴 2. Verbose Subagent Output Injected Back (32 task calls)

Each `@devloop-architect` and `@devloop-reviewer` subagent returned 500–2,000 lines of output, which was read back via `read_agent` (31 calls) and added permanently to the growing context.

Reviewer verdicts alone averaged ~200 lines each across 10+ reviews.

### 🟡 3. 766 Bash Calls

Every `devloop work`, `devloop fix`, `npm run build`, git command, and teststop run returned output that was kept in the ever-growing context window.

### 🟡 4. Large Source Files Read 233 Times

Files like `database.ts` (3,000+ lines) and `server.ts` (1,300+ lines) were repeatedly read via `view` calls and added to context.

### 🟡 5. Long Session Summary at Start

The session started with a ~300-line prior checkpoint summary injected into the system prompt, re-sent on every single one of the 870 turns.

---

## Tasks Completed During This Session

| Task | Result | Approx. Loops |
|------|--------|---------------|
| Session rollback races | ✅ APPROVED 9/10 | 3 fix loops |
| EventTopic build fix | ✅ Direct commit | — |
| Config trailing newline trim | ✅ Direct commit | — |
| Slack dedup key fix | ✅ Direct commit | — |
| Token approve-after-reject | ✅ Direct commit | — |
| PID reuse race (TASK-20260604-004255) | ✅ APPROVED 9/10 | 1 fix loop |
| Hub stop inflight guard (TASK-20260604-004538) | 🔄 Fix in progress | 1+ fix loops |

---

## Why It Cost ~$10 Extra

Claude Sonnet 4.6 pricing is approximately **$3 per million input tokens**.

At 35.9M input tokens:
- **Estimated gross cost:** ~$108 token-equivalent
- **Covered by Copilot plan:** monthly included quota
- **Overage charged:** ~$10 USD (tokens beyond plan limit billed pay-as-you-go)

---

## How to Prevent This in Future Sessions

| Action | Savings Estimate |
|--------|-----------------|
| **Reset session every 2–3 tasks** (`/clear` or new session) | 60–70% reduction |
| **Truncate reviewer output** — verdict + bullet points only, not 200-line reports | 15–20% reduction |
| **Don't `read_agent` full output** — check verdict line only, skip verbose body | 10% reduction |
| **Run teststop earlier** — catch failures before running multiple fix loops | Fewer loops = less context |
| **Avoid reading large files repeatedly** — cache content in session state | 5–10% reduction |

### One-Line Root Cause

> DevLoop ran 10+ architect → implement → review → fix loops in a **single never-reset 3-hour session**, causing the context to balloon to **36.4 million tokens** and exceed the monthly Copilot plan quota.
