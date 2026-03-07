# Aegiro (macOS) — Local-only, PQC-ready encrypted vault

> **Status**: Working CLI with REAL_CRYPTO support, chunked in‑vault storage, manifest verification, direct encrypted import flow, list/export/preview/doctor commands; SwiftUI app remains scaffolded.  
> **Crypto**: **Argon2id + Kyber512 + Dilithium2** in REAL_CRYPTO mode (system `libargon2`/`liboqs`). STUB_CRYPTO remains available for local runs (HKDF/ECDSA).

## Quick Start

```bash
# Build and package (recommended)
bash scripts/build-real.sh
./dist/aegiro-cli --version

# 1) Create a new vault
./dist/aegiro-cli create --vault ~/AegiroVaults/alpha.agvt --passphrase "<pass>"

# 2) Import files (written directly into encrypted vault storage)
./dist/aegiro-cli import --vault ~/AegiroVaults/alpha.agvt --passphrase "<pass>" ~/Downloads/tax.pdf ~/Desktop/passport.jpg
# (The CLI skips importing the vault file itself and legacy sidecar paths.)

# 3) (Optional) lock command for legacy staged-data cleanup/import
./dist/aegiro-cli lock --vault ~/AegiroVaults/alpha.agvt --passphrase "<pass>"

# 4) List entries
./dist/aegiro-cli list --vault ~/AegiroVaults/alpha.agvt --passphrase "<pass>" [--long]

# 5) Export entries
./dist/aegiro-cli export --vault ~/AegiroVaults/alpha.agvt --passphrase "<pass>" --out ~/Recovered [filters...]
```

---

## What’s here

- **AegiroCore** (Swift library): Vault header/index/manifest per spec, chunked AES-256-GCM I/O, nonce scheme, wrappers for KDF & PQC, secure preview temp policy, shredder, privacy monitor, “secure lock” scriptables, zero-telemetry guard.
- **AegiroCLI** (Swift exec): End-to-end CLI: `create`, `import`, `lock`, `unlock`, `list`, `export`, `preview`, `doctor`, `backup`, `verify`, `status`, `scan`, `shred`, `disk-encrypt`, `disk-unlock`.
- **AegiroApp** (SwiftUI stubs): First-run flow, main UI, menubar helper, Settings — wired to core APIs (dev-mode). XPC/LaunchAgent stubs included.
- **Entitlements & Hardened Runtime**: prefilled.
- **Tests**: Acceptance checks (some are integration stubs pending REAL_CRYPTO).

This repo follows the plan you provided (sections 0–23).

---

## Build

### Requirements

- Xcode 15+ (Swift 5.9+), macOS 13+
- No network required at runtime. (Zero telemetry enforced via allowlist tests.)

### Quick build (dev, uses STUB_CRYPTO)

```bash
cd Aegiro
swift build -c release
.build/release/aegiro-cli --help
```

### Install (binary)

If you have the packaged binary (`dist/aegiro-cli-macos-arm64.tar.gz`):

```bash
# 1) Verify checksum (should match the value below)
shasum -a 256 dist/aegiro-cli-macos-arm64.tar.gz

# 2) Extract
tar -xzf dist/aegiro-cli-macos-arm64.tar.gz -C /tmp

# 3) Install into your PATH (pick one)
sudo install -m 0755 /tmp/aegiro-cli /usr/local/bin/aegiro
# or
sudo mv /tmp/aegiro-cli /usr/local/bin/aegiro && sudo chmod 0755 /usr/local/bin/aegiro

# 4) Run
aegiro --help
```

Checksum for the current archive:

```
5ae6bc72d08bc2bbef67d9e897d5846abdd66487c054d055aafb5349e800dbab  dist/aegiro-cli-macos-arm64.tar.gz
```

### REAL_CRYPTO build (Argon2id + liboqs)

1) Install dependencies (macOS):
```bash
brew install liboqs argon2 openssl@3
```

2) Build and package (recommended):
```bash
bash scripts/build-real.sh
./dist/aegiro-cli --help
```

