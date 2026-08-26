# Skill: devloop-plan-dev-test-review-fix-test-ok-release-skill

Unified DevLoop execution workflow for coding agents.

## When to use this skill

Use for feature work, bug fixes, and releases that should follow the full DevLoop loop:
plan → develop → test → review → fix → test → approve → release.

## Steps

1. **Plan**: confirm scope and create a concrete implementation checklist.
2. **Develop**: implement requested changes with minimal unrelated edits.
3. **Test**: run existing project tests/lint/build relevant to changed code.
4. **Review**: inspect diff for correctness, edge cases, and regressions.
5. **Fix**: address review findings.
6. **Test again**: rerun checks after fixes.
7. **OK**: ensure acceptance criteria are satisfied.
8. **Release**: bump version/changelog/docs when requested, then commit.

## Notes

- Prefer repository-native commands and patterns.
- Do not skip explicit error handling.
- Keep commits scoped and descriptive.
