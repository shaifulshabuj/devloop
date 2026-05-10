# DocuFlow — AI Documentation Assistant

DocuFlow is an MCP server that gives you structured access to this codebase and maintains a living wiki.
It is registered in your Claude Desktop config and available as MCP tools in every session.

## Codebase Scanner Tools

- **read_module** — Analyse a single source file. Returns language, classes, functions, dependencies, DB tables, endpoints, config refs, and raw content (first 8 KB).
  - Example: `read_module({ path: "src/UserService.cs" })`
- **list_modules** — Walk a directory and extract facts for every non-binary file. Use this to understand the full project in one call.
  - Example: `list_modules({ path: "/Volumes/SATECHI_WD_BLACK_2/mySysTools/devloop" })`
- **write_spec** — Persist a markdown spec to `.docuflow/specs/<filename>.md` and update the index.
  - Example: `write_spec({ project_path: "/Volumes/SATECHI_WD_BLACK_2/mySysTools/devloop", filename: "UserService", content: "# UserService\n..." })`
- **read_specs** — Read previously written specs, optionally filtered by name.
  - Example: `read_specs({ project_path: "/Volumes/SATECHI_WD_BLACK_2/mySysTools/devloop" })`

## Wiki Pipeline Tools

- **ingest_source** — Ingest a markdown file from `.docuflow/sources/` and generate wiki pages (entities, concepts).
- **update_index** — Rebuild `.docuflow/index.md` from all wiki pages.
- **list_wiki** — List all wiki pages, optionally filtered by category (entity/concept/timeline/synthesis).
- **wiki_search** — BM25 search across all wiki pages. Returns ranked results with previews.
- **query_wiki** — One-stop Q&A: searches wiki, synthesises an answer, returns source citations.
- **synthesize_answer** — Generate a markdown synthesis from a list of specific wiki page IDs.
- **save_answer_as_page** — Persist a synthesised answer back into the wiki (knowledge compounding).

## Health & Guidance Tools

- **lint_wiki** — Health check: orphan pages, broken refs, stale content, metadata gaps. Returns a 0–100 health score.
- **get_schema_guidance** — Analyse what wiki pages should exist based on the schema and current state.
- **preview_generation** — Preview what a tool will do before running it.

## Common Workflows

### First time — understand the codebase
```
list_modules({ path: "/Volumes/SATECHI_WD_BLACK_2/mySysTools/devloop" })
→ read the language breakdown and dependency map
→ write_spec each important module
```

### Ongoing — answer a question
```
query_wiki({ project_path: "/Volumes/SATECHI_WD_BLACK_2/mySysTools/devloop", question: "How does authentication work?" })
→ save_answer_as_page if the answer is worth keeping
```

### Maintenance — check wiki health
```
lint_wiki({ project_path: "/Volumes/SATECHI_WD_BLACK_2/mySysTools/devloop" })
→ fix orphans and broken refs
```

## Storage Layout

```
.docuflow/
├── specs/           Legacy spec files written by write_spec
├── wiki/            LLM-generated wiki pages
│   ├── entities/    Named things (services, APIs, databases)
│   ├── concepts/    Design patterns, principles, integrations
│   ├── timelines/   Chronological pages
│   └── syntheses/   Cross-cutting synthesis pages
├── sources/         Raw input files for ingest_source
├── schema.md        Wiki configuration (edit to customise)
├── index.md         Auto-maintained catalog
└── log.md           Operation log
```

## Agent Provider Context
_See `.devloop/agent-docs/provider-context.md` for the full provider reference._
_Run `devloop agent-sync` to refresh docs and check for provider updates._


<!-- waymark -->
---
# ⚠️ WAYMARK ACTIVE — MANDATORY INSTRUCTIONS

## You are operating under Waymark agent control

Waymark is active in this project (devloop).
All file and shell operations MUST go through
Waymark MCP tools. No exceptions.

## MANDATORY tool usage

You MUST replace ALL built-in file and shell
operations with Waymark MCP equivalents:

| Operation              | Built-in (DO NOT USE) | Waymark (ALWAYS USE) |
|------------------------|-----------------------|----------------------|
| Write or edit a file   | write_file            | mcp__waymark-devloop__write_file |
| Read a file            | read_file             | mcp__waymark-devloop__read_file  |
| Run shell commands     | bash / run_command    | mcp__waymark-devloop__bash       |

This applies to ALL tasks in this project —
refactoring, creating files, running tests,
installing packages, git operations, everything.

## What Waymark does with each action

- Allowed paths → executes normally, logged
- Blocked paths → stopped, you will see why
- Sensitive paths → held for human approval,
  do not retry, tell the user to check dashboard

## If a Waymark tool returns a block decision

Accept the block. Do not attempt to work around it
using built-in tools. Tell the user what was blocked
and why. Suggest they update waymark.config.json
if the block was unintended.

## If Waymark MCP tools are unavailable

Do NOT fall back to built-in file tools.
Stop and tell the user:

"Waymark MCP server is not running for this project.
Please run in your terminal:
  npx @way_marks/cli start

Then restart Claude Code and try again."

## Dashboard

Pending and recent actions are visible in the
Waymark dashboard. Run `npx @way_marks/cli status`
to see the current dashboard URL for this project.
Approve pending actions there. Roll back any write there.

## This file was generated by Waymark
Do not delete or modify this file.
It controls how Claude Code behaves in this project.
---
