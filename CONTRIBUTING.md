# Contributing to Aegiro

Thank you for contributing to Aegiro.

This project accepts public collaboration through GitHub issues and pull
requests, under the repository license and contribution terms.

## Before You Start

- Read [LICENSE.txt](LICENSE.txt).
- Read [CLA.md](CLA.md).
- Do not submit code you do not have rights to contribute.

## Contribution Scope

You are welcome to contribute:

- bug fixes
- security hardening
- tests
- documentation improvements
- UX and app-flow improvements consistent with `UI_DESIGN.md`

## Workflow

1. Fork the repository on GitHub.
2. Create a focused branch for one change.
3. Keep changes small and atomic.
4. Open a pull request using the PR template.
5. Complete all required acknowledgment fields in the PR.

## CLI Versioning Rule

- Any change under `Sources/AegiroCLI` must bump `AEGIRO_CLI_VERSION` in `Sources/AegiroCLI/main.swift`.
- Pull requests and pushes to `main` are checked by `.github/workflows/cli-version-guard.yml`.
- You can run the same guard locally with:
  - `bash scripts/check-cli-version-bump.sh HEAD~1`

## Legal Terms for Contributions

By submitting any Contribution (including a pull request), you agree to the
assignment and license terms in:

- Section 4 of [LICENSE.txt](LICENSE.txt)
- [CLA.md](CLA.md)

If you do not agree with those terms, do not submit a Contribution.

## Distribution Reminder

This project is source-available with collaboration rights, but redistribution
and republication are restricted by [LICENSE.txt](LICENSE.txt), including
distribution through app stores, DMG packages, or other third-party channels.
