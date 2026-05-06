# DocuFlow — AI Documentation Assistant

DocuFlow is an MCP server that provides structured access to this codebase and maintains a living wiki.
It is registered via `.codex/config.toml` and available as MCP tools in every Codex session.

## Available MCP Tools

### Codebase Scanner
- **read_module** — Analyse a single file: language, classes, functions, dependencies, DB tables, endpoints, config refs, raw content.
  - `read_module({ path: "src/UserService.cs" })`
- **list_modules** — Walk a directory, extract facts for every file. One call to understand the whole project.
  - `list_modules({ path: "/Volumes/SATECHI_WD_BLACK_2/mySysTools/devloop" })`
- **write_spec** — Save a markdown spec to `.docuflow/specs/<name>.md`.
  - `write_spec({ project_path: "/Volumes/SATECHI_WD_BLACK_2/mySysTools/devloop", filename: "UserService", content: "..." })`
- **read_specs** — Read saved specs, optionally filtered by name.
  - `read_specs({ project_path: "/Volumes/SATECHI_WD_BLACK_2/mySysTools/devloop" })`

### Wiki Pipeline
- **ingest_source** — Ingest a markdown file from `.docuflow/sources/` into the wiki (entities, concepts).
- **update_index** — Rebuild `.docuflow/index.md` from all wiki pages.
- **list_wiki** — List all wiki pages by category (entity/concept/timeline/synthesis).
- **wiki_search** — BM25 search across all wiki pages.
- **query_wiki** — Q&A: searches wiki, synthesises an answer, returns citations.
  - `query_wiki({ project_path: "/Volumes/SATECHI_WD_BLACK_2/mySysTools/devloop", question: "How does auth work?" })`
- **synthesize_answer** — Generate a markdown synthesis from a list of page IDs.
- **save_answer_as_page** — Persist a synthesis as a wiki page.

### Health & Guidance
- **lint_wiki** — Health check: orphan pages, broken refs, stale content. Returns a 0–100 health score.
- **get_schema_guidance** — Recommend what wiki pages should exist based on schema + current state.
- **preview_generation** — Preview what a tool will generate before running it.

## Common Workflows

Start here — understand the codebase:
```
list_modules({ path: "/Volumes/SATECHI_WD_BLACK_2/mySysTools/devloop" })
→ write_spec for important modules
```

Answer a question:
```
query_wiki({ project_path: "/Volumes/SATECHI_WD_BLACK_2/mySysTools/devloop", question: "..." })
```

Maintain wiki health:
```
lint_wiki({ project_path: "/Volumes/SATECHI_WD_BLACK_2/mySysTools/devloop" })
```

## Storage Layout

```
.docuflow/
├── specs/        Code specs written by write_spec
├── wiki/         LLM-generated wiki pages
│   ├── entities/
│   ├── concepts/
│   ├── timelines/
│   └── syntheses/
├── sources/      Raw markdown docs to ingest
├── schema.md     Wiki configuration (edit to customise)
├── index.md      Auto-maintained catalog
└── log.md        Operation log
```