The script produces `dist/aegiro-cli` and `dist/aegiro-cli-macos-arm64.tar.gz` and prints a SHA256 checksum.

> REAL_CRYPTO uses SwiftPM `systemLibrary` targets (`Sources/Argon2C`, `Sources/OQSWrapper`, `Sources/OpenSSLShim`) and links against system libraries.

### macOS app build (dev)

```bash
bash scripts/build-app-dev.sh
open -n dist/AegiroApp.app
```

- If a signing identity exists, the script signs with it automatically.
- If none exists, the script uses ad-hoc signing and prints Touch ID limitations.
- You can force identity selection: `bash scripts/build-app-dev.sh --identity "<identity name>"`.
- `--launch` opens the newly built app instance immediately.
- `--kill-running` stops existing `AegiroApp` processes first (enabled automatically by `--launch`).

---

## CLI examples

```bash
# Create a new vault
.build/release/aegiro-cli create --vault ~/AegiroVaults/alpha.agvt --passphrase "correct horse battery staple" --touchid

# Import files (direct encrypted write)
.build/release/aegiro-cli import --vault ~/AegiroVaults/alpha.agvt --passphrase "<pass>" ~/Downloads/tax.pdf ~/Desktop/passport.jpg

# Lock (legacy staged-data cleanup/import) / unlock
.build/release/aegiro-cli lock --vault ~/AegiroVaults/alpha.agvt --passphrase "<pass>"
.build/release/aegiro-cli unlock --vault ~/AegiroVaults/alpha.agvt --passphrase "<pass>"

# List / Export / Preview
.build/release/aegiro-cli list --vault ~/AegiroVaults/alpha.agvt --passphrase "<pass>" [--long]
.build/release/aegiro-cli export --vault ~/AegiroVaults/alpha.agvt --passphrase "<pass>" --out ~/Recovered [filters...]
.build/release/aegiro-cli preview --vault ~/AegiroVaults/alpha.agvt --passphrase "<pass>" passport

# Backup export
.build/release/aegiro-cli backup --vault ~/AegiroVaults/alpha.agvt --out ~/Backups/alpha_2025-10-04.aegirobackup

# Privacy scan + suggest moves
.build/release/aegiro-cli scan --targets ~/Downloads ~/Desktop

# Secure shred
.build/release/aegiro-cli shred ~/Downloads/secret.zip

# Verify manifest
.build/release/aegiro-cli verify --vault ~/AegiroVaults/alpha.agvt

# Status
.build/release/aegiro-cli status --vault ~/AegiroVaults/alpha.agvt --passphrase "<pass>"

# Status (JSON)
.build/release/aegiro-cli status --vault ~/AegiroVaults/alpha.agvt --passphrase "<pass>" --json

# External APFS volume encryption + unlock (PQC recovery bundle)
.build/release/aegiro-cli disk-encrypt --disk disk9s1 --passphrase "<recovery-pass>" --recovery ~/Backups/disk9s1.aegiro-diskkey.json
.build/release/aegiro-cli disk-unlock --disk disk9s1 --recovery ~/Backups/disk9s1.aegiro-diskkey.json --passphrase "<recovery-pass>"

# Portable encrypted container on any writable USB filesystem (exFAT/FAT/NTFS/APFS)
.build/release/aegiro-cli usb-container-create --image /Volumes/MyUSB/aegiro-portable.sparsebundle --size 16g --name "AegiroUSB" --passphrase "<container-pass>"
.build/release/aegiro-cli usb-container-mount --image /Volumes/MyUSB/aegiro-portable.sparsebundle --passphrase "<container-pass>"
.build/release/aegiro-cli usb-container-unmount --target "/Volumes/AegiroUSB"

Example text output:

```text
Vault Info
File count: 2
Vault size: 24 KB (24028 bytes)
Last edited: 5 Mar 2026 at 11:52:08 AM

