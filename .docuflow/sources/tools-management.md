# DevLoop v3.1.0 — Tools Management (MCP, Skills, Plugins, Instructions)

This document describes the `devloop tools` command family added in DevLoop v3.1.0.

---

## Overview

DevLoop v3.1.0 adds project-level tool management for both Claude Code and GitHub Copilot. The `devloop tools` command family discovers, recommends, installs, and syncs:

- **MCP servers** — Model Context Protocol servers for external integrations
- **Claude skills** — Reusable task templates that Claude invokes automatically or on demand
- **Claude plugins** — Third-party Claude extensions (global only; installed interactively)
- **Copilot path instructions** — File-glob-scoped instructions applied by Copilot in addition to repo-wide instructions

### Usage

```bash
devloop tools           # defaults to audit
devloop tools audit     # inventory: global vs project tools
devloop tools suggest   # stack-based recommendations
devloop tools add       # interactive picker
devloop tools sync      # copy global → project
```

---

## Tool Scope Hierarchy

DevLoop uses project-level tools first, then global as fallback:

| Tool | Global location | Project location |
|------|----------------|-----------------|
| MCP (Claude) | `~/.claude.json` (`mcpServers`) | `.mcp.json` (`mcpServers`) |
| MCP (Copilot) | VS Code user profile | `.vscode/mcp.json` (`servers`) |
| Skills | `~/.claude/skills/<name>/SKILL.md` | `.claude/skills/<name>/SKILL.md` |
| Plugins | `~/.claude/settings.json` `enabledPlugins` | global only (per-user) |
| Hooks | `~/.claude/settings.json` | `.claude/settings.json` |
| Path instructions | — | `.github/instructions/<name>.instructions.md` |

---

## Dual MCP Config Writing

**Key architecture decision:** Claude and Copilot/VS Code use different schemas for MCP server configuration. DevLoop automatically writes both when adding an MCP server:

**Claude `.mcp.json`** (uses `mcpServers` key):
```json
{
  "mcpServers": {
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp"]
    }
  }
}
```

**VS Code `.vscode/mcp.json`** (uses `servers` key with `type` field):
```json
{
  "servers": {
    "context7": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp"]
    }
  },
  "inputs": []
}
```

Both files are written in a single `devloop tools add --mcp` call.

---

## `devloop tools audit`

Shows a full inventory comparing global vs project tools. Highlights gaps.

```bash
devloop tools audit
```

Output sections:
- **Claude MCP Servers** — global list with `[in project ✔]` or `[global only — run sync]` labels; project `.mcp.json` list; VS Code `.vscode/mcp.json` list
- **Claude Skills** — global `~/.claude/skills/` vs project `.claude/skills/`
- **Claude Plugins** — global `enabledPlugins` list
- **Claude Hooks** — global vs project hook event names
- **Copilot Instructions** — `.github/copilot-instructions.md` status; path-specific instruction files

---

## `devloop tools suggest`

Reads `PROJECT_STACK` from `devloop.config.sh` and recommends tools relevant to the stack.

```bash
devloop tools suggest
```

Recommendation map (keyword matching, case-insensitive):

| Stack keyword | Recommended tools |
|--------------|-------------------|
| `typescript`, `javascript` | MCP: context7; Plugin: typescript-lsp; Instruction: tests, docs |
| `python` | MCP: context7; Plugin: pyright-lsp; Instruction: tests |
| `rust` | Plugin: rust-analyzer-lsp |
| `golang` | Plugin: gopls-lsp |
| `csharp`, `dotnet` | Plugin: csharp-lsp; Skill: code-review |
| `docker`, `container` | MCP: docker |
| `sentry` | MCP: sentry (HTTP transport) |
| `linear` | MCP: linear |
| `github` | MCP: github; Plugin: github; Skill: commit-message |
| `jira`, `atlassian` | Plugin: atlassian |
| `figma` | Plugin: figma |
| `playwright`, `testing`, `e2e` | Plugin: playwright |
| `postgres`, `mysql`, `sql`, `sqlite` | MCP: database; Skill: database-query |

Output shows colour-coded badges: `[MCP]` (blue), `[Plugin]` (magenta), `[Skill]` (green), `[Instruction]` (cyan).

---

## `devloop tools add`

Interactive numbered picker based on `devloop tools suggest` output. User selects by number, comma-separated list, or `all`. Type `q` to quit.

```bash
devloop tools add
```

Installation behaviour per type:
- **MCP**: writes `.mcp.json` + `.vscode/mcp.json` (both schemas, auto-translated)
- **Plugin**: prints `claude plugin install <name>@claude-plugins-official` (plugins require an interactive Claude session)
- **Skill**: scaffolds `.claude/skills/<name>/SKILL.md` with template
- **Instruction**: creates `.github/instructions/<name>.instructions.md` with glob `applyTo` frontmatter

### Explicit (non-interactive) flags

```bash
# Add an MCP server by name
devloop tools add --mcp context7 npx -y @upstash/context7-mcp

# Scaffold a Claude skill
devloop tools add --skill database-query "Safe SQL query and migration skill"

# Create a Copilot path instruction
devloop tools add --instruction tests "**/*.test.ts,**/*.spec.ts"

# Print plugin install command
devloop tools add --plugin playwright
```

---

## `devloop tools sync`

Interactively copies global tools down to the project level, one item at a time.

```bash
devloop tools sync
```

Behaviour:
- For each global MCP server: checks if already in project `.mcp.json`; if not, prompts `[y/N]`; on yes, reads command + args from `~/.claude.json` and writes both `.mcp.json` + `.vscode/mcp.json`
- For each global skill: checks if already in `.claude/skills/`; prompts `[y/N]`; on yes, `cp -r` from `~/.claude/skills/<name>/`

---

## Claude Skills

Skills are reusable task templates stored as markdown. Claude invokes them automatically when a request matches, or users can invoke with `/skill-name`.

**Scope precedence** (highest wins): enterprise > personal > project (same name). Different names coexist.

### Locations

| Scope | Location |
|-------|---------|
| Personal | `~/.claude/skills/<name>/SKILL.md` |
| Project | `.claude/skills/<name>/SKILL.md` |
| Plugin-bundled | `<plugin>/skills/<name>/SKILL.md` |

### Scaffold template

`devloop tools add --skill <name>` creates:
```markdown
# Skill: <name>

<description>

## When to use this skill
## Steps
1.
## Notes
```

---

## Copilot Path-Specific Instructions

Copilot supports file-glob-scoped instructions via `.github/instructions/*.instructions.md` files. These apply in addition to `.github/copilot-instructions.md` for matching files.

### Format

```markdown
---
applyTo: "**/*.test.ts,**/*.spec.ts"
---

# Instructions for: tests

Add test-specific Copilot guidance here.
```

### Creating path instructions

```bash
devloop tools add --instruction tests "**/*.test.ts,**/*.spec.ts"
devloop tools add --instruction docs "**/*.md,docs/**"
```

---

## `devloop doctor` Tools Section

`devloop doctor` now includes a tools summary section (informational, not pass/fail):

```
— MCP servers: 10 global / 2 project
— VS Code MCP servers (.vscode/mcp.json): 2
— Project skills (.claude/skills/): 0
— Path-specific Copilot instructions: 1
→ Run devloop tools audit for full details | devloop tools suggest for recommendations
```

---

## `devloop init` Integration

After `devloop init` completes, the next-steps list now includes:

```
4. Run devloop tools suggest for stack-specific MCP/skill recommendations
```

`PROJECT_STACK` in `devloop.config.sh` drives this — set it accurately for useful suggestions.
