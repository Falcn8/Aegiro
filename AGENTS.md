## Aegiro — Agent Workflow and Git Rules

This repo is designed for iterative, surgical improvements. Please follow these rules when making changes.

### Golden Rule: Commit Every Fix
- After each fix or change that improves behavior (code, config, build, docs), you must commit.
- Keep commits small, focused, and atomic. Do not batch unrelated changes.
- Use clear commit messages describing why + what (e.g., `fix(cli): guard args and add hint for missing --vault`).
- If a change affects the CLI or on‑disk format, update docs/help and include those in the same commit.

### CLI Version Rule
- Any change under `Sources/AegiroCLI` must also bump `AEGIRO_CLI_VERSION` in `Sources/AegiroCLI/main.swift`.

### Build and Dist
- Build and packaging:
  - `bash scripts/build.sh`
  - Script outputs: `dist/aegiro-cli` and `dist/aegiro-cli-macos-arm64.tar.gz` and prints a SHA256 checksum.
- Always use scripts from `scripts/` for release builds and packaging (do not run ad-hoc manual build/package commands).
- For macOS app releases, use:
  - `bash scripts/build-app-universal.sh --configuration release --ad-hoc` (or a signing identity)
  - `bash scripts/package-dmg.sh ...` for DMG creation
  - Use `assets/dmg-background.png` as the DMG background image (not `assets/aegiro-banner.png`) unless explicitly instructed otherwise.
- When CLI behavior changes, rebuild and commit updated `dist/` artifacts so users can install directly.
- Verify basic commands after builds:
  - `./dist/aegiro-cli --version`
  - `./dist/aegiro-cli --help`

### Suggested Commit Flow
1) Make a minimal, focused change.
2) Build locally (and run quick checks if applicable).
3) Stage + commit immediately:
   - `git add -A`
   - `git commit -m "<type(scope): short summary>"`
4) If the change modifies CLI behavior, rebuild dist and commit those artifacts in a follow‑up commit or in the same commit if the diff is small.

### Commit Message Conventions
- Use conventional prefixes when possible: `feat:`, `fix:`, `docs:`, `refactor:`, `build:`, `test:`, `chore:`
- Example: `feat(cli): add status --json and doctor --fix`

### Safety + Scope
- Prefer fixing root causes over patching symptoms.
- Don’t mix unrelated fixes in one commit.
- Keep changes consistent with existing style.
- Update help/docs when you add or modify commands.

### Quick References
- Build: `bash scripts/build.sh`
- Verify package: `shasum -a 256 dist/aegiro-cli-macos-arm64.tar.gz`
- Install binary (optional): `sudo install -m 0755 dist/aegiro-cli /usr/local/bin/aegiro`
- Basic smoke test: `./dist/aegiro-cli --help`

### Design Reference
- Follow `docs/guides/UI_DESIGN.md` for macOS app layouts, patterns, and UX principles. Keep the document updated when changing app UI.

### Do Not
- Do not commit secrets or credentials.
- Do not bundle network dependencies in code (use system libraries as configured).

By committing each fix, we preserve a clean history that is easy to bisect and review.
