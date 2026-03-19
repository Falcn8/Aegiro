# Aegiro Encryption Scheme Paper

Version: 2.2 (implementation-focused)  
Document type: Engineering reference  
Primary source of truth: current code in `Sources/AegiroCore`

---

## 1. Scope and Intent

This paper documents how encryption works in the **current implementation**, not just in design specs.  
It covers three active cryptographic paths:

1. Vault encryption for `.agvt` files (`create`, `import`, `unlock`, `export`)  
2. APFS external-volume recovery wrapping (`apfs-volume-encrypt`, `apfs-volume-decrypt`)  
3. Portable encrypted APFS sparsebundle recovery wrapping (`usb-container-create`, `usb-container-open`)

It also identifies implementation caveats and runtime format behavior used by the current codebase.

---

## 2. Primitive Inventory

## 2.1 Core Primitives

- Password KDF: Argon2id
- AEAD: AES-256-GCM
- Hashes/MACs: SHA-256, HMAC-SHA256
- KEM (REAL_CRYPTO): Kyber512
- Signature (REAL_CRYPTO): Dilithium2

Source references:

- `Sources/AegiroCore/Crypto.swift`
- `Sources/AegiroCore/PQC.swift`
- `Sources/AegiroCore/IndexManifest.swift`

## 2.2 Build Modes

`PQC.swift` supports two operational crypto backends:

- `REAL_CRYPTO`: liboqs-based Kyber512 + Dilithium2
- non-`REAL_CRYPTO`: fallback stubs
  - KEM stub: Curve25519 key agreement + HKDF-SHA256
  - Signature stub: P-256 ECDSA

This keeps format/path behavior consistent while allowing non-production builds.

---

## 3. Vault Cryptosystem (`.agvt`)

## 3.1 Header and Metadata

The vault starts with `VaultHeader`, encoded as:

- 8-byte magic: `AEGIRO\0\1`
- 4-byte little-endian JSON length
- JSON payload of `VaultHeader`

Header fields include:

- crypto algorithm IDs
- `kdf_salt` (32 bytes)
- `index_salt` (32 bytes)
- Argon2 parameter metadata (`mMiB`, `t`, `p`)
- PQ public keys (`kyber_pk`, `dilithium_pk`)
- flags (`touchID`, `PQC unlock mode`)

Source references:

- `Sources/AegiroCore/VaultHeader.swift`
- `Sources/AegiroCore/Vault.swift` (`parseHeaderAndOffset`)

## 3.2 AAD Domain Separation

Main vault AEAD operations use a fixed AAD constant:

- `vaultAAD = "AEGIRO-V1"`

This AAD binds:

- key-wraps
- encrypted index blob
- encrypted chunk blobs
- signer secret-key wrap

Source: `Sources/AegiroCore/Vault.swift`

## 3.3 Key Hierarchy and Wrap Chain

### 3.3.1 Key Creation on Vault Create

On `AegiroVault.create(...)`, the system generates:

- passphrase-derived key `PDK` (32 bytes) from Argon2id
- random `AccessKey` (32 bytes)
- random `DEK` (32 bytes)
- Kyber keypair `(kemPk, kemSk)`
- Dilithium keypair `(sigPk, sigSk)`

### 3.3.2 Wrap Sequence

1. `pdkWrap = AES-GCM(PDK, AccessKey, AAD="AEGIRO-V1")`  
2. `kemSkWrap = AES-GCM(AccessKey, kemSk, AAD="AEGIRO-V1")`  
3. `ss, kemCt = KEM.encap(kemPk)`  
4. `pqWrap = AES-GCM(ss, DEK, AAD="AEGIRO-V1")`  
5. `signerSkWrap = AES-GCM(DEK, sigSk, AAD="AEGIRO-V1")`

`PQAccessBundleV1` persists:

- `version`
- `kemCiphertext`
- `kemSecretWrap`

