# Repository Structure

This page explains the main folders and which ones are source-of-truth vs generated.

## Source of truth (tracked)

- `Sources/`: Swift source for app, CLI, and core crypto modules.
- `Tests/`: unit/integration tests.
- `docs/`: project documentation (`explanations`, `guides`, `legal`, `archive`).
- `scripts/`: build and packaging scripts.
- `ThirdParty/`: third-party notices and pkg-config shims.
- `assets/`: static project assets.
- `dist/`: checked-in CLI release artifacts used for direct installation.

## Generated or local-only folders

- `.build/`: SwiftPM build output cache and intermediate artifacts.
- `.swiftpm/`: local Swift Package Manager/Xcode workspace metadata.

`/.build` and `/.swiftpm` are local machine state and should not be committed.

## Top-level reference files

- `README.md`: project overview and quick links.
- `AGENTS.md`: repository workflow instructions for coding agents.
- `LICENSE.txt`: legal terms and ownership boundaries.
- `SECURITY.md`: security contact/process notes.
