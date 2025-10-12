## AegiroApp — Modern UI Redesign

This document captures the macOS app design for Aegiro. It is the single source of truth for UI/UX decisions and should be kept up‑to‑date as the app evolves.

---

## Design Goals

- Trust & Calm: minimal chrome, clear security state, non‑modal feedback.
- One‑handed flows: open → unlock → import → lock/export, with obvious next steps.
- Fast at scale: big vaults stay snappy (lazy lists, incremental filtering).
- Native: keyboard shortcuts everywhere; system icons, materials, and typography.
- Accessible: VoiceOver‑friendly labels, Dynamic Type, high‑contrast compliance.

---

## Information Architecture

### Primary navigation (left sidebar)

- Vault
  - Header capsule with vault name, lock state chip, manifest status chip
  - "Pending Imports" (sidecar), with count badge
- Filters
  - All Files
  - Recently Added
  - Recently Modified
  - Tags (chips, collapsible)
- Actions
  - Open Vault…
  - Add Files…
  - Export…
  - Lock / Unlock
  - Preferences…

### Content (right)

- Toolbar
  - Lock/Unlock primary button
  - Add, Export
  - Search field (live filter with debounce)
  - View toggle: List / Grid
  - Sort menu: Name, Size, MIME, Modified (asc/desc)
- Content area
  - List view: 4‑column table (Name, Size, MIME, Modified) with Quick Look on double‑click
  - Grid view: adaptive thumbnails with filename + size; space toggles selection
  - Info drawer (optional): collapsible right pane showing metadata & actions
- Status bar
  - Count of items, selection summary, total selected size

### First-run onboarding

- Layout: split-pane card (left: hero badge + 3 succinct value bullets, right: form)
- Copy: keep lines under ~60 characters; prefer short phrases over sentences to avoid overload.
- Form fields
  - Vault location picker with inline “Choose…” button
  - Passphrase field with strength helper and optional hint (requires ≥8 chars)
  - Touch ID toggle w/ Secure Enclave note (one line)
- Primary action: “Create Vault” (prominent); secondary “Open Existing…” link below
- Responsive: card clamps to window bounds; scrolls vertically on small heights to prevent overflow.
- Footer: single-line local-only reminder and privacy link

### Secondary surfaces

- Unlock Sheet
  - Passphrase field, Face/Touch ID hint (if flag set), backoff help text when rate-limited
- Toasts (non‑blocking)
  - Imported N files to sidecar, Exported N files, Auto‑locked, Errors
- Preferences
  - Defaults folder picker
  - Auto‑lock TTL slider w/ presets (1–60 minutes)
  - “Allow Touch ID” toggle (device‑local explanation)

---

## Visual Language

- Color: neutral background; security state chip (green/amber/red) uses SF Symbols + semantic colors (`.green`, `.yellow`, `.red`).
- Materials: `.thinMaterial` toolbar/header; accent via system `tint`.
- Density: comfortable by default, compact row height option in View menu.
- Motion: subtle transitions on lock/unlock, tag edit, and grid/list switch.

---

## Interaction Details

- Quick Look: double‑click row or `Space` to preview; `⌘Y` also opens.
- Context menu on items: Quick Look, Export…, Reveal in Finder, Reveal Original, Copy name/path, Edit tags → inline token field.
- Drag & drop files into window to import (sidecar); shows drop target overlay.
- Keyboard
  - `⌘O` Open, `⌘I` Import, `⌘E` Export, `⌘L` Lock/Unlock, `⌘F` Search
  - Arrow keys navigate; `Space` select; `⌘A` select all

---

## Implementation Map

- Core model
  - `Sources/AegiroApp/VaultModel.swift`: create/open, unlock/lock, import/export, status, preferences (default dir, auto‑lock TTL), Quick Look support, activity monitors.
- Primary views
  - `Sources/AegiroApp/MainView.swift`: Sidebar, toolbar (sort/filter), List/Grid, footer, context menus, Quick Look triggers, Info drawer.
  - `Sources/AegiroApp/PreferencesView.swift`: Default vault folder, auto-lock slider, Touch ID toggle.
  - `Sources/AegiroApp/MenuBarView.swift`: Lock/Unlock, Add, Export, Preferences.
  - `Sources/AegiroApp/QuickLook.swift`: QLPreviewPanel coordinator for multi-item preview.
  - `Sources/AegiroApp/FirstRunView.swift`: Split onboarding, vault creation form, first-run helper links.
  - `Sources/AegiroApp/AppMain.swift`: App entry, Settings (Preferences), Vault command menu.
- Core helpers (AegiroCore)
  - `Editor.updateTags` (in `Vault.swift`): applies tag updates and re‑signs manifest.
  - `VaultLayout`, `computeLayout`, `parseHeaderAndOffset`: internal layout helpers used by doctor/editor logic.

---

## Accessibility & Localization

- All interactive controls should have `accessibilityLabel` and hover `help` text.
- Respect Dynamic Type and color contrast; test in Light/Dark Modes.
- Strings routed via `Localizable.strings` for future i18n.

---

## Performance Notes

- Use Table/LazyVGrid where appropriate; consider a small icon cache by file extension.
- Debounce search input (e.g., 150ms) for very large vaults.
- Avoid blocking the main thread for heavy crypto I/O; lift to background when necessary.

---

## Future Enhancements

- Tag editing UI backed by `Editor.updateTags`.
- Dedupe and SHA256 display in Info drawer.
- Touch ID/Keychain gating for PDK.
- Rich Quick Look navigation and annotations.
