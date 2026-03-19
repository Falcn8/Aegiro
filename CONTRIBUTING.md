# Contributing to Aegiro

Thank you for contributing. External pull requests are welcome.

## Ways to contribute

- Bug reports and reproducible issue reports
- Documentation fixes and clarifications
- Tests and reliability improvements
- Feature improvements aligned with project scope

## Pull request guidelines

- Keep changes focused and avoid unrelated edits in one PR.
- For behavior changes, include tests when feasible.
- Keep commit messages clear and scoped (for example: `fix(cli): handle empty passphrase`).
- Update docs/help text when CLI behavior or on-disk format changes.
- If CLI behavior changes, rebuild release artifacts with:
  - `bash scripts/build.sh`
  - verify: `./dist/aegiro-cli --version` and `./dist/aegiro-cli --help`

## Development checks

- Build: `swift build`
- Test: `swift test`

## Licensing

By submitting a contribution, you agree to the contribution and assignment
terms in [LICENSE](LICENSE), including Section 4 (Contribution Assignment).
