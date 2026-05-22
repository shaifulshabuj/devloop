# Providers & Failover

DevLoop separates two provider roles:

| Variable | Role | Used in phases |
|---|---|---|
| `DEVLOOP_MAIN_PROVIDER` | Architect, reviewer, orchestrator | Phase 1, 3, 5 |
| `DEVLOOP_WORKER_PROVIDER` | Implementer | Phase 2, 4 |

You set both in `devloop.config.sh`. Any compatible combination works.

## Supported combinations

| Main | Worker | Notes |
|---|---|---|
| `claude` | `copilot` | **Default.** Most tested. |
| `claude` | `claude` | Single-provider; useful when you only have Claude installed. |
| `copilot` | `copilot` | Single-provider Copilot. |
| `copilot` | `claude` | Reverse pairing. |
| `claude` | `opencode` | OpenCode as worker. |
| `claude` | `pi` | Pi as worker. |

`opencode` and `pi` are **worker-only** — they have no remote-control
session, so they can't run as main.

## Session capabilities

`devloop start` and `devloop daemon` behave differently based on the main
provider:

| Main provider | Session type |
|---|---|
| `claude` | **Remote-control** — drive from `claude.ai/code` or the Claude mobile app |
| `copilot` | **Remote** — drive from `github.com/copilot` or the GitHub mobile app |

Both modes prevent your Mac from sleeping via `caffeinate` while the
session is active.

## Models

For Claude roles, you control which model serves architect vs worker
independently:

```bash
# devloop.config.sh
CLAUDE_MODEL=sonnet              # base model for all roles
CLAUDE_MAIN_MODEL=opus           # overrides for architect/reviewer
CLAUDE_WORKER_MODEL=sonnet       # overrides for worker/fix
```

Available: `sonnet` (balanced), `opus` (most capable), `haiku` (fast/cheap).

Copilot's model is set at [github.com/settings/copilot](https://github.com/settings/copilot) —
there is no CLI flag.

## Auto-failover

When a provider returns a rate-limit error, DevLoop swaps it for the next
in chain. The original is probed every `DEVLOOP_PROBE_INTERVAL` minutes
(default `5`) and restored the moment it's available again — there's no
fixed wait time.

```text
Main chain:    claude → copilot
Worker chain:  copilot → opencode → pi
```

Enable / disable:

```bash
DEVLOOP_FAILOVER_ENABLED=true      # default
DEVLOOP_PROBE_INTERVAL=5           # minutes
```

Manage:

```bash
devloop failover status                    # show active overrides + recovery time
devloop failover reset                     # clear overrides, restore configured providers
devloop failover probe                     # test all providers right now
devloop failover main copilot              # force main to use copilot
devloop failover worker opencode           # force worker to use opencode
devloop failover worker clear              # clear worker override only
```

The active overrides are persisted in `.devloop/provider-health.sh` so a
restart preserves them — restart-safe by design.

## Provider context cache

`devloop agent-sync` fetches each provider's docs (CLI help, current
flags, model list) and caches them in `.devloop/agent-docs/` with a 24-hour
TTL. The orchestrator and architect personas read these caches to stay
current as provider CLIs evolve.

```bash
devloop agent-sync     # refresh now (also aliases: sync-agents, agentsync)
```

The cached docs flow into the architect's prompt as **Provider Context**
so the spec is grounded in what your installed providers actually support
today, not what they supported when devloop was last released.

## Troubleshooting

| Symptom | Diagnostic | Fix |
|---|---|---|
| "provider not found" | `which claude` / `which copilot` | Install the CLI; ensure it's on `$PATH` |
| "auth required" mid-run | `claude login` / `gh auth status` | Re-auth, then `devloop resume` |
| Stuck on rate-limit | `devloop failover status` | Failover should already have triggered; if not, `devloop failover probe` |
| Wrong model in use | `grep CLAUDE_.*MODEL devloop.config.sh` | Set `CLAUDE_MAIN_MODEL` / `CLAUDE_WORKER_MODEL` explicitly |
