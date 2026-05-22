# Changelog

All notable changes to DevLoop are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

The canonical source is [`CHANGELOG.md`](https://github.com/shaifulshabuj/devloop/blob/main/CHANGELOG.md)
in the repo — this page mirrors the current and previous releases. For
older entries, see the GitHub file or the [Releases](https://github.com/shaifulshabuj/devloop/releases)
page.

---

## [5.3.0] — 2026-05-22

**TUI Redesign.** `devloop-tui` graduates from a rough side-binary into a
first-class user surface. Dashboard, Focus Mode, Command Palette, and an
Onboarding Wizard land together — plus the backend hooks they consume.

CLI behaviour is unchanged. The redesign is purely additive: `devloop-tui`
is opt-in, and the existing `devloop run/work/review/fix` commands keep
running exactly as before.

### Added — TUI (`cmd/devloop-tui`)

- **Dashboard** with provider top bar, fuzzy task filter, collapsible
  SPEC and DIFF side panels, and stuck-task detection.
- **Focus Mode** — single-task full-screen view with LOG / SPEC / DIFF /
  PERMIT tabs, phase track, and `←/→` task navigation.
- **Command Palette** — 18 default actions, dispatched through a single
  audited shell entry point.
- **Onboarding Wizard** — first-run setup wraps `devloop init` and
  `devloop doctor` in a guided flow.

### Added — engine

- `phase.escalate` event emitted when the fix loop exhausts its retry
  budget and re-architect kicks in. The TUI subscribes to this to flip
  the active phase card.
- Permission queue formalised at `.devloop/permission-queue/<UUID>.json`
  with a contract documented in [Events Stream](reference/events.md).

### Changed

- `devloop` with no arguments now launches the dashboard by default.
  Set `DEVLOOP_DEFAULT_VIEW=help` to restore the old behaviour.

---

## [5.2.0] — 2026-05-12

- Auto-failover restored — main and worker chains, configurable probe
  interval, restart-safe overrides in `provider-health.sh`.
- `devloop agent-sync` introduced — 24h-TTL cache of provider docs.
- `devloop resume` rebuilt around session events for safe re-entry.

## [5.1.0] — 2026-05-08

- `devloop do` natural-language entry point.
- Smart Permissions modes (`off`/`auto`/`smart`/`strict`).
- Fix escalation strategy (`escalate` vs `standard`).

## [5.0.0] — 2026-04-XX

- Multi-provider architecture: `claude`, `copilot`, `opencode`, `pi`.
- `github-agent` worker mode.
- Session viewer + replay.

---

For the full historical changelog see
[`CHANGELOG.md`](https://github.com/shaifulshabuj/devloop/blob/main/CHANGELOG.md)
or the [Releases](https://github.com/shaifulshabuj/devloop/releases) page.
