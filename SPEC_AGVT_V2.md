# AGVT v2 Portable Encryption Format

Status: Release Baseline (v2)  
Audience: Aegiro core/CLI implementers  
Scope: Portable encrypted container format for macOS, Windows, Linux

Implementation snapshot (Aegiro mainline, 2026-03-19):

- Vault header `version = 2`, `alg_ids.aead = 2` (chunk AEAD v2 path).
- Chunk payload encryption uses per-file derived keys:
  - `file_key = HKDF-SHA256(DEK, salt=file.key_salt, info="AEGIRO-FILE-KEY-V2" || file_id || alg || format)`.
  - nonce = `nonce_prefix[4] || chunk_ordinal_le_u64`.
  - AAD = `"AEGIRO-CHUNK-V2" || vault_kdf_salt || file_id || alg || format || chunk_ordinal_le_u32`.
- Chunk map stores opaque identifiers only (`file_id`, `ordinal`, `rel_offset`, `length`) and does not store plaintext logical paths.
- Logical path mapping remains inside encrypted index entries.

## 1. Goals

- Build and own a portable encryption format (`.agvt`) that does not depend on APFS, BitLocker, or VeraCrypt.
- Keep security rooted in standard primitives and external-reviewed libraries, not custom cryptographic algorithms.
- Support crash-safe updates, integrity verification, and passphrase rotation.
- Keep format deterministic enough for cross-platform test vectors.

## 2. Non-Goals

- In-place block-device encryption of arbitrary filesystems.
- Kernel drivers or filesystem filter drivers.
- Obfuscation-based security.
- Reliance on platform keychains for core unlockability.

## 3. Threat Model (v2 Baseline)

- Protects confidentiality and integrity of vault contents at rest.
- Assumes attacker can read/copy/modify the vault file offline.
- Does not protect against a fully compromised runtime after unlock.
- Side-channel hardening is best-effort (constant-time compares, key zeroization where possible), but full microarchitectural resistance is out of scope for v2.

## 4. Crypto Profiles

AGVT v2 supports profile IDs so formats stay stable while algorithms can evolve.

- `0x0001` Classical baseline:
  - KDF: Argon2id
  - AEAD: Chunk AEAD v2 (`AES-256-GCM` on arm64, `ChaCha20-Poly1305` on non-arm64)
  - HKDF: HKDF-SHA256
  - Signature: Ed25519
- `0x0002` PQ-hybrid profile:
  - KDF: Argon2id
  - AEAD: Chunk AEAD v2 (`AES-256-GCM` on arm64, `ChaCha20-Poly1305` on non-arm64)
  - HKDF: HKDF-SHA256
  - KEM: Kyber512 (liboqs)
  - Signature: Dilithium2 (liboqs)

Initial implementation target for this repo: `0x0002` (to align with the current crypto posture), while keeping parsing generic.

## 5. Key Hierarchy

All keys are per-vault unless noted.

1. User passphrase + `kdf_salt` -> `PDK` (32 bytes) via Argon2id.
2. `PDK` unwraps `MasterSecret` (32 bytes random).
3. Derive per-file chunk key from `DEK`:
   - `file_key = HKDF-SHA256(DEK, file.key_salt, "AEGIRO-FILE-KEY-V2" || file_id || alg || format)`.
4. Each file gets random `key_salt` (16B) and `nonce_prefix` (4B) in encrypted index metadata.
5. Optional PQ recovery material may wrap either `MasterSecret` or a recovery key that can unwrap `MasterSecret`.

Rules:
- Never reuse the same key for index and chunk encryption.
- Nonce uniqueness is mandatory per AEAD key.
- All wraps include AAD with vault UUID + format version.

## 6. On-Disk Layout (v2)

Integer encoding: little-endian unsigned.

```
+----------------------+-----------------------------------------+
| Region               | Notes                                   |
+----------------------+-----------------------------------------+
| Superblock A (4 KiB) | Active pointer metadata slot            |
| Superblock B (4 KiB) | Alternate slot for atomic flip          |
| Record Area          | Append-only typed records               |
+----------------------+-----------------------------------------+
```

### 6.1 Superblock Structure (fixed 4096 bytes)

- `magic[8]`: `"AGVT2\0\0\1"` (exact bytes finalized before implementation)
- `superblock_version` (`u16`)
- `profile_id` (`u16`)
- `vault_uuid` (`16 bytes`)
- `epoch` (`u64`) monotonic commit counter
- `active_manifest_offset` (`u64`)
- `active_manifest_length` (`u32`)
- `active_manifest_hash` (`32 bytes`) SHA-256
- `header_crc32` (`u32`) over superblock fields except trailing reserved
- `reserved[...]` to 4096 bytes

Only the superblock with the highest valid `epoch` is active.

### 6.2 Record Framing (append-only)

Each record in Record Area:

- `record_type` (`u16`)
- `record_version` (`u16`)
- `record_flags` (`u32`)
- `payload_len` (`u64`)
- `payload_crc32` (`u32`)
- `payload[payload_len]`

Record types:

- `0x0001`: Vault metadata/header payload
- `0x0002`: Encrypted index snapshot payload
- `0x0003`: Chunk blob payload
- `0x0004`: Manifest payload (commit object)
- `0x0005`: Rekey payload
- `0x0006`: Tombstone payload (logical deletes)

Unknown record types are skipped by length.

## 7. Data Model

- Files are split into fixed-size plaintext chunks (default 1 MiB).
- Each encrypted chunk maps to a chunk record.
- Logical file metadata lives in encrypted index snapshots.
- Manifests point to the current index root and the set of referenced chunk records.

