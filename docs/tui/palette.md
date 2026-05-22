# Command Palette

A Cmd-K style action launcher. Press `:` in the [Dashboard](dashboard.md)
or [Focus Mode](focus.md) to open.

## Layout

```text
┌─ : run            ─────────────────────────────────┐
│ ▸ run         devloop run "feature"               │
│   queue add   devloop queue add "feature"         │
│   resume      devloop resume                       │
│   sessions    devloop sessions --last 10          │
│ ...                                                │
└────────────────────────────────────────────────────┘
```

The selected action highlights as you type. `enter` runs it; `esc` cancels.

## Default actions

The palette ships with 18 actions covering the most-used CLI flows:

| Group | Actions |
|---|---|
| Pipeline | `run`, `queue add`, `queue run`, `resume`, `fix`, `review` |
| Inspection | `sessions`, `session`, `tasks`, `status`, `stats`, `replay` |
| Providers | `failover status`, `failover reset`, `agent-sync` |
| Permissions | `permit watch`, `permit grant`, `permit deny`, `permit mode` |

The current set is built from `internal/components/palette.go`.

## How execution works

The palette never spawns subprocesses directly from view code. Every
selected action becomes a `PaletteRun` message routed through `internal/app/app.go`,
which dispatches via `chat.dispatchShell`. This means:

- Permission rules apply the same way they would in a normal CLI call.
- Output streams back into the TUI's existing log view.
- There is a single, auditable entry point for shell execution.

## Customising

Actions are defined in code (`internal/components/palette.go`). To add or
remove entries, edit the slice and rebuild:

```bash
make tui-install
```

A future version may load palette entries from a YAML file. Today you
edit Go.

## Keys

| Key | Action |
|---|---|
| `:` | Open palette (from dashboard or focus mode) |
| any character | Filter actions |
| `↑ / ↓` | Move selection |
| `enter` | Run selected action |
| `esc` | Close palette |
