
import Foundation
import CryptoKit

public enum AEGError: Error {
    case crypto(String)
    case io(String)
    case integrity(String)
    case unsupported(String)
}

public struct NonceScheme {
    public static func nonce(fileSeed: SymmetricKey, chunkIndex: UInt64) -> AES.GCM.Nonce {
        let ci = withUnsafeBytes(of: chunkIndex.bigEndian, Array.init)
        let mac = HMAC<SHA256>.authenticationCode(for: ci, using: fileSeed)
        let twelve = Data(mac.prefix(12))
        if let nonce = try? AES.GCM.Nonce(data: twelve) {
            return nonce
        }
        assertionFailure("Failed to derive AES-GCM nonce from deterministic HMAC output")
        return AES.GCM.Nonce()
    }
}

public struct AEAD {
    public static func encrypt(key: SymmetricKey, nonce: AES.GCM.Nonce, plaintext: Data, aad: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        guard let combined = sealed.combined else {
            throw AEGError.crypto("AES-GCM combined ciphertext was unavailable")
        }
        return combined
    }
    public static func decrypt(key: SymmetricKey, nonce: AES.GCM.Nonce, combined: Data, aad: Data) throws -> Data {
        let sealed = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(sealed, using: key, authenticating: aad)
    }
}

public protocol KDF {
    func deriveKey(passphrase: String, salt: Data, outLen: Int) throws -> Data
}

import Argon2C
public struct Argon2idKDF: KDF {
    public func deriveKey(passphrase: String, salt: Data, outLen: Int) throws -> Data {
        // Default parameters align with VaultHeader defaults
        let t_cost: UInt32 = 3
        let m_cost: UInt32 = 256 * 1024 // KiB
        let parallelism: UInt32 = 1

        var out = Data(count: outLen)
        let pwd = Data(passphrase.utf8)

        let rc = salt.withUnsafeBytes { saltRaw -> Int32 in
            out.withUnsafeMutableBytes { outRaw -> Int32 in
                pwd.withUnsafeBytes { pwdRaw -> Int32 in
                    guard let pwdPtr = pwdRaw.baseAddress, let saltPtr = saltRaw.baseAddress, let outPtr = outRaw.baseAddress else {
                        return -1
                    }
                    return argon2id_hash_raw(t_cost, m_cost, parallelism,
                                             pwdPtr, pwd.count,
                                             saltPtr, salt.count,
                                             outPtr, outLen)
                }
            }
        }

        if rc != 0 {
            throw AEGError.crypto("argon2id_hash_raw failed: \(rc)")
        }
        return out
    }
}

public struct HMACUtil {
    public static func hmacNameHash(_ name: String, salt: Data) -> Data {
        let key = SymmetricKey(data: salt)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(name.utf8), using: key)
        return Data(mac)
    }
}
