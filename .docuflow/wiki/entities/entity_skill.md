---
created_at: 2026-05-07T10:20:08.894Z
updated_at: 2026-05-07T10:20:08.894Z
sources: ["tools-management"]
tags: ["entity"]
inbound_links: ["source_tools_management"]
outbound_links: []
---

# Skill

**Type:** entity

## Overview

| Tool | Global location | Project location |
|------|----------------|-----------------|
| MCP (Claude) | ~/.claude.json (mcpServers) | .mcp.json (mcpServers) |
| MCP (Copilot) | VS Code user profile | .vscode/mcp.json (servers) |
| Skills | ~/.claude/skills/<name>/SKILL.md | .claude/skills/<name>/SKILL.md |
| Plugins | ~/.claude/settings.json enabledPlugins | global only (per-user) |
| Hooks | ~

*Introduced in: tools-management*