### 3.3.3 Unlock Sequence

Given passphrase:

1. Re-derive `PDK` from `kdf_salt`
2. Decrypt `pdkWrap` -> `AccessKey`
3. Decode `PQAccessBundleV1`
4. Decrypt `kemSecretWrap` with `AccessKey` -> `kemSk`
5. Decapsulate `kemCiphertext` -> shared secret `ss`
6. Decrypt `pqWrap` with `ss` -> `DEK`

Legacy mode remains supported:

- if PQC flag is not set, decrypted `pdkWrap` plaintext is interpreted directly as `DEK`.

Source references:

- `Sources/AegiroCore/Vault.swift` (`AegiroVault.create`, `unlockDEK`, `inferUnlockMode`)

## 3.4 Index Encryption

`VaultIndex` is JSON-encoded, then AES-GCM encrypted under `DEK` with `vaultAAD`:

- `idxBlob = AES-GCM(DEK, JSON(index), AAD="AEGIRO-V1")`

Source reference: `Sources/AegiroCore/IndexManifest.swift` (`IndexCrypto`)

## 3.5 Chunk Encryption

File data is chunked (current import path uses 128 KiB plaintext chunks).  
Each file stores `VaultChunkCrypto` metadata in encrypted index entries:

- `format` (`1`)
- `algorithm` (`1 = AES-GCM`, `2 = ChaCha20-Poly1305`)
- `keySalt` (`16 bytes`)
- `noncePrefix` (`4 bytes`)

For each file:

1. Derive `file_key = HKDF-SHA256(DEK, keySalt, "AEGIRO-FILE-KEY-V1" || fileID || algorithm || format)`.
2. Build per-chunk nonce as `noncePrefix || chunkOrdinalLE64`.
3. Build per-chunk AAD as `"AEGIRO-CHUNK-V1" || kdf_salt || fileID || algorithm || format || chunkOrdinalLE32`.
4. Encrypt/decrypt chunk payload with selected AEAD algorithm using `file_key`.

Chunk map metadata (`ChunkInfo`) stores `fileID`, `ordinal`, relative offset, and encrypted length.

Source references:

- `Sources/AegiroCore/Crypto.swift` (`NonceScheme`, `HMACUtil`)
- `Sources/AegiroCore/Vault.swift` (`mergeImportedItems`)

## 3.6 Manifest Integrity and Authenticity

Manifest fields:

- `indexRootHash = SHA256(JSON(index))`
- `chunkMapHash = SHA256(chunkMapBytes)`
- `signature = Sign(indexRootHash || chunkMapHash)`
- `signerPK`

Verification checks signature over concatenated hashes.

Source references:

- `Sources/AegiroCore/IndexManifest.swift` (`ManifestBuilder`)
- `Sources/AegiroCore/Vault.swift` (`Doctor`, `verify` command path)

## 3.7 Current On-Disk Layout

After header bytes, vault payload is laid out sequentially:

1. `pdkWrap` (60 bytes)
2. `pqAccessBlobLen` (`u32 LE`)
3. `pqAccessBlob`
4. `pqWrap` (60 bytes)
5. `signerWrapLen` (`u32 LE`)
6. `signerWrap`
7. `idxLen` (`u32 LE`)
8. `idxBlob`
9. `manifestLen` (`u32 LE`)
10. `manifestBlob`
11. `chunkMapLen` (`u32 LE`)
12. `chunkMapBlob`
13. `chunkArea` (concatenated encrypted chunks)

Source references:

- `Sources/AegiroCore/Vault.swift` (`readVaultReadComponents`, `computeLayout`)

---

## 4. APFS External Volume Recovery Bundle Crypto

Module: `ExternalDiskCrypto`

AAD scope:

- `"AEGIRO-DISK-V1:<diskIdentifier>"`

Flow:

1. Generate random APFS disk passphrase
2. Derive recovery key from user recovery passphrase (`Argon2id`)
3. Kyber encap -> `sharedSecret`, `kemCiphertext`
4. Wrap disk passphrase with `sharedSecret`
5. Wrap `kemSk` with recovery key
6. Persist JSON recovery bundle
7. Execute `diskutil apfs encryptVolume ...`

Unlock flow decrypts wraps in reverse, recovers disk passphrase, calls `diskutil apfs unlockVolume ...`.

Source: `Sources/AegiroCore/ExternalDiskCrypto.swift`

---

## 5. USB Container Recovery Bundle Crypto

Module: `USBContainerCrypto`

AAD scope:

- `"AEGIRO-USB-CONTAINER-V1:<imagePath>"`

Flow:

1. Determine container passphrase (provided or random)
2. Derive recovery key via Argon2id
3. Kyber encap -> `sharedSecret`, `kemCiphertext`
4. Wrap container passphrase with `sharedSecret`
5. Wrap `kemSk` with recovery key
6. Persist JSON recovery bundle
7. Use `hdiutil` with recovered passphrase for create/mount operations

Source: `Sources/AegiroCore/USBContainerCrypto.swift`

---

## 6. Validation, Audit, and Repair (`doctor`)

`Doctor.run(...)` performs layered checks:

- header parse
- manifest decode and signature validity
- signer public key consistency with header
- chunk map hash consistency
- optional index hash consistency (requires passphrase)
- chunk map structural continuity
- optional deep chunk authentication and size reconciliation

Fix mode can rebuild/re-sign manifest when decryptable state is available.

Source: `Sources/AegiroCore/Vault.swift` (`Doctor`)

---

## 7. Security Properties

Provided (offline at-rest model):

- confidentiality of index and chunk payloads
- authenticated encryption for wrapped secrets and file/index blobs
- signed manifest-level consistency checks
- passphrase strengthening by Argon2id
- post-quantum KEM/signature path in `REAL_CRYPTO`

Not provided:

- protection after endpoint compromise while unlocked
- complete metadata hiding (file size/timestamps, container presence remain visible)
- remote escrow or server-assisted recovery

---

## 8. Known Implementation Caveats

1. Argon2 parameter structs are stored in header/bundle metadata, but KDF code paths currently use fixed defaults (`m=256 MiB, t=3, p=1`).  
2. `wraps_offsets` fields exist in header, but parser/reader logic uses sequential parsing instead of relying on those offsets.  
3. Legacy unlock and PQC unlock coexist; mode inference and flag normalization are available.  
4. Chunk readers are strict AGVT v1 (`AEGIRO-FILE-KEY-V1`, `AEGIRO-CHUNK-V1`, AEAD ID `1`); vaults with legacy v2 chunk labels are not supported.

---

## 9. Runtime Format Status

Current runtime vault read/write behavior uses the v1 serialized layout documented above (`Vault.swift` path).  
This document is the active implementation reference for that format.

Runtime policy:

- New vault writes: AGVT v1 header/version/AEAD labels.
- Reader enforcement: accepts only AEAD ID `1` with `AEGIRO-FILE-KEY-V1` / `AEGIRO-CHUNK-V1` chunk domains.
- AGVT v2 spec/helper artifacts were removed from active source/docs; historical context remains in git history.

---

## 10. Quick Source Index

- Core primitives: `Sources/AegiroCore/Crypto.swift`  
- Header model: `Sources/AegiroCore/VaultHeader.swift`  
- Vault create/unlock/import/export/doctor: `Sources/AegiroCore/Vault.swift`  
- Index + manifest crypto: `Sources/AegiroCore/IndexManifest.swift`  
- PQ backend: `Sources/AegiroCore/PQC.swift`  
- APFS recovery bundle: `Sources/AegiroCore/ExternalDiskCrypto.swift`  
- USB container recovery bundle: `Sources/AegiroCore/USBContainerCrypto.swift`
