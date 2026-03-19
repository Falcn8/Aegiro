## Summary

- Describe what changed and why.

## Scope

- Type: `feat` / `fix` / `docs` / `refactor` / `build` / `test` / `chore`
- Area: `AegiroCLI` / `AegiroCore` / `AegiroApp` / `docs` / `scripts` / `dist`

## Validation

- [ ] Built locally with `bash scripts/build.sh` (when applicable)
- [ ] Verified `./dist/aegiro-cli --version` (when CLI behavior changed)
- [ ] Verified `./dist/aegiro-cli --help` (when CLI behavior changed)

## Required Checklist

- [ ] Change is atomic and focused (no unrelated edits)
- [ ] If `Sources/AegiroCLI` changed, `AEGIRO_CLI_VERSION` was bumped in `Sources/AegiroCLI/main.swift`
- [ ] If CLI behavior or on-disk format changed, help/docs were updated in the same PR
- [ ] If CLI behavior changed, updated `dist/` artifacts are included (`dist/aegiro-cli`, `dist/aegiro-cli-macos-arm64.tar.gz`)
- [ ] No secrets or credentials included

## Notes for Reviewers

- Breaking changes:
- Follow-up work:
