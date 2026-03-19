import Foundation
import CryptoKit
import Security

public enum FastEncryptionScheme {
    public enum Algorithm: UInt8, Sendable {
        case aesGCM256 = 1
        case chaChaPoly1305 = 2
    }

    public static let version: UInt8 = 1
    public static let magic = Data("AEGFAST1".utf8)
    public static let headerSize = 32
    public static let defaultChunkSize = 1 << 20 // 1 MiB
    private static let tagSize = 16
    private static let noncePrefixSize = 4
    private static let nonceSize = 12

    public static func preferredAlgorithm() -> Algorithm {
        #if arch(arm64)
        return .aesGCM256
        #else
        return .chaChaPoly1305
        #endif
    }

    public static func generateMasterKey() throws -> SymmetricKey {
        return SymmetricKey(data: try randomBytes(count: 32))
    }

    public static func encrypt(plaintext: Data,
                               masterKey: SymmetricKey,
                               chunkSize: Int = defaultChunkSize,
                               algorithm: Algorithm? = nil) throws -> Data {
        let selected = algorithm ?? preferredAlgorithm()
        guard chunkSize > 0, chunkSize <= 16 * 1024 * 1024 else {
            throw AEGError.crypto("chunkSize must be between 1 and 16777216 bytes")
        }
        guard UInt64(plaintext.count) <= UInt64(Int.max) else {
            throw AEGError.crypto("plaintext too large")
        }

        let noncePrefix = try randomBytes(count: noncePrefixSize)
        let header = try makeHeader(algorithm: selected,
                                    chunkSize: chunkSize,
                                    plaintextLength: UInt64(plaintext.count),
                                    noncePrefix: noncePrefix)
        let sessionKey = deriveSessionKey(masterKey: masterKey, algorithm: selected)

        let chunkCount = chunkCountFor(plaintextLength: plaintext.count, chunkSize: chunkSize)
        let expectedCipherLen = try encryptedPayloadLength(plaintextLength: plaintext.count, chunkSize: chunkSize)
        let capacity = header.count + expectedCipherLen

        var out = Data()
        out.reserveCapacity(capacity)
        out.append(header)

        if chunkCount == 0 {
            return out
        }

        for chunkIndex in 0..<chunkCount {
            let start = chunkIndex * chunkSize
            let end = min(start + chunkSize, plaintext.count)
            let chunk = plaintext[start..<end]
            let nonceData = nonceBytes(prefix: noncePrefix, chunkIndex: UInt64(chunkIndex))

            switch selected {
            case .aesGCM256:
                let nonce = try AES.GCM.Nonce(data: nonceData)
                let sealed = try AES.GCM.seal(chunk, using: sessionKey, nonce: nonce, authenticating: header)
                out.append(sealed.ciphertext)
                out.append(sealed.tag)
            case .chaChaPoly1305:
                let nonce = try ChaChaPoly.Nonce(data: nonceData)
                let sealed = try ChaChaPoly.seal(chunk, using: sessionKey, nonce: nonce, authenticating: header)
                out.append(sealed.ciphertext)
                out.append(sealed.tag)
            }
        }

        return out
    }

    public static func decrypt(ciphertext: Data, masterKey: SymmetricKey) throws -> Data {
        let header = try parseHeader(ciphertext)
        let body = Data(ciphertext.dropFirst(headerSize))
        let expectedBodyLength = try encryptedPayloadLength(plaintextLength: Int(header.plaintextLength),
                                                            chunkSize: Int(header.chunkSize))
        guard body.count == expectedBodyLength else {
            throw AEGError.integrity("Encrypted payload length mismatch")
        }

        let sessionKey = deriveSessionKey(masterKey: masterKey, algorithm: header.algorithm)
        let chunkSize = Int(header.chunkSize)
        let chunkCount = chunkCountFor(plaintextLength: Int(header.plaintextLength), chunkSize: chunkSize)

        var plaintext = Data()
        plaintext.reserveCapacity(Int(header.plaintextLength))
        var bodyOffset = 0

        for chunkIndex in 0..<chunkCount {
            let remainingPlain = Int(header.plaintextLength) - (chunkIndex * chunkSize)
            let plainLen = min(chunkSize, remainingPlain)
            let cipherLen = plainLen + tagSize
            let chunkSlice = body[bodyOffset..<(bodyOffset + cipherLen)]
            bodyOffset += cipherLen

            let encSlice = chunkSlice.prefix(plainLen)
            let tagSlice = chunkSlice.suffix(tagSize)
            let nonceData = nonceBytes(prefix: header.noncePrefix, chunkIndex: UInt64(chunkIndex))

            switch header.algorithm {
            case .aesGCM256:
                let nonce = try AES.GCM.Nonce(data: nonceData)
                let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: encSlice, tag: tagSlice)
                let dec = try AES.GCM.open(sealed, using: sessionKey, authenticating: header.raw)
                plaintext.append(dec)
            case .chaChaPoly1305:
                let nonce = try ChaChaPoly.Nonce(data: nonceData)
                let sealed = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: encSlice, tag: tagSlice)
                let dec = try ChaChaPoly.open(sealed, using: sessionKey, authenticating: header.raw)
                plaintext.append(dec)
            }
        }

        return plaintext
    }

    private struct ParsedHeader {
        let raw: Data
        let algorithm: Algorithm
        let chunkSize: UInt32
        let plaintextLength: UInt64
        let noncePrefix: Data
    }

    private static func makeHeader(algorithm: Algorithm,
                                   chunkSize: Int,
                                   plaintextLength: UInt64,
                                   noncePrefix: Data) throws -> Data {
        guard noncePrefix.count == noncePrefixSize else {
            throw AEGError.crypto("Invalid nonce prefix")
        }

        var out = Data()
        out.reserveCapacity(headerSize)
        out.append(magic)
        out.append(version)
        out.append(algorithm.rawValue)
        out.append(leData(UInt32(chunkSize)))
        out.append(leData(plaintextLength))
        out.append(noncePrefix)
        out.append(Data(repeating: 0, count: headerSize - out.count))
        return out
    }

    private static func parseHeader(_ ciphertext: Data) throws -> ParsedHeader {
        guard ciphertext.count >= headerSize else {
            throw AEGError.integrity("Ciphertext too small for fast-encryption header")
        }
        let header = ciphertext.prefix(headerSize)
        let headerData = Data(header)
        guard headerData.prefix(magic.count) == magic else {
            throw AEGError.integrity("Fast-encryption header magic mismatch")
        }
        guard headerData[8] == version else {
            throw AEGError.unsupported("Unsupported fast-encryption version: \(headerData[8])")
        }
        guard let algorithm = Algorithm(rawValue: headerData[9]) else {
            throw AEGError.unsupported("Unsupported fast-encryption algorithm: \(headerData[9])")
        }

        let chunkSize = readLEUInt32(headerData, at: 10)
        guard chunkSize > 0, chunkSize <= 16 * 1024 * 1024 else {
            throw AEGError.integrity("Invalid chunk size in fast-encryption header")
        }

        let plaintextLength = readLEUInt64(headerData, at: 14)
        guard plaintextLength <= UInt64(Int.max) else {
            throw AEGError.integrity("Plaintext length exceeds supported range")
        }

        let noncePrefix = headerData.subdata(in: 22..<26)
        return ParsedHeader(raw: headerData,
                            algorithm: algorithm,
                            chunkSize: chunkSize,
                            plaintextLength: plaintextLength,
                            noncePrefix: noncePrefix)
    }

    private static func deriveSessionKey(masterKey: SymmetricKey, algorithm: Algorithm) -> SymmetricKey {
        let salt = Data("AEGIRO-FAST-SCHEME-V1".utf8)
        let info = Data([algorithm.rawValue])
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: masterKey,
                                      salt: salt,
                                      info: info,
                                      outputByteCount: 32)
    }

    private static func nonceBytes(prefix: Data, chunkIndex: UInt64) -> Data {
        var out = Data()
        out.reserveCapacity(nonceSize)
        out.append(prefix)
        out.append(leData(chunkIndex))
        return out
    }

    private static func chunkCountFor(plaintextLength: Int, chunkSize: Int) -> Int {
        guard plaintextLength > 0 else { return 0 }
        return (plaintextLength + chunkSize - 1) / chunkSize
    }

    private static func encryptedPayloadLength(plaintextLength: Int, chunkSize: Int) throws -> Int {
        guard plaintextLength >= 0 else {
            throw AEGError.crypto("Invalid plaintext length")
        }
        guard chunkSize > 0 else {
            throw AEGError.crypto("Invalid chunk size")
        }
        let fullChunks = plaintextLength / chunkSize
        let lastChunk = plaintextLength % chunkSize
        var total = fullChunks * (chunkSize + tagSize)
        if lastChunk > 0 {
            total += lastChunk + tagSize
        }
        if total < 0 {
            throw AEGError.crypto("Encrypted payload length overflow")
        }
        return total
    }

    private static func randomBytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { raw in
            SecRandomCopyBytes(kSecRandomDefault, count, raw.baseAddress!)
        }
        if status != errSecSuccess {
            throw AEGError.crypto("SecRandomCopyBytes failed: \(status)")
        }
        return data
    }

    private static func leData(_ v: UInt32) -> Data {
        var x = v.littleEndian
        return withUnsafeBytes(of: &x) { Data($0) }
    }

    private static func leData(_ v: UInt64) -> Data {
        var x = v.littleEndian
        return withUnsafeBytes(of: &x) { Data($0) }
    }

    private static func readLEUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let range = offset..<(offset + MemoryLayout<UInt32>.size)
        return data.subdata(in: range).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }

    private static func readLEUInt64(_ data: Data, at offset: Int) -> UInt64 {
        let range = offset..<(offset + MemoryLayout<UInt64>.size)
        return data.subdata(in: range).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
    }
}
