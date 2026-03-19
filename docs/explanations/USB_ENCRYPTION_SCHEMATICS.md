# Aegiro — USB / External APFS Disk Encryption Schematics

This document provides full technical schematics for `ExternalDiskCrypto.swift`:
how a USB (or any external APFS) volume is encrypted, what the recovery bundle
contains, and how the volume is unlocked.

---

## 1. High-Level Overview

```
┌──────────────────────────────────────────────────────────────────────────┐
│                     ENCRYPT (apfs-volume-encrypt)                        │
│                                                                          │
│  User passphrase ──► Argon2id KDF ──► Recovery Key                      │
│                                           │                              │
│  Kyber512.keypair() ──► KEM_PK, KEM_SK    │                              │
│  Kyber512.encap(KEM_PK) ──► Shared Secret + KEM Ciphertext              │
│                                           │                              │
│  random 32-byte hex ──► Disk Passphrase   │                              │
│                             │             │                              │
│           AES-256-GCM wrap ─┤             │                              │
│          (key=Shared Secret)│             │                              │
│             disk_passphrase_wrap          │                              │
│                                           │                              │
│           AES-256-GCM wrap ───────────────┘                              │
│          (key=Recovery Key)                                              │
│             kem_secret_wrap                                              │
│                                                                          │
│  Bundle JSON ──► saved to <recovery>.aegiro-diskkey.json                 │
│  diskutil apfs encryptVolume <disk> ◄── Disk Passphrase (via stdin)      │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│                      UNLOCK (apfs-volume-decrypt)                        │
│                                                                          │
│  Bundle JSON ──► kdf_salt, argon2 params, kem_ciphertext,                │
│                  kem_secret_wrap, disk_passphrase_wrap                   │
│                                                                          │
│  User passphrase + kdf_salt ──► Argon2id KDF ──► Recovery Key           │
│  Recovery Key ──► AES-256-GCM unwrap(kem_secret_wrap) ──► KEM_SK        │
│  KEM_SK + kem_ciphertext ──► Kyber512.decap() ──► Shared Secret         │
│  Shared Secret ──► AES-256-GCM unwrap(disk_passphrase_wrap)             │
│                         ──► Disk Passphrase                              │
│  diskutil apfs unlockVolume <disk> ◄── Disk Passphrase (via stdin)       │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Encrypt Flow — Step by Step

```
┌─────────────────────────────────────────────────────────────────────────┐
│  INPUT                                                                  │
│  ─────                                                                  │
│  diskIdentifier   : "disk9s1"                                           │
│  recoveryPassphrase: "<user-chosen passphrase>"                         │
│  recoveryURL      : ~/Backups/disk9s1.aegiro-diskkey.json               │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  STEP 1 — Generate KDF salt and derive Recovery Key                     │
│  ──────────────────────────────────────────────────                     │
│                                                                         │
│  kdf_salt  ← CSPRNG(32 bytes)                                           │
│  argon2    ← { mMiB: 256, t: 3, p: 1 }                                 │
│                                                                         │
│  Recovery Key  ← Argon2id(                                              │
│                      passphrase = recoveryPassphrase,                   │
│                      salt       = kdf_salt,                             │
│                      m          = 256 MiB,                              │
│                      t          = 3 iterations,                         │
│                      p          = 1 lane,                               │
│                      outLen     = 32 bytes                              │
│                  )                                                      │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  STEP 2 — Generate KEM keypair and encapsulate                          │
│  ─────────────────────────────────────────────                          │
│                                                                         │
│  (KEM_PK, KEM_SK)         ← Kyber512.keypair()                         │
│  (Shared Secret, KEM_CT)  ← Kyber512.encap(KEM_PK)                     │
│                                                                         │
│  Shared Secret : 32 bytes (derived inside liboqs from Kyber SHAKE-256) │
│  KEM_CT        : Kyber512 ciphertext  (~800 bytes)                      │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  STEP 3 — Generate random Disk Passphrase                               │
│  ─────────────────────────────────────────                              │
│                                                                         │
│  Disk Passphrase ← hex(CSPRNG(32 bytes))   // 64-character hex string  │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  STEP 4 — AES-256-GCM wrap Disk Passphrase under Shared Secret         │
│  ──────────────────────────────────────────────────────────────         │
│                                                                         │
│  nonce_dp ← CSPRNG(12 bytes)                                            │
│  AAD      ← "AEGIRO-DISK-V1:disk9s1"  (UTF-8 bytes)                    │
│                                                                         │
│  disk_passphrase_wrap ← AES-256-GCM.seal(                              │
│                             key       = Shared Secret,                  │
│                             nonce     = nonce_dp,                       │
│                             plaintext = UTF-8(Disk Passphrase),         │
│                             aad       = AAD                             │
│                         )                                               │
│                         // combined = nonce_dp || ciphertext || tag     │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  STEP 5 — AES-256-GCM wrap KEM_SK under Recovery Key                   │
│  ────────────────────────────────────────────────────                   │
│                                                                         │
│  nonce_ks ← CSPRNG(12 bytes)                                            │
│                                                                         │
│  kem_secret_wrap ← AES-256-GCM.seal(                                   │
│                        key       = Recovery Key,                        │
│                        nonce     = nonce_ks,                            │
│                        plaintext = KEM_SK (raw bytes),                  │
│                        aad       = AAD                                  │
│                    )                                                    │
│                    // combined = nonce_ks || ciphertext || tag          │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  STEP 6 — Assemble and write Recovery Bundle                            │
│  ──────────────────────────────────────────                             │
│                                                                         │
│  DiskRecoveryBundle {                                                   │
│      version            : 1                                             │
│      created_unix       : <unix timestamp>                              │
│      disk_identifier    : "disk9s1"                                     │
│      kdf_salt           : <32 bytes, base64>                            │
│      argon2             : { mMiB: 256, t: 3, p: 1 }                    │
│      kem_ciphertext     : <KEM_CT, base64>                              │
│      kem_secret_wrap    : <nonce_ks||ct||tag, base64>                   │
│      disk_passphrase_wrap: <nonce_dp||ct||tag, base64>                  │
│  }                                                                      │
│                                                                         │
│  → Written as pretty-printed JSON (keys sorted) to recoveryURL          │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  STEP 7 — Enable APFS encryption on the volume                          │
│  ─────────────────────────────────────────────                          │
│                                                                         │
│  (skipped when --dry-run)                                               │
│                                                                         │
│  diskutil apfs encryptVolume disk9s1       \                            │
│           -user disk                       \                            │
│           -stdinpassphrase                 \                            │
│           <<< "<Disk Passphrase>"                                       │
│                                                                         │
│  macOS stores the APFS key slot; Aegiro holds the unlock material.      │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Recovery Bundle — JSON Structure

