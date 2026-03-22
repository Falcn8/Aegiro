## Aegiro App UI System (2026 Redesign)

This document describes the current visual and interaction model for the macOS app.

## Design Goals

- Calm and trustworthy UI for sensitive data workflows.
- Security state is always visible (locked/unlocked/integrity warning).
- Local-first confidence with clear copy and minimal clutter.
- Fast file operations with list/grid browsing, drag-and-drop import, and quick actions.

## Visual Identity

- Display font: `Fraunces`
- Body/UI font: `Space Grotesk`
- Monospace/technical font: `JetBrains Mono`
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
- Create Vault, Open Existing, and USB Encryption actions.
- Inline create form (name/location/passphrase/confirm).
- Uses branded `LandingHero` image as full-screen background with dark overlay.
- Crypto reassurance copy: Argon2id, AES-256-GCM, and post-quantum cryptography.

2. Main app (`MainView`)
- Dark, card-based sidebar and high-contrast content area.
- No-vault empty state includes quick actions for Open Existing, Create Vault, and USB Encryption.
- File list and grid modes.
- Large vault unlock/load shows a dedicated loading state while the file list is resolved asynchronously.
- Vault file lists stream in paged chunks (with "load more" prefetch while scrolling) for large-vault responsiveness.
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
- List view renders files as an expandable folder tree derived from each entry's logical path.
- Users can create folders in the currently open vault directory from the sidebar action card and empty-folder state.
- Grid rows continue to show each file's parent path under the filename to disambiguate duplicates.
- Context menu: Preview, Export, Move, Copy Path, Reveal Export, Delete.
- Drag-and-drop import to encrypt dropped files.
- Added a "Move to Folder" workflow that supports moving selected files or a selected folder path into another vault directory.
- Unlock sheet plus a dedicated USB Encryption page (outside the vault shell) for external volume encryption workflows.
- Security card now includes `Check Integrity`, `Backup`, and `Restore` (`.aegirobackup` -> `.agvt`) workflows.
- External disk sheets only show external APFS candidates (never internal system volumes), default to mounted external APFS volumes (`/Volumes/...`), and include a "Show All External" fallback.
- Sheets include mounted non-APFS volumes inline in the same list; in USB-focused flows these rows are selectable across the full row hit area (not text-only), and in APFS-only flows they remain informational.
- Added "Encrypt USB Data" sheet for mounted non-APFS volumes: encrypts only user files into a `.agvt` vault file on the USB, skips known filesystem metadata, and can optionally delete originals after successful import.
- Disk encryption sheet uses a two-step flow (select external volume, then details) with a Continue action.
- Non-APFS encryption now shows live file progress (`processed / total`) while encrypting user data.
- APFS encryption progress remains volume/block-level from `diskutil` (percent + status message), because file-level counts are not exposed.
- Added a dedicated **USB Encryption** page that renders as its own screen (not inside the Open Vault shell).
- The USB page has one volume picker for APFS and non-APFS USB volumes, then an encryption option selector that explicitly covers:
  - `apfs-volume-encrypt` / `apfs-volume-decrypt`
  - `usb-vault-pack`
  - `usb-container-create` / `usb-container-open` / `usb-container-close`
- Vault Pack configuration includes a "Do Not Encrypt" file/folder exclusion picker so users can explicitly skip paths they do not want encrypted.
- Vault Pack excludes hidden files/folders by default during scan/encrypt, and the exclusion picker still shows hidden items so users can inspect/select them explicitly.
- Pressing Vault Pack Encrypt/Scan opens a dedicated progress screen with live logs, auto-scroll to newest entries, and inline cancel control.
- Vault Pack progress screen shows elapsed operation time (`mm:ss` / `h:mm:ss`) while running.
- Live debug logs support selection/copy, with a one-click copy action.
- If the target `.agvt` already exists, USB Encryption shows an overlap warning before run.

3. Preferences (`PreferencesView`)
- Dark settings card.
- Default vault folder selector.
- Auto-lock presets + slider.

## Behavior Standards

- Security state is explicit in sidebar and status bar.
- Locked state blocks file operations and shows clear unlock call-to-action.
- Search filters by name, path, mime/type, and tags.
- Search/sort projection is rebuilt asynchronously (with a short search debounce) to keep large-vault UI interactions responsive.
- When search text is active, remaining pages are prefetched so search covers the full vault.
- Drag-and-drop imports only when vault is unlocked.
- Toast status feedback appears for key operations.
- Each command-parity sheet keeps output visible in a copyable, monospaced area.
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
- Lock/unlock flow works with passphrase.
- Import/export/quick look still function in redesigned shell.
- Drag-and-drop import works for local files.
