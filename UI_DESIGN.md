## AegiroVault App — Modern Simplified UI

This document describes the current AegiroVault macOS app UI and interaction model.

## Design Intent

- Keep the workflow obvious: add to sidecar, then lock to import.
- Keep primary actions one-click: create vault, open vault, unlock, add files, lock/import, lock now, select files, export, and add Touch ID while unlocked.
- Keep visuals modern and calm with icon-led sections and clear hierarchy.
- Keep secondary controls available but not noisy.

## Visual System

- Palette (fixed):
  - `#8ECAE6` (ice blue)
  - `#219EBC` (teal blue)
  - `#023047` (deep navy)
  - `#FFB703` (sun yellow)
  - `#FB8500` (orange)
- Shared theme tokens live in `Sources/AegiroApp/AegiroTheme.swift`.
- Cards use rounded corners, soft strokes, and light gradients.
- SF Symbols are used for all major actions and status.
- Lock-state background is explicit:
  - Unlocked keeps the existing cool ice-blue feel
  - Locked shifts shell gradients to teal → orange

## Screen Model

1. First-run (`FirstRunView`)
- Modern hero + single card layout.
- Core actions:
  - Create new vault (location + passphrase + Touch ID option)
  - Open existing vault
- Messaging emphasizes local-first privacy and simple onboarding.

2. Main app (`MainView`)
- Two-pane shell:
  - Left: brand card, vault info card, workflow card, selected-file card, core action buttons
  - Right: top bar, list/grid content, status bar
- Vault info card surfaces key metadata:
  - File count (updates immediately after unlock)
  - Vault file size
  - Last edited timestamp
- Workflow card explicitly teaches:
  - 1) Add files to sidecar
  - 2) Import happens when locking
  - 3) Lock vault to finalize
- Unlocked-state actions include:
  - Lock vault even when sidecar is empty
  - Add Touch ID from the action panel
- Top bar keeps only essentials visible:
  - Search, list/grid toggle, sort controls, select files, quick look, export
- Select files is a toggle mode:
  - When enabled, files show circle selectors for multi-select
  - When disabled, list/grid return to normal browsing
- Selected file card adds direct actions:
  - Quick Look selected file(s)
  - Export selected file(s)
  - File metadata for single-selection (name, kind, size, modified, path)
- Content states are explicit:
  - No vault selected
  - Vault locked
  - Empty vault
  - File list/grid

3. Preferences (`PreferencesView`)
- Simple settings card with icons.
- Core controls:
  - Default vault folder
  - Auto-lock timeout presets + slider
  - Touch ID toggle

## UX References

This redesign follows interaction patterns commonly seen in major apps used by billions of users:

- File-centric clarity (Finder/Files style)
- Minimal command surfaces with overflow menus (Google Drive/Docs style)
- Card-based setup and settings (Notion/Slack style)

No brand assets or proprietary UI are copied; this is pattern-level inspiration only.

## Important Actions (must remain easy)

- Create vault
- Open vault
- Unlock vault
- Add files to sidecar
- Lock to import sidecar into encrypted vault
- Lock vault when already unlocked
- Add Touch ID while unlocked
- Export selected files
- Toggle selection mode and choose files inline before export

## Implementation Map

- `Sources/AegiroApp/AegiroTheme.swift`: shared color tokens and hex color helper
- `Sources/AegiroApp/FirstRunView.swift`: first-run create/open experience
- `Sources/AegiroApp/MainView.swift`: main shell, workflow UI, list/grid, quick actions
- `Sources/AegiroApp/PreferencesView.swift`: modern settings card

## Validation Checklist

- Build passes via `BuildProject`.
- First-run can create and open vaults.
- Main view keeps sidecar workflow clear and visible.
- Lock/Unlock, Import (sidecar), and Export remain functional.
