
import Foundation
import CryptoKit

public struct VaultIndexEntry: Codable {
    public var fileID: Data
    public var nameHash: Data
    public var logicalPath: String
    public var size: UInt64
    public var mime: String
    public var tags: [String]
    public var chunkCount: Int
    public var chunkCrypto: VaultChunkCrypto
    public var created: Date
    public var modified: Date
    public var sidecarName: String?
}

public struct VaultChunkCrypto: Codable {
    public var format: UInt8
    public var algorithm: UInt8
    public var keySalt: Data
    public var noncePrefix: Data
}

public struct ChunkInfo: Codable {
    public var fileID: Data
    public var ordinal: UInt32
    public var relOffset: UInt64
    public var length: Int
}

public struct VaultIndex: Codable {
    public var entries: [VaultIndexEntry]
    public var thumbnails: [String: Data] // nameHash(hex) -> small image data
}

public struct VaultIndexPage: Codable {
    public var entries: [VaultIndexEntry]
    public var totalCount: Int
    public var nextOffset: Int
    public var hasMore: Bool
}

public struct Manifest: Codable {
    public var indexRootHash: Data // SHA256(JSON of index)
    public var chunkMapHash: Data  // SHA256(concat of chunk ids & sizes)
    public var signature: Data
    public var signerPK: Data
}

public struct IndexCrypto {
    public static func encryptIndex(_ index: VaultIndex, key: SymmetricKey, aad: Data) throws -> Data {
        let data = try JSONEncoder().encode(index)
        let sealed = try AES.GCM.seal(data, using: key, authenticating: aad)
        return sealed.combined ?? Data()
    }
    public static func decryptIndex(_ blob: Data, key: SymmetricKey, aad: Data) throws -> VaultIndex {
        let box = try AES.GCM.SealedBox(combined: blob)
        let data = try AES.GCM.open(box, using: key, authenticating: aad)
        return try JSONDecoder().decode(VaultIndex.self, from: data)
    }
}

public struct ManifestBuilder {
    public static func build(index: VaultIndex, chunkMap: Data, signer: PQSig, sk: Data, pk: Data) throws -> Manifest {
        let idx = try JSONEncoder().encode(index)
        let idxHash = Data(SHA256.hash(data: idx))
        let cmHash  = Data(SHA256.hash(data: chunkMap))
        let msg = idxHash + cmHash
        let sig = try signer.sign(message: msg, sk: sk)
        return Manifest(indexRootHash: idxHash, chunkMapHash: cmHash, signature: sig, signerPK: pk)
    }
    public static func verify(_ m: Manifest, signer: PQSig) -> Bool {
        let msg = m.indexRootHash + m.chunkMapHash
        return signer.verify(message: msg, sig: m.signature, pk: m.signerPK)
    }
}

public enum ManifestIO {
    private static func readExactBytes(from handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw NSError(domain: "ManifestIO", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected end of vault while loading manifest"])
        }
        return data
    }

    private static func readUInt32LE(from handle: FileHandle, offset: UInt64) throws -> UInt32 {
        let data = try readExactBytes(from: handle, offset: offset, count: 4)
        return data.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
    }

    public static func load(from vaultURL: URL) throws -> Manifest {
        let handle = try FileHandle(forReadingFrom: vaultURL)
        defer { try? handle.close() }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: vaultURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard fileSize > 12 else {
            throw NSError(domain: "ManifestIO", code: -2, userInfo: [NSLocalizedDescriptionKey: "Vault file is too small"])
        }

        let probeSizes: [Int] = [8 * 1024, 64 * 1024, 512 * 1024, 2 * 1024 * 1024]
        var parsedHeader: (VaultHeader, Int)?
        for size in probeSizes {
            let readCount = Int(min(UInt64(size), fileSize))
            guard readCount > 0 else { break }
            let prefix = try readExactBytes(from: handle, offset: 0, count: readCount)
            if let result = try? parseHeaderAndOffset(prefix) {
                parsedHeader = result
                break
            }
            if UInt64(readCount) >= fileSize {
                break
            }
        }

        guard let (_, hdrLen) = parsedHeader else {
            throw NSError(domain: "ManifestIO", code: -3, userInfo: [NSLocalizedDescriptionKey: "Could not parse vault header"])
        }

        var cursor = UInt64(hdrLen)
        cursor += 60
        let ctLen = UInt64(try readUInt32LE(from: handle, offset: cursor))
        cursor += 4 + ctLen
        cursor += 60
        let signerLen = UInt64(try readUInt32LE(from: handle, offset: cursor))
        cursor += 4 + signerLen
        let idxLen = UInt64(try readUInt32LE(from: handle, offset: cursor))
        cursor += 4 + idxLen
        let manLen = Int(try readUInt32LE(from: handle, offset: cursor))
        cursor += 4
        let manBlob = try readExactBytes(from: handle, offset: cursor, count: manLen)
        return try JSONDecoder().decode(Manifest.self, from: manBlob)
    }
}
