## Aegiro App UI System (2026 Redesign)

This document describes the current visual and interaction model for the macOS app.

## Design Goals

- Calm and trustworthy UI for sensitive data workflows.
- Security state is always visible (locked/unlocked/integrity warning).
- Local-first confidence with clear copy and minimal clutter.
- Fast file operations with list/grid browsing, drag-and-drop import, and quick actions.

## Visual Identity

- Primary accent: `#4F46E5` (indigo)
- Security highlight: `#10B981` (emerald)
- Warning: `#F59E0B` (amber)
- Danger: `#EF4444` (red)
- Main background: `#0F172A`
- Panel background: `#111827`
- Card background: `#1F2937`
- Borders: `#374151`

Theme tokens are centralized in `Sources/AegiroApp/AegiroTheme.swift`.

## Layout

Main window uses a three-zone shell:

1. Top bar
- Vault identity and lock status at left.
- Centered search field.
- View toggle, sorting menu, file info button, preferences on right.

2. Body split
- Left sidebar (260px): vault status, vault info, actions, security actions, external disk tools.
- Right content: locked/empty/no-vault states plus list/grid file browser.

3. Bottom status bar
- Locked/unlocked pill.
- Files/selection counts.
- Auto-lock countdown.
- Active vault path.

## Primary Screens

1. First run (`FirstRunView`)
- Centered hero card.
- Create Vault, Open Existing, and Encrypt Disk actions.
- Inline create form (name/location/passphrase/confirm/Touch ID).
- Crypto reassurance copy: Argon2id, AES-256-GCM, and post-quantum cryptography.

2. Main app (`MainView`)
- Dark, card-based sidebar and high-contrast content area.
- No-vault empty state includes quick actions for Open Existing, Create Vault, and Encrypt Disk.
- File list and grid modes.
- Finder-style selection behavior:
  - Single click selects one file.
  - Clicking the same selected item again deselects it.
  - Command-click toggles multi-selection.
  - Shift-click selects ranges.
  - List and grid views support drag-to-select rectangle.
  - Up/Down arrow keys move selection to previous/next item.
  - Shift+Up/Shift+Down extends range selection from the anchor.
- Space bar opens Quick Look for the current selection.
- File details are shown from a top-bar Info popover.
- Context menu: Preview, Export, Copy Path, Reveal Export, Delete.
- Drag-and-drop import to encrypt dropped files.
- Unlock sheet and external disk encrypt/unlock sheets.
- Security card keeps one integrity entry point (`Check Integrity`) that opens the doctor sheet, plus Touch ID enable action.
- External disk sheets only show external APFS candidates (never internal system volumes), default to mounted external APFS volumes (`/Volumes/...`), and include a "Show All External" fallback.
- Sheets include mounted non-APFS volumes inline in the same list as gray, disabled rows so users can see them but cannot select them.
- Added "Encrypt USB Data" sheet for mounted non-APFS volumes: encrypts only user files into a `.agvt` vault file on the USB, skips known filesystem metadata, and can optionally delete originals after successful import.
- Disk encryption sheet uses a two-step flow (select external volume, then details) with a Continue action.
- Non-APFS encryption now shows live file progress (`processed / total`) while encrypting user data.
- APFS encryption progress remains volume/block-level from `diskutil` (percent + status message), because file-level counts are not exposed.

3. Preferences (`PreferencesView`)
- Dark settings card.
- Default vault folder selector.
- Auto-lock presets + slider.
- Touch ID toggle.

## Behavior Standards

- Security state is explicit in sidebar and status bar.
- Locked state blocks file operations and shows clear unlock call-to-action.
- Search filters by name, path, mime/type, and tags.
- Drag-and-drop imports only when vault is unlocked.
- Toast status feedback appears for key operations.
- If keychain entitlements are missing in a dev build, Touch ID controls are disabled with explicit guidance text.
- Passphrase policy: required minimum stays `8+` chars with uppercase, lowercase, and a number; the meter marks `Strong` at `12+` chars with `3+` character types, or `20+` chars.

## Implementation Map

- `Sources/AegiroApp/AegiroTheme.swift`: color tokens
- `Sources/AegiroApp/FirstRunView.swift`: onboarding flow
- `Sources/AegiroApp/MainView.swift`: app shell, file browser, overlays, sheets
- `Sources/AegiroApp/PreferencesView.swift`: settings UI
- `Sources/AegiroApp/VaultModel.swift`: dropped-file import helper

## Validation Checklist

- App builds (`swift build --target AegiroApp`).
- First run can create/open vaults.
- Lock/unlock flow works with passphrase and Touch ID when enabled.
- Import/export/quick look still function in redesigned shell.
- Drag-and-drop import works for local files.
