---
allowed-tools: [Read, Write, Edit, Bash, Glob, Grep]
description: "Generate structured wiki documentation for this project using the DocuFlow pipeline. Covers architecture, CLI, agents, config, and setup docs written to .docuflow/wiki/."
---

# /docuflow-document — DevLoop Documentation Generator

Generate or update structured wiki pages for this project using the DocuFlow wiki pipeline.

## Usage

```
/docuflow-document [target] [--type concept|entity|synthesis] [--all]
```

### Arguments

| Argument | Description |
|----------|-------------|
| `target` | What to document: a command, agent, concept name, or file path |
| `--type` | Wiki category: `concept` (design/flow), `entity` (named thing), `synthesis` (cross-cutting) |
| `--all` | Regenerate all 5 core docs from scratch |
| `--update` | Update an existing page to reflect current code |
| `--index` | Rebuild `.docuflow/index.md` from all wiki pages |

## Established Wiki Structure

Five core documents exist in this project under `.docuflow/wiki/`:

| # | File | Category | Covers |
|---|------|----------|--------|
| 1 | `concepts/pipeline-architecture.md` | concept | Three-agent loop, session modes, data flow, key invariants |
| 2 | `entities/cli-commands.md` | entity | All CLI commands with args, flags, outputs, examples |
| 3 | `entities/agents.md` | entity | orchestrator, architect, reviewer — roles, models, output formats |
| 4 | `concepts/configuration.md` | concept | All `devloop.config.sh` keys with types, defaults, examples |
| 5 | `concepts/setup-installation.md` | concept | Prerequisites, quickstart, gitignore, troubleshooting |

## Execution Workflow

### Step 1 — Identify scope

For `--all`: regenerate all 5 core docs.
For a specific target: determine which existing page it belongs to, or whether a new page is needed.

```bash
# Check what already exists
ls .docuflow/wiki/concepts/ .docuflow/wiki/entities/
cat .docuflow/index.md
```

### Step 2 — Read current source of truth

Always read the actual source before writing docs — never rely on memory of a previous run.

```bash
# For CLI or implementation changes
cat devloop.sh | head -200        # version, constants, helpers
grep "^cmd_" devloop.sh           # all command functions

# For agent changes
ls .claude/agents/
cat .claude/agents/devloop-orchestrator.md
cat .claude/agents/devloop-architect.md
cat .claude/agents/devloop-reviewer.md

# For config changes
cat devloop.config.sh
```

### Step 3 — Try DocuFlow MCP tools first

If the DocuFlow MCP server is available in this session, prefer its tools:

```
list_modules({ path: "/Volumes/SATECHI_WD_BLACK_2/mySysTools/devloop" })
```

Then use `write_spec` to persist structured analysis, and `ingest_source` + `update_index` to rebuild the wiki.

If DocuFlow MCP tools are not available (they won't appear in ToolSearch), proceed directly to Step 4.

### Step 4 — Write wiki page directly

Use the standard frontmatter format for all wiki pages:

```markdown
---
title: "Page Title"
category: concept | entity | synthesis | timeline
tags: [tag1, tag2, tag3]
created: YYYY-MM-DD
updated: YYYY-MM-DD   # add when updating an existing page
---

# Page Title

[content]
```

Write to the correct subdirectory:
- Design patterns, flows, principles → `.docuflow/wiki/concepts/`
- Named things (commands, agents, APIs) → `.docuflow/wiki/entities/`
- Cross-cutting answers → `.docuflow/wiki/syntheses/`
- Chronological events → `.docuflow/wiki/timelines/`

### Step 5 — Update the index

After writing any page, update `.docuflow/index.md`. The index format uses the DocuFlow auto-maintained structure — preserve the `Generated:` header and `By Category` sections. Add a row for any new page; update descriptions for revised pages.

## Writing Standards

### Content rules
- Lead with a 1–2 sentence summary of what the page covers before any headings
- Use tables for command arguments, config keys, agent comparisons — avoid bullet walls
- Include runnable shell examples for every command or workflow
- Link to related pages using relative paths: `[Configuration Reference](../concepts/configuration.md)`
- State invariants explicitly (e.g. "the architect never modifies files")

### What belongs in each category

**concept** — non-obvious design decisions, flows between components, principles that aren't visible from the code alone. Examples: pipeline architecture, daemon restart logic, remote control setup.

**entity** — exhaustive reference for a named thing users interact with. Examples: CLI commands, agent definitions, config keys. Should be complete enough to use without reading the code.

**synthesis** — answers a cross-cutting question by pulling from multiple entities/concepts. Examples: "How does a feature request become a git commit?", "What happens when Copilot fails?"

## Updating Existing Pages

When `devloop.sh` is modified (new command, changed behavior, new agent):

1. Read the changed section of `devloop.sh`
2. Identify which wiki page(s) are affected
3. Open the existing page and make targeted edits — do not rewrite the whole page
4. Add `updated: YYYY-MM-DD` to frontmatter
5. Update `.docuflow/index.md` description if the scope changed

## Example Invocations

```
/docuflow-document                               # show what exists, suggest what's stale
/docuflow-document --all                         # regenerate all 5 core docs
/docuflow-document "daemon command" --type entity
/docuflow-document "devloop-architect" --update  # refresh agent doc after prompt change
/docuflow-document --index                       # rebuild index only
```

## Notes from Initial Generation (2026-05-06)

- DocuFlow MCP tools were unavailable in the session — all pages written directly via Write tool
- The DocuFlow `index.md` was subsequently auto-updated by the MCP server (preserved its format)
- All 5 core docs written from `devloop.sh` + `README.md` as single source of truth
- `devloop.sh` is ~1,100 lines — read in 250-line chunks to cover the full command set
- The README.md (11KB) contains the canonical command reference; cross-check it when updating CLI docs
