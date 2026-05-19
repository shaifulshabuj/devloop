# DevLoop v6 — Design Documents

This directory contains the formal design for DevLoop v6.0, a full rewrite of
DevLoop as a standalone AI development platform.

## Documents

| File | Description |
|------|-------------|
| [01-vision-and-goals.md](./01-vision-and-goals.md) | Problem statement, design goals, non-goals |
| [02-architecture.md](./02-architecture.md) | System architecture, components, data flow |
| [03-tui-design.md](./03-tui-design.md) | Terminal UI layout, interaction model |
| [04-agent-system.md](./04-agent-system.md) | Agent model, personas, skills, model routing |
| [05-storage.md](./05-storage.md) | SQLite schema, file layout, git integration |
| [06-build-phases.md](./06-build-phases.md) | Phased implementation plan |
| [07-adr.md](./07-adr.md) | Architecture Decision Records |
| [08-session-persistence.md](./08-session-persistence.md) | Named persistent sessions per project |

## Status

> **Status:** Draft — design phase  
> **Branch:** `design/v6-interactive-platform`  
> **Context:** Born from analysis of DevLoop v5.x limitations (non-interactive agents,
> no shared context, rigid pipeline, bash-only).

## Quick Summary

DevLoop v6 is a **full Go rewrite** — a single binary that is its own TUI platform.
Claude and Copilot become **engines** (any role, any agent), not the face.
The AI decides the workflow. DevLoop manages the context, history, and UI.