Status
Locked: no
Sidecar pending: 0
Manifest: OK
Touch ID: disabled
```

Example JSON output:

```json
{
  "touchIDEnabled" : false,
  "vaultLastModified" : "2026-03-05T02:52:08Z",
  "vaultSizeBytes" : 24028,
  "locked" : false,
  "entries" : 2,
  "sidecarPending" : 0,
  "manifestOK" : true
}
```

# Doctor (check, optional fix)
.build/release/aegiro-cli doctor --vault ~/AegiroVaults/alpha.agvt [--passphrase "<pass>"] [--fix]
```

---

## External Disk Encryption

- `disk-encrypt` targets APFS volumes (`diskutil apfs encryptVolume`) and creates a PQC recovery bundle JSON.
- `disk-unlock` recovers the APFS unlock passphrase from that bundle and unlocks with `diskutil apfs unlockVolume`.
- Recovery bundle flow: passphrase KDF unwraps Kyber secret key; Kyber decapsulation derives shared secret; shared secret unwraps the APFS passphrase.
- Use `--dry-run` to generate/validate bundle logic without changing disk state.
- Requires ownership/admin permissions for the target disk as enforced by `diskutil`.

Full step-by-step schematics, key material tables, and threat-model notes are in **[USB_ENCRYPTION_SCHEMATICS.md](USB_ENCRYPTION_SCHEMATICS.md)**.

## Portable USB Container Encryption

- `usb-container-create` creates an encrypted APFS sparsebundle using `hdiutil` (AES-256) at a path on your USB.
- `usb-container-mount` mounts that encrypted container and returns its mount point/device.
- `usb-container-unmount` detaches the mounted container by mount path or disk identifier.
- This is the safe path for non-APFS USB formats (for example, exFAT): you keep the host filesystem and store an encrypted APFS container file on it.
- Unlike `disk-encrypt`, this does not encrypt the physical USB block device in place.

---

## Spec conformance (highlights)

- **AES-256-GCM**: CryptoKit-based, 96-bit nonces, **HMAC(fileNonceSeed, chunkIndex)[:12]**.
- **Argon2id**: REAL_CRYPTO uses `libargon2`. STUB_CRYPTO uses HKDF-SHA256 placeholder (clearly labeled).
- **Kyber512 + Dilithium2**: Interfaces via `liboqs`. STUB_CRYPTO uses ECDH(E25519) + ECDSA for demo-signing.
- **Header**: Matches field layout (see `VaultHeader.swift`). Versioning & alg IDs included.
- **Index**: Encrypted AEAD; filename hashing via HMAC(name, index_salt); entries include counts and metadata.
- **Chunk Map + Area**: Length‑prefixed JSON chunk map written before the chunk area; chunk area is a concatenation of per‑chunk AES‑GCM combined ciphertexts with deterministic nonces.
- **Manifest**: SHA256 over chunk map + index root; signature via Dilithium2 (or ECDSA in STUB mode). `verify` validates signature.
- **Backups**: Tar-like directory with `manifest.json`, `keys.bin` (PQC-wrap only in REAL_CRYPTO), `data/`.
- **Auto-lock & backoff**: Implemented in core/session; UX wires to timers (LaunchAgent stub).
- **Zero Telemetry**: Network deny by default; allowlist unit test prevents regressions.
- **Shred**: Two passes + unlink + TRIM hint (best effort; APFS limitations documented).

If you enable REAL_CRYPTO, all PQC/KDF behaviors follow your plan exactly.

---

## Project layout
```
Aegiro/
  Package.swift
  README.md
  LICENSE.txt
  ThirdParty/
    NOTICE-liboqs.txt
  Sources/
    AegiroCore/...
    AegiroCLI/main.swift
    AegiroApp/...
    Argon2C/ (systemLibrary mapper)
    OQSWrapper/ (systemLibrary mapper)
  Tests/
    AegiroCoreTests/...
```

---

## Legal & Licensing
- `liboqs` (Apache-2.0) and `argon2` (CC0/Apache). Notices included.
- This repo’s code is Apache-2.0 (see `LICENSE.txt`).

---

