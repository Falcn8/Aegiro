# Set Aegiro as Default App for `.agvt` and `.aegirobackup` on macOS

Use this when double-clicking vault files opens the wrong app (or does nothing).

## 1) Show filename extensions in Finder (recommended)

1. Open Finder.
2. In the menu bar, click `Finder` -> `Settings` (or `Preferences` on older macOS).
3. Open the `Advanced` tab.
4. Enable `Show all filename extensions`.

This makes it easy to confirm you are working with `.agvt` and `.aegirobackup` files.

## 2) Set Aegiro as default for `.agvt`

1. In Finder, select any file ending in `.agvt`.
2. Press `Command + I` (or right-click -> `Get Info`).
3. Expand `Open with`.
4. Choose `Aegiro` from the app list.
5. Click `Change All...` and confirm.

macOS applies this association to all `.agvt` files.

## 3) Set Aegiro as default for `.aegirobackup`

Repeat the same steps above with a `.aegirobackup` file, then click `Change All...`.

This is a separate file type, so it must be set once on its own.

## 4) If Aegiro is missing in the app list

1. In `Open with`, choose `Other...`.
2. Browse to `/Applications/Aegiro.app` (or your Aegiro app location).
3. Select it, then click `Change All...`.

## 5) Quick verification

1. Double-click a `.agvt` file.
2. Double-click a `.aegirobackup` file.
3. Both should open with Aegiro.