```
disk9s1.aegiro-diskkey.json
───────────────────────────
{
    "argon2": {
        "mMiB": 256,          ← memory cost (256 MiB)
        "p": 1,               ← parallelism
        "t": 3                ← time cost (iterations)
    },
    "created_unix": 1741234567,
    "disk_identifier": "disk9s1",
    "kem_ciphertext": "<base64>",       ← Kyber512 ciphertext from encap()
    "kem_secret_wrap": "<base64>",      ← nonce(12B) || AES-GCM ct+tag
                                        ←   key = Recovery Key (Argon2id)
                                        ←   plaintext = KEM_SK (Kyber512 secret key)
    "disk_passphrase_wrap": "<base64>", ← nonce(12B) || AES-GCM ct+tag
                                        ←   key = Shared Secret (Kyber decap)
                                        ←   plaintext = Disk Passphrase (UTF-8)
    "kdf_salt": "<base64>",             ← 32-byte CSPRNG salt for Argon2id
    "version": 1
}

AAD bound to every AES-GCM ciphertext: "AEGIRO-DISK-V1:disk9s1" (UTF-8)
```

---

## 4. Unlock Flow — Step by Step

```
┌─────────────────────────────────────────────────────────────────────────┐
│  INPUT                                                                  │
│  ─────                                                                  │
│  diskIdentifier   : "disk9s1"                                           │
│  recoveryPassphrase: "<user-chosen passphrase>"                         │
│  recoveryURL      : ~/Backups/disk9s1.aegiro-diskkey.json               │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  STEP 1 — Load and validate Recovery Bundle                             │
│  ─────────────────────────────────────────                              │
│                                                                         │
│  bundle ← JSON.decode(recoveryURL)                                      │
│  assert bundle.version == 1                                             │
│  assert bundle.disk_identifier == "disk9s1"                             │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  STEP 2 — Re-derive Recovery Key                                        │
│  ───────────────────────────────                                        │
│                                                                         │
│  Recovery Key ← Argon2id(                                               │
│                     passphrase = recoveryPassphrase,                    │
│                     salt       = bundle.kdf_salt,                       │
│                     m / t / p  = bundle.argon2                          │
│                 )                                                       │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  STEP 3 — Unwrap KEM_SK                                                 │
│  ──────────────────────                                                 │
│                                                                         │
│  nonce_ks ← bundle.kem_secret_wrap[0:12]                                │
│  AAD      ← "AEGIRO-DISK-V1:disk9s1"                                    │
│                                                                         │
│  KEM_SK ← AES-256-GCM.open(                                             │
│               key      = Recovery Key,                                  │
│               nonce    = nonce_ks,                                      │
│               combined = bundle.kem_secret_wrap,                        │
│               aad      = AAD                                            │
│           )                                                             │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  STEP 4 — Kyber512 Decapsulation                                        │
│  ───────────────────────────────                                        │
│                                                                         │
│  Shared Secret ← Kyber512.decap(                                        │
│                      ciphertext = bundle.kem_ciphertext,                │
│                      sk         = KEM_SK                                │
│                  )                                                      │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  STEP 5 — Unwrap Disk Passphrase                                        │
│  ───────────────────────────────                                        │
│                                                                         │
│  nonce_dp ← bundle.disk_passphrase_wrap[0:12]                           │
│                                                                         │
│  Disk Passphrase ← AES-256-GCM.open(                                    │
│                        key      = Shared Secret,                        │
│                        nonce    = nonce_dp,                             │
│                        combined = bundle.disk_passphrase_wrap,          │
│                        aad      = AAD                                   │
│                    )                                                    │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  STEP 6 — Unlock APFS volume                                            │
│  ───────────────────────────                                            │
│                                                                         │
│  (skipped when --dry-run)                                               │
│                                                                         │
│  diskutil apfs unlockVolume disk9s1    \                                │
│           -user disk                   \                                │
│           -stdinpassphrase             \                                │
│           <<< "<Disk Passphrase>"                                       │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 5. Key Material at a Glance

```
┌──────────────────┬───────────────────────────────┬────────────────────────────────┐
│  Name            │  Algorithm / Size             │  Where stored                  │
├──────────────────┼───────────────────────────────┼────────────────────────────────┤
│  kdf_salt        │  CSPRNG, 32 bytes             │  bundle.kdf_salt               │
│  Recovery Key    │  Argon2id output, 32 bytes    │  NOT stored (derived on-demand)│
│  KEM_PK          │  Kyber512 public key          │  NOT stored (ephemeral)        │
│  KEM_SK          │  Kyber512 secret key          │  bundle.kem_secret_wrap        │
│  KEM_CT          │  Kyber512 ciphertext          │  bundle.kem_ciphertext         │
│  Shared Secret   │  Kyber512 output, 32 bytes    │  NOT stored (derived on-demand)│
│  Disk Passphrase │  64-char hex, 256 bits        │  bundle.disk_passphrase_wrap   │
│                  │                               │  + macOS APFS key slot         │
│  nonce_ks        │  AES-GCM nonce, 12 bytes      │  prefix of kem_secret_wrap     │
│  nonce_dp        │  AES-GCM nonce, 12 bytes      │  prefix of disk_passphrase_wrap│
└──────────────────┴───────────────────────────────┴────────────────────────────────┘
```

---

## 6. Authenticated Additional Data (AAD)

Both AES-256-GCM ciphertexts are bound to the specific disk via AAD:

```
AAD  =  "AEGIRO-DISK-V1" + ":" + diskIdentifier
     =  "AEGIRO-DISK-V1:disk9s1"   (encoded as UTF-8 bytes)
