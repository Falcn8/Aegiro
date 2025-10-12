# Aegiro (macOS) — Local-only, PQC-ready encrypted vault

> **Status**: Build-ready skeleton with working local vault/backup CLI and SwiftUI app stubs.  
> **Crypto**: Interfaces for **Argon2id + Kyber512 + Dilithium2** are included. By default, the project builds in **STUB_CRYPTO** mode for easy local runs (HKDF-based KDF and ECDSA signatures). Switch to **REAL_CRYPTO** to link `libargon2` and `liboqs` and meet the exact PQC/KDF spec.

---

## What’s here

- **AegiroCore** (Swift library): Vault header/index/manifest per spec, chunked AES-256-GCM I/O, nonce scheme, wrappers for KDF & PQC, secure preview temp policy, shredder, privacy monitor, “secure lock” scriptables, zero-telemetry guard.
- **AegiroCLI** (Swift exec): End-to-end demo: `create`, `import`, `lock`, `unlock`, `backup`, `verify`, `scan`, `shred`.
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
36d406371f3cd873f2ce06a211cf885cd2c76a6ed1df1f1dcdc49202e7f5c3bd  dist/aegiro-cli-macos-arm64.tar.gz
```

### REAL_CRYPTO build (Argon2id + liboqs)

1) Install dependencies (macOS):
```bash
brew install liboqs argon2
```

2) Build **without** STUB_CRYPTO:
```bash
swift build -c release -Xswiftc -DREAL_CRYPTO
```

> REAL_CRYPTO mode uses system libraries via SwiftPM `systemLibrary` targets located in `Sources/Argon2C` and `Sources/OQSWrapper`. See their READMEs for symbol mapping.

---

## CLI examples

```bash
# Create a new vault
.build/release/aegiro-cli create --vault ~/AegiroVaults/alpha.aegirovault --passphrase "correct horse battery staple" --touchid

# Import files
.build/release/aegiro-cli import --vault ~/AegiroVaults/alpha.aegirovault ~/Downloads/tax.pdf ~/Desktop/passport.jpg

# Lock / unlock
.build/release/aegiro-cli lock --vault ~/AegiroVaults/alpha.aegirovault
.build/release/aegiro-cli unlock --vault ~/AegiroVaults/alpha.aegirovault --passphrase "correct horse battery staple"

# Backup export
.build/release/aegiro-cli backup --vault ~/AegiroVaults/alpha.aegirovault --out ~/Backups/alpha_2025-10-04.aegirobackup

# Privacy scan + suggest moves
.build/release/aegiro-cli scan --targets ~/Downloads ~/Desktop

# Secure shred
.build/release/aegiro-cli shred ~/Downloads/secret.zip
```

---

## Spec conformance (highlights)

- **AES-256-GCM**: CryptoKit-based, 96-bit nonces, **HMAC(fileNonceSeed, chunkIndex)[:12]**.
- **Argon2id**: REAL_CRYPTO uses `libargon2`. STUB_CRYPTO uses HKDF-SHA256 placeholder (clearly labeled).
- **Kyber512 + Dilithium2**: Interfaces via `liboqs`. STUB_CRYPTO uses ECDH(E25519) + ECDSA for demo-signing.
- **Header**: Matches field layout (see `VaultHeader.swift`). Versioning & alg IDs included.
- **Index**: Encrypted AEAD; filename hashing via HMAC(name, index_salt).
- **Manifest**: SHA256 over chunk map + index root; signature via Dilithium2 (or ECDSA in STUB mode).
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
- Menubar helper, Finder/UI features are scaffolded. Core crypto and formats are prioritized.
- To ship: sign/notarize, enable Hardened Runtime, pin `liboqs` version, and run the provided security checklist.
