<!-- Thanks for the PR. Please fill out the checklist below. -->

## Summary

<!-- 1–3 sentences on what changed and why. Link the issue: Closes #N -->

Closes #

## Acceptance criteria

<!-- Copy the issue's acceptance-criteria checklist and tick each box. -->

- [ ] criterion 1

## Verification

- [ ] `go build ./cmd/devloop-tui/...` passes locally
- [ ] `go test -count=1 ./cmd/devloop-tui/...` passes locally
- [ ] CI (`tui-ci`) is green
- [ ] For backend changes: `CHANGELOG.md` under `## Unreleased` updated
- [ ] Manual smoke (if UI): described in PR body

## Spec corrections referenced

<!-- If this issue's brief in `devloop-tui-redesign 3/` had errors, note the corrected reality (file paths, env vars, NDJSON event names). See the plan's "Spec corrections" table. -->

## Notes for reviewer

<!-- Anything reviewer should know: tradeoffs, follow-ups, risky areas. -->
