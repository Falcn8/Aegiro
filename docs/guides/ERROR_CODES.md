# Aegiro Error Codes

This document lists the support/error code scheme shown by Aegiro app and CLI.

## Format

Displayed format:

`<message> [Code: AEG-<PREFIX>-<NNN>]`

Code construction:

- `PREFIX` identifies the error family (domain/category).
- `NNN` is a zero-padded 3-digit number from the absolute error code value.
- Example: `NSError(domain: "Backup", code: -31, ...)` -> `AEG-BKP-031`.

Source of truth: `Sources/AegiroCore/ErrorPresentation.swift`.

## Family Prefixes

| Source | Prefix | Notes |
| --- | --- | --- |
| `AEGError.crypto` | `AEG-CRY-001` | Crypto/PQC failures. |
| `AEGError.io` | `AEG-IO-001` | I/O and process execution failures. |
| `AEGError.integrity` | `AEG-INT-001` | Integrity/validation failures. |
| `AEGError.unsupported` | `AEG-UNS-001` | Unsupported format/algorithm/version. |
| `NSError` domain `Backup` | `AEG-BKP-<NNN>` | Backup/restore archive flow. |
| `NSError` domain `ManifestIO` | `AEG-MAN-<NNN>` | Manifest loading/parsing. |
| `NSError` domain `VaultRead` | `AEG-VRD-<NNN>` | Low-level vault read flow. |
| `NSError` domain `VaultHeader` | `AEG-VHD-<NNN>` | Vault header parsing/format checks. |
| `NSError` domain `VaultSettings` | `AEG-VST-<NNN>` | Vault settings errors (prefix reserved). |
| `NSError` domain `Shred` | `AEG-SHD-<NNN>` | File shredding flow. |
| `NSError` domain `VaultModel` | `AEG-APP-<NNN>` | App-side validation/user input errors. |
| Other `NSError` domains | `AEG-<DOMAIN6>-<NNN>` | Fallback uses first 6 uppercase alnum chars from domain. |

## Known Codes in Current Source

### `Backup` (`AEG-BKP-*`)

| Raw code | Support code | Meaning |
| --- | --- | --- |
| `-1` | `AEG-BKP-001` | Backup output path matches vault path. |
| `-2` | `AEG-BKP-002` | Backup metadata too large to encode. |
| `-3` | `AEG-BKP-003` | Unable to create temporary backup/restore file. |
| `-4` | `AEG-BKP-004` | Backup payload copy incomplete. |
| `-10` | `AEG-BKP-010` | Backup magic mismatch (invalid format). |
| `-11` | `AEG-BKP-011` | Invalid backup metadata length. |
| `-12` | `AEG-BKP-012` | Backup payload truncated/incomplete. |
| `-20` | `AEG-BKP-020` | Unexpected EOF while reading backup. |
| `-30` | `AEG-BKP-030` | Restore output path matches backup path. |
| `-31` | `AEG-BKP-031` | Restore output already exists without overwrite. |
| `-32` | `AEG-BKP-032` | Restored payload hash mismatch. |

### `ManifestIO` (`AEG-MAN-*`)

| Raw code | Support code | Meaning |
| --- | --- | --- |
| `-1` | `AEG-MAN-001` | Unexpected EOF while loading manifest. |
| `-2` | `AEG-MAN-002` | Vault file too small. |
| `-3` | `AEG-MAN-003` | Vault header parse failed. |

### `VaultRead` (`AEG-VRD-*`)

| Raw code | Support code | Meaning |
| --- | --- | --- |
| `-1` | `AEG-VRD-001` | Invalid read length. |
| `-2` | `AEG-VRD-002` | Unexpected EOF while reading vault. |
| `-3` | `AEG-VRD-003` | Vault file too small. |
| `-4` | `AEG-VRD-004` | Vault header parse failed. |

### `VaultHeader` (`AEG-VHD-*`)

| Raw code | Support code | Meaning |
| --- | --- | --- |
| `-1` | `AEG-VHD-001` | Header blob too small. |
| `-2` | `AEG-VHD-002` | Header magic mismatch. |
| `-3` | `AEG-VHD-003` | Header length exceeds available bytes. |
| `-10` | `AEG-VHD-010` | Header probe blob too small. |
| `-11` | `AEG-VHD-011` | Header probe magic mismatch. |
| `-12` | `AEG-VHD-012` | Header parse failed (all formats). |

### `Shred` (`AEG-SHD-*`)

| Raw code | Support code | Meaning |
| --- | --- | --- |
| `1` | `AEG-SHD-001` | Could not open file handle for shredding. |

### `VaultModel` (`AEG-APP-*`)

| Raw code | Support code | Meaning |
| --- | --- | --- |
| `1` | `AEG-APP-001` | Missing container size. |
| `2` | `AEG-APP-002` | Missing container volume name. |
| `3` | `AEG-APP-003` | Missing recovery passphrase. |
| `4` | `AEG-APP-004` | Missing mount passphrase. |
| `5` | `AEG-APP-005` | Missing unmount target. |

## Maintenance Notes

- When adding a new `NSError` domain mapping in `ErrorPresentation.swift`, update this document in the same change.
- Keep existing support codes stable after release so support logs remain searchable over time.
