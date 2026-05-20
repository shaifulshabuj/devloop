# DevLoop v6 — Developer Setup & Contributing Guide

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Go | 1.22+ | [go.dev/dl](https://go.dev/dl) |
| golangci-lint | latest | `brew install golangci-lint` |
| GitHub CLI (`gh`) | 2.x+ | `brew install gh` |
| git | 2.x+ | pre-installed on macOS |

### Verify prerequisites

```bash
go version          # go1.22+
golangci-lint --version
gh auth status
git --version
```

---

## Clone & Build

```bash
git clone https://github.com/shaifulshabuj/devloop.git
cd devloop

# Build the v6 binary
make build

# Verify
./devloop --version   # devloop v6.0.0-dev
```

---

## Repository Layout

```
devloop/
├── cmd/
│   ├── devloop/          # v6 Go binary entry point
│   │   └── main.go
│   └── devloop-tui/      # v5 companion TUI (legacy — kept for reference)
├── internal/
│   ├── config/           # Config loading (global + project config.toml)
│   ├── tui/              # Bubble Tea TUI layer
│   ├── agent/            # Agent subprocess sessions + session pool
│   │   └── backends/     # Backend adapters (Claude, Copilot, OpenCode, Pi)
│   ├── storage/          # SQLite + file I/O
│   ├── orchestrator/     # Task analysis, plan generation, step dispatch
│   ├── git/              # Git integration (auto-commit, diff)
│   └── server/           # Optional local API server (Phase 4)
├── docs/
│   └── v6-design/        # Architecture & design specs
│       ├── 01-vision-and-goals.md
│       ├── 02-architecture.md
│       ├── 04-agent-system.md
│       ├── 06-build-phases.md
│       ├── 07-adr.md
│       └── 08-session-persistence.md
├── go.mod                # Root Go module: github.com/shaifulshabuj/devloop
├── go.work               # Go workspace (includes root + devloop-tui)
├── Makefile              # build/test/lint/install/clean
├── .golangci.yml         # Lint config (golangci-lint v2)
└── devloop.sh            # v5 bash engine (kept for v5 compatibility)
```

---

## Makefile Targets

| Target | What it does |
|--------|-------------|
| `make build` | Compile `./devloop` binary |
| `make test` | `go test ./... -race -count=1` |
| `make lint` | `golangci-lint run ./...` |
| `make install` | Install to `$GOPATH/bin/devloop` |
| `make clean` | Remove compiled binary |

---

## Development Workflow

```bash
# Create a feature branch
git checkout -b feat/my-feature

# Make changes, then:
make build          # verify it compiles
make test           # all tests pass
make lint           # no new lint issues
git commit -m "feat(#N): description"
```

---

## Contributing — Pull Request Checklist

Before opening a PR, verify:

- [ ] `make build` succeeds
- [ ] `make test` passes (`go test ./... -race -count=1`)
- [ ] `make lint` passes (0 issues on your new code)
- [ ] Commit message follows `feat(#N): description` format
- [ ] New packages have at least one test covering the primary behaviour
- [ ] No secrets, tokens, or personal paths in committed files

---

## Design Principles (read before coding)

1. **Subprocess streaming** — agent communication is `os/exec` + stdout. No MCP/HTTP.
2. **No auth required** — DevLoop needs no accounts; backends handle their own auth.
3. **4 first-class backends** — Claude, Copilot, OpenCode, Pi — all equal priority.
4. **Backend detection at startup** — silently skip missing binaries via `exec.LookPath`.
5. **Named sessions** — deterministic session IDs from project+role.
6. **SQLite + JSONL** — SQLite for structured data, JSONL for conversation history.
7. **Single binary** — `make build` produces one `devloop` binary with all features.
8. **Go 1.22+** — use modern Go: `range-over-int`, `slices`, `maps`.

Full rationale in [`docs/v6-design/07-adr.md`](docs/v6-design/07-adr.md).

---

## Running Tests

```bash
# All tests
make test

# Single package
go test ./internal/config/... -v

# With coverage
go test ./... -coverprofile=coverage.out
go tool cover -html=coverage.out
```

---

## Issue Labels

| Label | Meaning |
|-------|---------|
| `phase/1-foundation` | Phase 1 (Go scaffold, config, storage, TUI shell) |
| `phase/2-intelligence` | Phase 2 (Orchestrator, model routing, context) |
| `phase/3-platform` | Phase 3 (Personas, skills, TUI platform) |
| `phase/4-advanced` | Phase 4 (Parallel agents, remote control) |
| `ai-ready` | Fully specced — an AI agent can implement autonomously |
| `priority/critical` | Must complete before phase ships |

---

## Getting Help

- Design specs: `docs/v6-design/`
- GitHub Issues: <https://github.com/shaifulshabuj/devloop/issues>
- GitHub Project board: <https://github.com/users/shaifulshabuj/projects/6>
