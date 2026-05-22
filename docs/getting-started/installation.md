# Installation

DevLoop is a single bash script with an optional Go TUI. The script is
self-contained — no Python, no Node, no runtime to install. Pick the install
method that matches your environment.

## Install the script

=== "curl (recommended)"

    ```bash
    curl -fsSL https://raw.githubusercontent.com/shaifulshabuj/devloop/main/devloop.sh \
      -o /tmp/devloop
    chmod +x /tmp/devloop
    sudo mv /tmp/devloop /usr/local/bin/devloop
    devloop --version    # → DevLoop v5.3.0
    ```

=== "Per-user (no sudo)"

    ```bash
    mkdir -p ~/bin
    curl -fsSL https://raw.githubusercontent.com/shaifulshabuj/devloop/main/devloop.sh \
      -o ~/bin/devloop
    chmod +x ~/bin/devloop
    # Make sure ~/bin is on $PATH
    echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc
    ```

=== "From a clone"

    ```bash
    git clone https://github.com/shaifulshabuj/devloop.git ~/devloop
    cd ~/devloop
    ./devloop.sh install            # → /usr/local/bin/devloop
    ./devloop.sh install ~/bin/devloop   # or a custom path
    ```

## Enable self-update

Set the source URL once in `devloop.config.sh` (created by `devloop init`):

```bash
DEVLOOP_SOURCE_URL="https://raw.githubusercontent.com/shaifulshabuj/devloop/main/devloop.sh"
```

Then upgrade in place anytime:

```bash
devloop check    # see if a new version is on GitHub
devloop update   # self-upgrade + refresh project configs
```

## Install the TUI (optional)

The bash engine is fully usable without the TUI. For the live dashboard,
Focus Mode, and Command Palette, build the Go binary:

```bash
git clone https://github.com/shaifulshabuj/devloop.git
cd devloop
make tui-install        # builds cmd/devloop-tui and installs to ~/bin
```

Requires Go 1.21+. The TUI watches `.devloop/` and never writes to it —
the bash engine remains the source of truth.

## Provider CLIs

DevLoop drives external provider CLIs. Install at least one main provider
(`claude` or `copilot`); workers can be any of the four.

| Provider | Role | Install |
|---|---|---|
| **Claude Code** | Main or worker | `curl -fsSL https://claude.ai/install.sh \| bash` |
| **GitHub Copilot** | Main or worker | `npm install -g @github/copilot` |
| **OpenCode** | Worker only | `npm install -g opencode-ai` |
| **Pi** | Worker only | [pi.dev/docs/latest](https://pi.dev/docs/latest) |
| **GitHub CLI** | `github-agent` worker mode | `brew install gh` (or `apt install gh`) |

After installing a provider CLI, authenticate it once (`claude login`,
`gh auth login`, etc.) before running `devloop init`.

## Verify everything works

```bash
devloop doctor
```

`doctor` checks:

- `git` is on `$PATH`
- At least one configured provider CLI is reachable
- `devloop.config.sh` exists and is syntactically valid
- `.devloop/` directory is writable
- `gh` is installed if `DEVLOOP_WORKER_MODE=github-agent`
- Optional dependencies (`tmux`, `jq`) and their fallbacks

Fix anything it flags before running your first pipeline.

## What's next

- [Quickstart in 5 steps :material-arrow-right:](quickstart.md){ .md-button .md-button--primary }
- [Worked example: First Project](first-project.md){ .md-button }
