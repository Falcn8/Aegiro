# Aegiro Encryption Scheme Paper (Implementation Reference)

Version: 1.0  
Scope: Current implementation in `Sources/AegiroCore` and CLI wiring in `Sources/AegiroCLI`  
Audience: engineers, reviewers, and security auditors

---

## 1) Executive Summary

Aegiro currently ships three encryption workflows:

1. `.agvt` vault encryption (`create`, `import`, `export`, `unlock`)  
2. APFS external-volume recovery wrapping (`apfs-volume-encrypt` / `apfs-volume-decrypt`)  
3. Portable APFS sparsebundle recovery wrapping (`usb-container-create` / `usb-container-open`)

The main vault path is passphrase-gated, Argon2id-based, AES-GCM authenticated encryption with post-quantum key encapsulation/signature support in `REAL_CRYPTO` builds.

---

## 2) Cryptographic Building Blocks

## 2.1 Primitive Set

- KDF: Argon2id (`Argon2idKDF`)  
- Symmetric AEAD: AES-256-GCM (`AEAD`, `IndexCrypto`)  
- Hash / MAC: SHA-256, HMAC-SHA256  
- KEM (REAL_CRYPTO): Kyber512 (`Kyber512`)  
- Signature (REAL_CRYPTO): Dilithium2 (`Dilithium2`)

Reference code:

- `Sources/AegiroCore/Crypto.swift`
- `Sources/AegiroCore/PQC.swift`
- `Sources/AegiroCore/IndexManifest.swift`

## 2.2 Build-Mode Split

- `REAL_CRYPTO` build: liboqs-backed Kyber512 + Dilithium2
- Non-`REAL_CRYPTO` build: test/developer stubs
  - KEM stub: Curve25519 ECDH + HKDF-SHA256
  - Sig stub: P-256 ECDSA

This means the same file format logic exists in both modes, but cryptographic strength differs by build target.

---

## 3) Main Vault (`.agvt`) Scheme

## 3.1 Header and Metadata Model

Vault header (`VaultHeader`) stores:

- magic: `AEGIRO\0\1`
- version (`UInt16`, currently `1`)
- algorithm IDs
- `kdf_salt` (32 bytes)
- `index_salt` (32 bytes)
- Argon2 parameter struct (`mMiB=256`, `t=3`, `p=1` by default metadata)
- PQ public keys (`kyber_pk`, `dilithium_pk`)
- flags
  - `bit0`: Touch ID enabled marker
  - `bit1`: PQC unlock mode (`vaultFlagPQCUnlockV1`)

Header serialization is JSON prefixed by magic + JSON length.

Reference code:

- `Sources/AegiroCore/VaultHeader.swift`
- `Sources/AegiroCore/Vault.swift` (`parseHeaderAndOffset`)

## 3.2 Key Hierarchy (Current PQC v1 Unlock Path)

On `create`:

1. Derive `PDK` from user passphrase:
   - `PDK = Argon2id(passphrase, kdf_salt, outLen=32)`
2. Generate random 32-byte keys:
   - `AccessKey`
   - `DEK` (data-encryption key)
3. Generate Kyber keypair (`kemPk`, `kemSk`) and Dilithium keypair (`sigPk`, `sigSk`)
4. Wrap chain:
   - `pdkWrap = AES-GCM(PDK, AccessKey, AAD="AEGIRO-V1")`
   - `kemSkWrap = AES-GCM(AccessKey, kemSk, AAD="AEGIRO-V1")`
   - `ss, kemCt = Kyber.encap(kemPk)`
   - `pqWrap = AES-GCM(ss, DEK, AAD="AEGIRO-V1")`
   - `signerSkWrap = AES-GCM(DEK, sigSk, AAD="AEGIRO-V1")`
5. Store `PQAccessBundleV1` JSON:
   - `{version, kemCiphertext, kemSecretWrap}`

On unlock:

1. Re-derive `PDK` from passphrase + header salt
2. Open `pdkWrap` to recover `AccessKey`
3. Decode `PQAccessBundleV1`
4. Open `kemSecretWrap` with `AccessKey` to recover `kemSk`
5. `ss = Kyber.decap(kemCiphertext, kemSk)`
6. Open `pqWrap` with `ss` to recover `DEK`

Legacy support:

- If PQC flag is unset, decrypted `pdkWrap` plaintext is treated directly as `DEK`.

Reference code:

- `Sources/AegiroCore/Vault.swift` (`AegiroVault.create`, `unlockDEK`, `inferUnlockMode`)

