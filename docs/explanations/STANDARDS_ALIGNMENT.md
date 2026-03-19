# Aegiro Standards Alignment (Current Implementation)

_Last reviewed: 2026-03-19_

## Scope and wording

This document lists standards and guidance that the current implementation **meets or aligns with** based on implemented algorithms and construction choices.

- "Meets" here means implementation-level conformance to the listed guidance/algorithm usage.
- This document does **not** claim formal third-party certification unless explicitly stated.

## Formal certification claims

- No formal certification claim is currently made in-repo for:
  - FIPS 140-3 module validation (CMVP)
  - NIAP/CSfC validation
  - EUCC product certification

## Standards/guidance currently met or aligned

| Standard / Guidance | Status | Why | Evidence in code |
|---|---|---|---|
| OWASP Password Storage Cheat Sheet | Aligned | Uses Argon2id with strong parameters (`m=256 MiB, t=3, p=1`) for passphrase-derived keys. | `Sources/AegiroCore/Crypto.swift`, `Sources/AegiroCore/Vault.swift` |
| OWASP Cryptographic Storage Cheat Sheet | Aligned | Uses authenticated encryption (AES-GCM), CSPRNG for secret material, and avoids custom crypto algorithms. | `Sources/AegiroCore/Crypto.swift`, `Sources/AegiroCore/Vault.swift`, `Sources/AegiroCore/ExternalDiskCrypto.swift`, `Sources/AegiroCore/USBContainerCrypto.swift` |
| NIST SP 800-38D (GCM mode) | Uses standard primitive | AES-GCM is used for key wrapping and protected blobs. | `Sources/AegiroCore/Crypto.swift`, `Sources/AegiroCore/Vault.swift` |
| NIST FIPS 180-4 (SHA-2 family) | Uses standard primitive | SHA-256 is used for hashes and HKDF/HMAC-related constructions. | `Sources/AegiroCore/Vault.swift`, `Sources/AegiroCore/IndexManifest.swift`, `Sources/AegiroCore/Backup.swift` |
| NIST FIPS 198-1 (HMAC) | Uses standard primitive | HMAC-SHA256 is used for deterministic name hashing. | `Sources/AegiroCore/Crypto.swift` |
| RFC 5869 (HKDF) | Uses standard primitive | HKDF-SHA256 is used to derive per-file keys from DEK and salts/context labels. | `Sources/AegiroCore/Vault.swift` |
| RFC 8439 (ChaCha20-Poly1305) | Uses standard primitive | ChaCha20-Poly1305 is implemented as a supported chunk AEAD option. | `Sources/AegiroCore/Vault.swift` |
| CRYPTREC algorithm-list overlap (Japan) | Partial alignment | Implementation uses several algorithms present on CRYPTREC lists (AES, GCM, HMAC, SHA-256, ChaCha20-Poly1305). | `Sources/AegiroCore/Vault.swift`, `Sources/AegiroCore/Crypto.swift` |

## Important boundary (to prevent over-claims)

The current implementation includes strong cryptography, but this document does not imply compliance with stricter profiles that require specific parameter sets and/or validated modules (for example, CNSA 2.0, strict FIPS module validation, or EUCC certification profiles).

## External references

- OWASP Password Storage Cheat Sheet: <https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html>
- OWASP Cryptographic Storage Cheat Sheet: <https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html>
- NIST SP 800-38D (GCM): <https://csrc.nist.gov/pubs/sp/800/38/d/final>
- NIST FIPS 180-4 (SHA): <https://csrc.nist.gov/pubs/fips/180-4/upd1/final>
- NIST FIPS 198-1 (HMAC): <https://csrc.nist.gov/pubs/fips/198-1/final>
- RFC 5869 (HKDF): <https://www.rfc-editor.org/rfc/rfc5869>
- RFC 8439 (ChaCha20-Poly1305): <https://www.rfc-editor.org/rfc/rfc8439>
- CRYPTREC list page: <https://www.cryptrec.go.jp/method.html>