```

This prevents a recovery bundle from one disk being replayed against a
different disk identifier, even if an attacker controls the bundle file.

---

## 7. Threat Model Notes

| Threat | Mitigation |
|--------|-----------|
| Attacker steals recovery bundle only | Cannot unlock: Recovery Key never stored; Argon2id memory-hard KDF required |
| Attacker knows passphrase but has wrong bundle | AAD check + `disk_identifier` assertion reject mismatched bundle |
| Quantum adversary breaks classical crypto | Kyber512 KEM is ML-KEM (FIPS 203); shared secret binding defeats CRQC harvest-now-decrypt-later |
| Nonce reuse under AES-256-GCM | Both nonces are independently CSPRNG-generated per encrypt call; no counter reuse possible |
| Bundle file tampering | AES-256-GCM authentication tag on both wrapped fields detects any bit flip |

---

## 8. CLI Usage Reference

```bash
# Encrypt an external APFS volume and create recovery bundle
aegiro-cli apfs-volume-encrypt \
  --disk disk9s1 \
  --passphrase "<recovery passphrase>" \
  --recovery ~/Backups/disk9s1.aegiro-diskkey.json \
  [--force]     # overwrite existing bundle
  [--dry-run]   # generate bundle only; do NOT call diskutil

# Unlock an APFS volume using the recovery bundle
aegiro-cli apfs-volume-decrypt \
  --disk disk9s1 \
  --recovery ~/Backups/disk9s1.aegiro-diskkey.json \
  --passphrase "<recovery passphrase>" \
  [--dry-run]   # recover passphrase only; do NOT call diskutil
```

> **Note:** `apfs-volume-encrypt` and `apfs-volume-decrypt` both require admin or ownership
> permissions on the target disk, as enforced by `diskutil`.

---

## 9. Source File Reference

| Symbol | File |
|--------|------|
| `ExternalDiskCrypto.encryptAPFSVolume()` | `Sources/AegiroCore/ExternalDiskCrypto.swift` |
| `ExternalDiskCrypto.unlockAPFSVolume()` | `Sources/AegiroCore/ExternalDiskCrypto.swift` |
| `ExternalDiskCrypto.recoverDiskPassphrase()` | `Sources/AegiroCore/ExternalDiskCrypto.swift` |
| `DiskRecoveryBundle` | `Sources/AegiroCore/ExternalDiskCrypto.swift` |
| `AEAD.encrypt` / `AEAD.decrypt` | `Sources/AegiroCore/Crypto.swift` |
| `Kyber512` | `Sources/AegiroCore/PQC.swift` |
| `Argon2idKDF` | `Sources/AegiroCore/Crypto.swift` |
