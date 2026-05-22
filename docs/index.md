---
hide:
  - navigation
  - toc
---

<div class="dl-hero" markdown>

# DevLoop

<p class="tagline">
A single shell script that orchestrates Claude, Copilot, OpenCode, and Pi
into a fully automated <strong>design → implement → review → fix</strong> loop —
remote-controllable, self-healing, provider-flexible.
</p>

<p class="badges">
  <img alt="version" src="https://img.shields.io/badge/version-5.3.0-6a0dad">
  <img alt="license" src="https://img.shields.io/badge/license-MIT-blue">
  <img alt="platform" src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey">
  <img alt="shell" src="https://img.shields.io/badge/shell-bash-1f425f">
</p>

[Get Started :material-rocket-launch:](getting-started/quickstart.md){ .dl-btn .dl-btn-primary }
[View on GitHub :fontawesome-brands-github:](https://github.com/shaifulshabuj/devloop){ .dl-btn .dl-btn-secondary }

</div>

```bash
curl -fsSL https://raw.githubusercontent.com/shaifulshabuj/devloop/main/devloop.sh \
  -o /tmp/devloop && chmod +x /tmp/devloop && sudo mv /tmp/devloop /usr/local/bin/devloop
```

---

## What it does

You type a feature request — from your phone, your laptop, anywhere your
provider's web client runs — and DevLoop drives the whole loop:

```text
You (mobile / browser — anywhere)
         ↓  "add order filtering by date range"
Main provider  (architect + reviewer: Claude or Copilot)
         ↓  precise implementation spec
Worker provider (implementer: Claude | Copilot | OpenCode | Pi)
         ↓  commit
Main provider  (reviews git diff vs spec)
         ↓
  APPROVED ✅  or  loop back for fixes ⚠️
         ↓  auto-failover if any provider hits its rate limit
```

---

## Why DevLoop

<div class="dl-features" markdown>

<div class="dl-feature" markdown>
### :material-cellphone-link: Remote-control
Run `devloop start` once, then drive the whole pipeline from
claude.ai/code or your Claude/Copilot mobile app. No SSH, no tmux gymnastics.
</div>

<div class="dl-feature" markdown>
### :material-swap-horizontal: Mix & match providers
Use **Claude** as the architect, **Copilot** as the worker — or any of
the 6 supported provider combinations. Workers can be Claude, Copilot,
OpenCode, or Pi.
</div>

<div class="dl-feature" markdown>
### :material-shield-refresh: Self-healing
Provider hits its rate limit? DevLoop auto-fails-over to the next in chain
(`claude → copilot`, `copilot → opencode → pi`) and restores the original
the moment it's available again.
</div>

<div class="dl-feature" markdown>
### :material-checkbox-multiple-marked-circle: Smart permissions
`PreToolUse` hooks classify every shell command: block dangerous,
allow safe, escalate the rest to terminal / macOS dialog / queue file.
Configurable per project.
</div>

<div class="dl-feature" markdown>
### :material-television: First-class TUI
A Bubble Tea dashboard, Focus Mode, and Command Palette
(`devloop` with no args). Watch every phase live or replay the logs after.
</div>

<div class="dl-feature" markdown>
### :material-brain: Learning loop
`devloop learn` extracts lessons from approved reviews and appends them
to `CLAUDE.md` (project) or `~/.devloop/lessons.md` (global, stack-matched).
The next architect run sees them.
</div>

</div>

---

## Quick install

=== "macOS / Linux"

    ```bash
    curl -fsSL https://raw.githubusercontent.com/shaifulshabuj/devloop/main/devloop.sh \
      -o /tmp/devloop
    chmod +x /tmp/devloop && sudo mv /tmp/devloop /usr/local/bin/devloop
    devloop --version
    ```

=== "Per-project (no sudo)"

    ```bash
    curl -fsSL https://raw.githubusercontent.com/shaifulshabuj/devloop/main/devloop.sh \
      -o ./devloop && chmod +x ./devloop
    ./devloop install ~/bin/devloop   # picks a writeable location
    ```

Then run `devloop init` inside any project — it auto-detects your stack,
walks you through the setup wizard, and you're ready in under a minute.

[Full installation guide :material-arrow-right:](getting-started/installation.md){ .md-button }
[Quickstart in 5 steps :material-arrow-right:](getting-started/quickstart.md){ .md-button .md-button--primary }

---

<div class="dl-quote" markdown>
DevLoop turns a single feature request into a closed-loop pipeline —
architect → worker → reviewer → fix — without you having to stay at the keyboard.
</div>
