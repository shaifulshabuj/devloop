# Session History

Per-session worklog entries written when a Claude / Copilot / human session
ships something substantial. Each file is a self-contained reference for a
future agent or maintainer who needs to understand:

- What was attempted
- What shipped (commits, issues, PRs)
- What was decided and why
- What was deferred or left open
- Where to start reading if picking up the thread

The goal is to compress a session's full conversation context into a single
document that future work can reference without having to replay the
session.

## Convention

- Filename: `YYYY-MM-DD-<slug>.md` (UTC date the session started)
- Each entry includes: scope, commits in order, files touched at high level,
  key decisions, open follow-ups, "how to pick up"
- Prefer concision — link to commits, issues, and live docs rather than
  duplicating their content

## Index

| Date | Session | Headline outcome |
|------|---------|------------------|
| 2026-05-22 | [tui-v5.3-release](./2026-05-22-tui-v5.3-release.md) | TUI Redesign v5.3 shipped end-to-end (4 phases, 18 commits, ~7k LOC), full doc pass, MCP cleanup |
