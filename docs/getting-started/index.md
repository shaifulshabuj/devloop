# Getting Started

This section walks you from "never heard of DevLoop" to "running the
pipeline on my own project" in three short pages.

| Page | What you'll learn |
|---|---|
| [Installation](installation.md) | Install `devloop` globally, satisfy the provider CLI requirements, verify with `devloop doctor` |
| [Quickstart](quickstart.md) | The 5-step flow from `devloop init` to your first approved feature |
| [First Project](first-project.md) | A worked example: a real feature request, the spec, the review, the fix loop |

If you only have 30 seconds, the [TL;DR](#tl-dr) is below.

---

## TL;DR { #tl-dr }

```bash
# 1. Install
curl -fsSL https://raw.githubusercontent.com/shaifulshabuj/devloop/main/devloop.sh \
  -o /tmp/devloop && chmod +x /tmp/devloop && sudo mv /tmp/devloop /usr/local/bin/devloop

# 2. Set up your project
cd your-project/
devloop init           # interactive wizard, detects stack
devloop doctor         # verify everything is wired up

# 3. Run a feature
devloop run "add date-range filter to the orders endpoint"
```

That's it. The architect designs a spec, the worker implements it, the
reviewer approves or loops back for a fix. You can watch live with
`devloop` (the dashboard) or replay the session afterwards.

---

## Prerequisites

| Tool | Role | Required? |
|---|---|---|
| `bash` 4+ | Engine | Always |
| `git` | Pipeline operates on git diffs | Always |
| `claude` | Main or worker provider | One of these is required |
| `copilot` | Main or worker provider | One of these is required |
| `gh` | GitHub Agent worker mode | Only for `github-agent` mode |
| `opencode` / `pi` | Worker-only providers | Optional |
| `tmux` | Live `devloop view` dashboard | Optional |

DevLoop runs on macOS and Linux. Windows users should use WSL.
