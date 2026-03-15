<h1 align="center">
  Aegiro
</h1>

<p align="center">
  <strong>Local-only encrypted vault for macOS</strong><br>
  <sub>Argon2id • AES-256-GCM • Post-quantum key protection</sub>
</p>

<p align="center">
  <a href="https://github.com/aegiro-project/Aegiro"><img src="https://img.shields.io/badge/GitHub-AegiroMaintainer%2FAegiro-181717?style=flat-square&logo=github" alt="GitHub"></a>
  <img src="https://img.shields.io/badge/Platform-macOS-000000?style=flat-square&logo=apple" alt="Platform macOS">
  <img src="https://img.shields.io/badge/Language-Swift-F05138?style=flat-square&logo=swift" alt="Swift">
  <img src="https://img.shields.io/badge/Format-AGVT%20v2-2f6feb?style=flat-square" alt="AGVT v2">
</p>

<p align="center">
  <a href="#quick-start">Quick Start</a> •
  <a href="#protection-modes">Protection Modes</a> •
  <a href="#docs-map">Docs Map</a> •
  <a href="#build">Build</a>
</p>

---

## What Is This?

Aegiro is a local-first encrypted vault system for macOS:

- CLI + app workflows for encrypted vault operations
- AGVT v2 storage format with chunked encrypted file data
- APFS disk encryption support with recovery bundles
- Portable USB container flow for non-APFS filesystems
- Non-APFS USB file packing into `.agvt` via `usb-vault-pack`

---

## Protection Modes

| Mode | Commands | Best for | Notes |
|---|---|---|---|
| APFS volume encryption | `apfs-volume-encrypt` / `apfs-volume-decrypt` | Dedicated APFS external drives | In-place APFS encryption using `diskutil` |
| Portable encrypted container | `usb-container-create` / `usb-container-open` / `usb-container-close` | exFAT/FAT/NTFS/APFS USB drives | Encrypted APFS sparsebundle stored on host filesystem |
| Non-APFS file-level vault packing | `usb-vault-pack` | Existing non-APFS USB media | Packs user files into AGVT vault file (`data.agvt`) |

---

## Quick Start

```bash
# Build REAL_CRYPTO package (recommended)
bash scripts/build-real.sh
./dist/aegiro-cli --version

# Create a vault
./dist/aegiro-cli create --vault ~/AegiroVaults/alpha.agvt --passphrase "<pass>"

# Import files
./dist/aegiro-cli import --vault ~/AegiroVaults/alpha.agvt --passphrase "<pass>" ~/Downloads/file.pdf

# List and export
./dist/aegiro-cli list --vault ~/AegiroVaults/alpha.agvt --passphrase "<pass>"
./dist/aegiro-cli export --vault ~/AegiroVaults/alpha.agvt --passphrase "<pass>" --out ~/Recovered
```

---

## Core CLI

```text
create, import, delete, lock, unlock, list, export, preview
backup, verify, status, doctor, scan, shred
apfs-volume-encrypt, apfs-volume-decrypt
usb-container-create, usb-container-open, usb-container-close
usb-vault-pack
```

Use `./dist/aegiro-cli --help` for full options.

---

## Build

### REAL_CRYPTO (recommended)

```bash
brew install liboqs argon2 openssl@3
bash scripts/build-real.sh
```

Outputs:

- `dist/aegiro-cli`
- `dist/aegiro-cli-macos-arm64.tar.gz`

### Dev build (STUB_CRYPTO)

```bash
swift build -c release
.build/release/aegiro-cli --help
```

---

## Docs Map

Jump between project markdown pages:

- [Format Spec (AGVT v2)](SPEC_AGVT_V2.md)
- [USB Encryption Schematics](USB_ENCRYPTION_SCHEMATICS.md)
- [USB Encryption Diagrams](USB_ENCRYPTION_DIAGRAMS.md)
- [App UI Design](UI_DESIGN.md)
- [Contributing Guide](CONTRIBUTING.md)
- [Contributor CLA](CLA.md)
- [Agent Workflow Rules](AGENTS.md)

---

## Notes

- Default file-count limit per vault: `1,000` (`AEGIRO_MAX_FILES_PER_VAULT` to override).
- Non-APFS metadata paths are skipped in USB user-data flow.
- All encryption workflows are local; no telemetry endpoints are used by default.

---

## License

This project uses a custom source-available license in [LICENSE.txt](LICENSE.txt).

- GitHub collaboration and pull requests are allowed.
- Redistribution or republication (including App Store listings and DMG/binary distribution) is not allowed.
- Contributions are assigned to the project owner under the license terms.