## Notes
- Legacy vaults supported: header parser accepts both MAGIC+JSON (legacy) and MAGIC+len+JSON (current).
- Menubar helper, Finder/UI features are scaffolded. Core crypto and formats are prioritized.
- To ship: sign/notarize, enable Hardened Runtime, pin `liboqs` version, and run the provided security checklist.

---

## Contributing
- See `AGENTS.md` for workflow: commit every fix/change, keep diffs focused, rebuild and commit `dist/` after CLI changes.

---

## Troubleshooting

- Linker errors about OpenSSL or liboqs (e.g., symbols `_EVP_*`, `_RAND_*`)  
  - Ensure Homebrew dependencies are installed: `brew install liboqs argon2 openssl@3`  
  - Use the provided build script: `bash scripts/build-real.sh` (injects the right link flags).

- macOS version warnings (built for 15.0, linking 13.0)  
  - Harmless for local builds via Homebrew bottles. For shipping, build from source targeting your deployment target.

- `VaultHeader` JSON or length errors on import/open  
  - The parser supports legacy and new headers. If you hit errors, recreate the vault with the latest CLI and re-import, or run `doctor` to inspect.

- `status` shows Locked: yes / unknown entries  
  - Provide `--passphrase` to decrypt the index: `status --vault <path> --passphrase "<pass>"`.

- Preview doesn’t open a window  
  - In headless or sandboxed environments, `open` may be ignored. Use `export` to recover files.

- `pkg-config` not found / headers not found  
  - Install `pkg-config` (usually present via Xcode CLT or Homebrew). The build script adds local `.pc` shims as a fallback.

- Shred limitations on APFS  
  - On SSD/APFS, secure deletion is best-effort. Consider full-disk encryption + vault workflows.

- `security find-identity -v -p codesigning` shows `0 valid identities found`
  - Unlocking the keychain does not create certificates; it only unlocks existing ones.
  - For local development (no paid membership required): open Xcode, add your Apple ID, then create an `Apple Development` certificate in `Xcode > Settings > Accounts > Manage Certificates` (Xcode labels it `Apple Development`, not `Code Signing`).
  - Or create a local self-signed `Code Signing` certificate in Keychain Access.
  - Then rebuild/sign the app: `bash scripts/build-app-dev.sh --identity "<identity name>"`.
  - If you stay ad-hoc signed, the app runs but Touch ID secure keychain storage is expected to be unavailable.

- `open dist/AegiroApp.app` shows an old app window
  - macOS may reactivate an already running instance with the same bundle identifier.
  - Use `open -n dist/AegiroApp.app` (or `bash scripts/build-app-dev.sh --launch`) to force a new instance of the freshly built app.
  - If you previously launched from Xcode, stale `DerivedData` processes can remain; use `bash scripts/build-app-dev.sh --kill-running --launch`.

---

## Security Notes

- Key derivation: Argon2id (REAL_CRYPTO) derives the PDK from your passphrase + salt; parameters default to m=256 MiB, t=3, p=1.
- Unlock flow (new vaults): The passphrase-derived key unwraps a PQ access key; that key unwraps the Kyber secret key, Kyber decapsulation derives the shared secret, and only then is the DEK unwrapped.
- Signer key wrapping: The Dilithium private key is AES‑GCM wrapped under the DEK, enabling offline manifest re‑signing on lock.
- Chunking + nonces: File data is encrypted into 1 MiB chunks on import using AES‑GCM with deterministic 96‑bit nonces (derived via HMAC(seed, chunkIndex)).
- Integrity: Index is AEAD-encrypted; manifest signs SHA256(index JSON) + SHA256(chunk map). `verify` validates integrity without passphrase.
- Zero telemetry: No network access required. Keep the CLI offline; signing and KDF are all local.
- Backups: Keep your passphrase safe. The backup includes only encrypted data + metadata; losing the passphrase means losing access.
- External disks: `disk-encrypt` relies on APFS/FileVault volume encryption and stores unlock material in a PQC recovery bundle.
- Compatibility note: legacy vaults (created before this PQ unlock flow) still use direct PDK->DEK unwrap until migrated.