### 7.1 Index Entry Fields (logical)

- `entry_id` (UUID)
- `path_utf8`
- `mode`/platform attrs (portable subset)
- `mtime_unix_ns`
- `size_bytes`
- `chunk_refs[]`:
  - `record_offset`
  - `cipher_len`
  - `plain_len`
  - `chunk_hash` (SHA-256 of plaintext)

## 8. AEAD and Nonces

- AEAD additional data (AAD) must include:
  - chunk format/version
  - vault salt binding
  - file identifier
  - chunk ordinal
- Nonce policy:
  - 96-bit nonce
  - `nonce_prefix[4] || chunk_ordinal_le_u64`
  - unique per file key domain

## 9. Commit Protocol (Crash Safety)

Write path is copy-on-write with two-phase commit:

1. Append new chunk records.
2. Append new encrypted index snapshot record.
3. Append new manifest record referencing all new roots.
4. `fsync` vault file.
5. Update inactive superblock with new manifest pointer and incremented epoch.
6. `fsync` vault file again.
7. Flip active superblock by writing the alternate slot.

Recovery rule:
- On open, choose highest valid superblock epoch.
- If newest epoch references an invalid manifest, fall back to previous valid epoch.

## 10. Integrity Rules

- Every record has CRC32 for corruption detection (fast fail).
- Security integrity is provided by AEAD tags and manifest signature/hash chain.
- Manifest payload includes:
  - `epoch`
  - `index_record_offset`
  - `index_cipher_hash` (SHA-256)
  - `chunk_set_hash` (deterministic hash of chunk refs)
  - `prev_manifest_hash`
  - `signature` (per profile)

`verify` checks:
- Superblock validity
- Manifest chain continuity
- Signature validity
- Referenced record existence
- Optional deep mode: full chunk decrypt/hash scan

## 11. Rekey Protocol

`rekey` changes passphrase without re-encrypting all chunks:

1. Derive `new_PDK` with new Argon2 params/salt.
2. Rewrap existing `MasterSecret` into a new key-wrap record.
3. Append rekey record + new manifest.
4. Commit via superblock epoch flip.

Optional `rekey --full` may rotate `MasterSecret` and re-encrypt index/chunks.

## 12. Recovery Bundle (Portable)

For lost/rotated passphrase workflows, AGVT can optionally emit a separate recovery bundle:

- Bundled fields:
  - version
  - vault UUID
  - profile id
  - KDF params + salt
  - KEM ciphertext (profile-dependent)
  - wrapped recovery secret
  - wrapped `MasterSecret`
- AAD binds all wraps to vault UUID + profile id + version.
- Bundle is JSON for now (cross-language tooling), with canonical key order in test vectors.

## 13. CLI Contract (v2 command surface)

Canonical commands:

- `init --vault <path> --passphrase <...> [--profile <id>]`
- `add --vault <path> --passphrase <...> <files...>`
- `list --vault <path> --passphrase <...>`
- `extract --vault <path> --passphrase <...> --out <dir> [filters...]`
- `verify --vault <path> [--deep]`
- `rekey --vault <path> --old-passphrase <...> --new-passphrase <...>`
- `recover --vault <path> --bundle <path> --passphrase <...>`
- `gc --vault <path> --passphrase <...>` (optional compaction)

Exit code guidance:

- `0`: success
- `2`: usage error
- `3`: auth failure
- `4`: integrity failure
- `5`: IO/system error

## 14. Cross-Platform Rules

- Path normalization in index uses UTF-8 + `/` separators.
- Preserve platform-specific metadata in optional extension fields.
- Do not require symlink support for core correctness.
- Core format implementation must avoid platform-only APIs.

## 15. Test Matrix Requirements

Minimum acceptance:

- Round-trip create/add/list/extract on macOS, Windows, Linux.
- Deterministic vectors for:
  - KDF output
  - nonce derivation
  - one chunk AEAD sample
  - one manifest hash/signature sample
- Corruption tests:
  - flipped bit in chunk payload
  - truncated record
  - stale superblock epoch
  - invalid signature
- Rekey test:
  - old passphrase rejected
  - new passphrase accepted
  - data unchanged

Guardrails:

- Max segments per vault (default): `4096`.
- Segment writers must reject commits that would exceed this cap.
- Optional runtime override may be provided for controlled advanced use.

## 16. Migration from Current `.agvt` (v1)

Pre-release hard-cutover policy for this repository:

- Backward compatibility with old chunk payload layouts is intentionally not guaranteed.
- Existing local test data should be regenerated after chunk-format changes.
- Migration tooling can be added later when a public compatibility contract is required.

## 17. Format Decisions

- `magic` bytes and superblock checksum scope are fixed for AGVT v2.
- Profile `0x0002` is the primary release target for this repository.
- Signature verification is part of the portable integrity baseline.
- Compaction and chunk handling behavior follow the current manifest/chunk map model.
- Metadata encoding remains aligned with the implementation and versioned for future evolution.

## 18. Implementation Plan Anchored to This Repo

1. Add `AegiroCore/FormatV2/` with parser + writer + superblock manager.
2. Add deterministic vector fixtures under `Tests/AegiroCoreTests/Vectors/`.
3. Implement `init/add/list/extract/verify` v2 path behind feature flag.
4. Add `rekey` and `migrate --to-v2`.
5. Promote v2 as default after compatibility soak.

---

This specification is the contract for implementation and maintenance. Security-sensitive changes must update this file in the same commit as code changes.
