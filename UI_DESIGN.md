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
- View toggle, sorting menu, preferences on right.

2. Body split
- Left sidebar (260px): vault status, vault info, actions, security actions, external disk tools, selection summary.
- Right content: locked/empty/no-vault states plus list/grid file browser.

3. Bottom status bar
- Locked/unlocked pill.
- Files/selection counts.
- Auto-lock countdown.
- Active vault path.

## Primary Screens

1. First run (`FirstRunView`)
- Centered hero card.
- Create Vault and Open Existing actions.
- Inline create form (name/location/passphrase/confirm/Touch ID).
- Crypto reassurance copy: Argon2id, AES-256-GCM, and post-quantum cryptography.

2. Main app (`MainView`)
- Dark, card-based sidebar and high-contrast content area.
- File list and grid modes.
- Finder-style selection behavior:
  - Single click selects one file.
  - Command-click toggles multi-selection.
  - Shift-click selects ranges.
  - Grid view supports drag-to-select rectangle.
- Context menu: Preview, Export, Copy Path, Reveal Export.
- Drag-and-drop import to encrypt dropped files.
- Unlock sheet and external disk encrypt/unlock sheets.

3. Preferences (`PreferencesView`)
- Dark settings card.
- Default vault folder selector.
- Auto-lock presets + slider.
- Touch ID toggle.

4. Menu bar (`MenuBarView`)
- Dynamic icon state (locked/unlocked).
- Status summary and quick lock/unlock/import/export actions.

## Behavior Standards

- Security state is explicit in sidebar, status bar, and menu bar.
- Locked state blocks file operations and shows clear unlock call-to-action.
- Search filters by name, path, mime/type, and tags.
- Drag-and-drop imports only when vault is unlocked.
- Toast status feedback appears for key operations.

## Implementation Map

- `Sources/AegiroApp/AegiroTheme.swift`: color tokens
- `Sources/AegiroApp/FirstRunView.swift`: onboarding flow
- `Sources/AegiroApp/MainView.swift`: app shell, file browser, overlays, sheets
- `Sources/AegiroApp/PreferencesView.swift`: settings UI
- `Sources/AegiroApp/MenuBarView.swift`: menu bar companion
- `Sources/AegiroApp/VaultModel.swift`: dropped-file import helper

## Validation Checklist

- App builds (`swift build --target AegiroApp`).
- First run can create/open vaults.
- Lock/unlock flow works with passphrase and Touch ID when enabled.
- Import/export/quick look still function in redesigned shell.
- Drag-and-drop import works for local files.
