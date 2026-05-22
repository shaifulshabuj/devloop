# Smart Permissions

DevLoop intercepts every shell command the provider tries to run through
Claude's `PreToolUse` hook. Commands are classified into three buckets:
**allow**, **block**, **escalate**.

This is opt-in per project: `devloop hooks` installs the necessary
`.claude/settings.json` and hook scripts.

## Modes

Set `DEVLOOP_PERMISSION_MODE` in `devloop.config.sh`:

| Mode | Behavior |
|---|---|
| `smart` (default) | Block dangerous, allow safe, escalate everything else |
| `auto` | Allow everything (fastest, no interruptions) |
| `strict` | Allow safe ops only, block everything else + ask user |
| `off` | Disable the hook entirely (Claude's default) |

## Always blocked

Regardless of mode, these are hard-blocked:

- `rm -rf /` or `rm -rf ~`
- `curl ... | bash` (or `wget ... | sh`)
- `dd` writes to `/dev/sd*`
- `mkfs.*`
- `sudo rm -rf ...`

If you have a legitimate need for any of these, run them outside the
pipeline.

## Always allowed

Safe inspection and routine dev commands skip the hook:

- `cat`, `grep`, `find`, `ls`, `head`, `tail`, `wc`, `awk`, `sed` (read-only)
- `git status`, `git log`, `git diff`, `git show`, `git branch`
- `pytest`, `npm test`, `cargo test`, `go test`, `make test`
- Build commands: `npm run build`, `cargo build`, `go build`, `make`
- Package install from a lockfile: `npm ci`, `pip install -r ...`, `cargo install --locked`
- Linters and formatters

Edit `.devloop/permissions.yaml` to add project-specific allows or denies.

## Escalation

Unknown commands escalate. DevLoop tries three escalation channels in order:

1. **Terminal prompt** via `/dev/tty` — works in foreground sessions.
2. **macOS dialog** via `osascript` — works in `devloop daemon` mode.
3. **Queue file** at `.devloop/permission-queue/<UUID>.json` — picked up by
   `devloop permit watch` on Linux / headless / mobile.

After `DEVLOOP_PERMISSION_TIMEOUT` seconds (default `60`) without a
response, the command is **auto-denied**.

## Managing escalations

```bash
devloop permit status            # show pending requests
devloop permit watch             # interactive prompt for pending requests
devloop permit grant [id]        # allow latest (or named) pending request
devloop permit deny [id]         # deny latest (or named) pending request
devloop permit log               # view audit log
devloop permit mode auto         # switch to auto mode (no escalations)
```

The TUI dashboard surfaces pending permits with a yellow chip
(`⚑ N pending`) and the Focus Mode has a dedicated `PERMIT` tab when the
queue is non-empty.

## `permissions.yaml`

Per-project allow/deny lists live at `.devloop/permissions.yaml`. Edit
with:

```bash
devloop permissions    # opens the file in $EDITOR
```

Example:

```yaml
allow:
  - "docker compose up*"
  - "make migrate"
  - "yarn workspaces foreach run lint"
deny:
  - "drop database*"
  - "rm -rf node_modules"   # in this project we use yarn cache clean instead
escalate:
  # everything else not in the global allow list
```

## Audit log

Every classified command lands in `.devloop/permissions.log` with a
timestamp, classification, and the originating task ID. Tail it during a
run to see what's being requested:

```bash
devloop permit log              # pretty-print
tail -F .devloop/permissions.log   # raw
```

## Recommended configuration by environment

| Environment | Mode | Notes |
|---|---|---|
| Local dev, solo | `smart` | Default. Tune `permissions.yaml` over time. |
| Long-running daemon | `smart` | Use `devloop permit watch` in tmux pane (or rely on macOS dialog) |
| Daemon on a Linux server | `smart` | Use the queue file + watch from a remote shell |
| CI runner | `auto` | The runner is ephemeral; the danger surface is low |
| Sensitive prod-adjacent repo | `strict` | Force every unknown command through review |