## 3.3 Vault AAD Domain

Main vault AEAD uses one shared AAD constant:

- `vaultAAD = "AEGIRO-V1"`

This AAD is applied to:

- key-wrap records
- encrypted index
- encrypted file chunks
- signer secret wrap

Reference code: `Sources/AegiroCore/Vault.swift`

## 3.4 File/Data Encryption

### 3.4.1 Index Encryption

Index object (`VaultIndex`) is JSON-encoded and AES-GCM encrypted under `DEK`:

- `idxBlob = AES-GCM(DEK, JSON(index), AAD="AEGIRO-V1")`

Reference: `Sources/AegiroCore/IndexManifest.swift` (`IndexCrypto`)

### 3.4.2 Chunk Encryption

Imported file bytes are split (currently 128 KiB chunks in import path).  
Each chunk is encrypted as AES-GCM combined blob and appended to a chunk area.

Nonce generation path:

1. `nameHash = HMAC-SHA256(index_salt, basename(filePath))`
2. `seedKey = HMAC-SHA256(DEK, nameHash)`
3. `nonce_i = HMAC-SHA256(seedKey, BE64(chunkIndex))[0..11]`

Then:

- `chunkBlob_i = AES-GCM(DEK, chunkPlain_i, nonce_i, AAD="AEGIRO-V1")`

`chunkMap` stores each chunk’s file name/path association and relative offset/length.

Reference code:

- `Sources/AegiroCore/Crypto.swift` (`NonceScheme`)
- `Sources/AegiroCore/Vault.swift` (`mergeImportedItems`)

## 3.5 Integrity and Authenticity Layer

A manifest object stores:

- `indexRootHash = SHA256(JSON(index))`
- `chunkMapHash = SHA256(chunkMapBytes)`
- `signature = Sign_dilithium(indexRootHash || chunkMapHash)`
- `signerPK`

Verification confirms signature validity for `indexRootHash || chunkMapHash`.

Reference code:

- `Sources/AegiroCore/IndexManifest.swift` (`ManifestBuilder`)
- `Sources/AegiroCore/Vault.swift` (`Doctor`, `VaultStatus`, `verify` command)

## 3.6 On-Disk Layout (Current Implemented Layout)

After header bytes:

1. `pdkWrap` (fixed 60 bytes: nonce 12 + ct 32 + tag 16)
2. `pqAccessBlobLen` (`u32 LE`)
3. `pqAccessBlob` (`PQAccessBundleV1` JSON)
4. `pqWrap` (fixed 60 bytes)
5. `signerWrapLen` (`u32 LE`)
6. `signerWrap` (AES-GCM wrapped signing SK)
7. `idxLen` (`u32 LE`)
8. `idxBlob` (encrypted index)
9. `manifestLen` (`u32 LE`)
10. `manifestBlob` (JSON)
11. `chunkMapLen` (`u32 LE`)
12. `chunkMapBlob` (JSON array of chunk descriptors)
13. `chunkArea` (concatenated encrypted chunk blobs)

Reference code:

- `Sources/AegiroCore/Vault.swift` (`readVaultReadComponents`, `computeLayout`)

---

## 4) APFS External Volume Recovery Scheme

Used by:

- `apfs-volume-encrypt`
- `apfs-volume-decrypt`

Goal: protect a randomly generated APFS disk passphrase inside a recovery JSON bundle.

Flow:

1. Generate random `diskPassphrase`
2. Derive `recoveryKey = Argon2id(recoveryPassphrase, kdf_salt)`
3. Generate Kyber keypair and encapsulate to produce `(sharedSecret, kemCiphertext)`
4. Wrap
   - `disk_passphrase_wrap = AES-GCM(sharedSecret, diskPassphrase, AAD="AEGIRO-DISK-V1:<diskID>")`
   - `kem_secret_wrap = AES-GCM(recoveryKey, kemSk, AAD="AEGIRO-DISK-V1:<diskID>")`
5. Persist `DiskRecoveryBundle` JSON
6. Call `diskutil apfs encryptVolume ... -stdinpassphrase`

Recovery/unlock reverses the wraps and invokes `diskutil apfs unlockVolume`.

Reference code:

- `Sources/AegiroCore/ExternalDiskCrypto.swift`

---

## 5) Portable USB Container Recovery Scheme

Used by:

- `usb-container-create`
- `usb-container-open`

Goal: protect a container passphrase used by `hdiutil` encrypted sparsebundle.

Flow:

1. Create or accept container passphrase
2. Derive `recoveryKey = Argon2id(recoveryPassphrase, kdf_salt)`
3. Kyber encapsulation produces `sharedSecret` and `kemCiphertext`
4. Wrap
   - `container_passphrase_wrap = AES-GCM(sharedSecret, containerPassphrase, AAD="AEGIRO-USB-CONTAINER-V1:<imagePath>")`
   - `kem_secret_wrap = AES-GCM(recoveryKey, kemSk, same AAD)`
5. Save recovery JSON bundle
6. `hdiutil create/attach` consumes real container passphrase

Reference code:

- `Sources/AegiroCore/USBContainerCrypto.swift`

---

## 6) FastEncryptionScheme Module (Separate Utility)

`FastEncryptionScheme` is a standalone chunked AEAD format with custom header (`AEGFAST1`) and per-chunk authentication bound to header bytes.

Key points:

- Header includes algorithm ID, chunk size, plaintext length, nonce prefix, key salt
- Session key = `HKDF(masterKey, salt=keySalt, info=algorithmID)`
- Per-chunk nonce = `noncePrefix(4B) || chunkIndex(8B little-endian)`
- Supports AES-GCM-256 and ChaCha20-Poly1305

Current status: implemented + unit-tested, but not the primary `.agvt` vault persistence path.

Reference code:

- `Sources/AegiroCore/FastEncryptionScheme.swift`
- `Tests/AegiroCoreTests/FastEncryptionSchemeTests.swift`

---

## 7) Validation and Repair (`doctor`)

`Doctor.run` can validate and optionally fix manifest mismatches.

Checks include:

- header parseability
- manifest signature validity
- signer key match against header
- chunk map hash match
- index hash match (if passphrase supplied)
- chunk map structural coverage (offset/length consistency)
- deep chunk authentication and plaintext-size reconciliation (when enabled)

Fix mode (`--fix`) can re-sign and rewrite manifest if decryptable state is available.

Reference code: `Sources/AegiroCore/Vault.swift` (`Doctor`)

---

## 8) Security Properties

Provided (at-rest model):

- confidentiality of vault index and file chunk payloads via AES-GCM + DEK
- integrity/authenticity of encrypted blobs via AEAD tags
- whole-state binding via manifest hashes + signature
- passphrase hardening via Argon2id
- PQC-assisted unlock chain in `REAL_CRYPTO` builds

Not provided:

- protection after host compromise/unlock
- hidden metadata (vault file size/timestamps and some plaintext metadata remain observable)
- remote key escrow/recovery service (all local files)

---

## 9) Important Implementation Notes and Caveats

1. Argon2 parameter structs are persisted in metadata/bundles, but current KDF calls use fixed defaults (`m=256 MiB, t=3, p=1`) in code paths today.  
2. `wraps_offsets` header fields exist but read logic uses sequential parsing rather than trusting those offsets.  
3. Legacy and PQC unlock modes coexist; a normalization helper can reconcile header flags with inferred mode.  
4. Current nonce seed for file chunks is derived from `nameHash`, where `nameHash` uses file basename hashing (`lastPathComponent`) with `index_salt`. This means duplicate basenames across directories share nonce-seed material under one `DEK` domain. Treat this as an implementation detail requiring careful review before claiming formal nonce-domain separation.

---

## 10) AGVT v2 Spec vs Current Runtime

`SPEC_AGVT_V2.md` defines a newer dual-superblock append-only format with record framing and expanded profile rules.  
Current runtime `.agvt` operations are still driven by the v1-style JSON-header + wraps/index/manifest/chunk-map layout described in this paper.

In short:

- AGVT v2 spec: present as design/specification target
- Production code path today: v1-style layout in `Vault.swift`

---

## 11) Source Map (Quick Audit Index)

- Core crypto primitives: `Sources/AegiroCore/Crypto.swift`  
- Vault header model: `Sources/AegiroCore/VaultHeader.swift`  
- Vault creation/import/export/unlock/doctor: `Sources/AegiroCore/Vault.swift`  
- Index + manifest hashing/signature: `Sources/AegiroCore/IndexManifest.swift`  
- PQ wrappers: `Sources/AegiroCore/PQC.swift`  
- APFS recovery bundle crypto: `Sources/AegiroCore/ExternalDiskCrypto.swift`  
- USB container recovery bundle crypto: `Sources/AegiroCore/USBContainerCrypto.swift`  
- Alternative fast chunk scheme: `Sources/AegiroCore/FastEncryptionScheme.swift`

