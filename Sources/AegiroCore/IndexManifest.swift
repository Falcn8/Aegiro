
import Foundation
import CryptoKit

public struct VaultIndexEntry: Codable {
    public var nameHash: Data
    public var logicalPath: String
    public var size: UInt64
    public var mime: String
    public var tags: [String]
    public var chunkCount: Int
    public var created: Date
    public var modified: Date
    public var sidecarName: String?
}

public struct ChunkInfo: Codable {
    public var name: String
    public var relOffset: UInt64
    public var length: Int
}

public struct VaultIndex: Codable {
    public var entries: [VaultIndexEntry]
    public var thumbnails: [String: Data] // nameHash(hex) -> small image data
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
    public static func load(from vaultURL: URL) throws -> Manifest {
        let data = try Data(contentsOf: vaultURL)
        let (head, hdrLen) = try parseHeaderAndOffset(data)
        // leverage Vault.swift layout helper by duplicating minimal offsets logic here
        var cursor = hdrLen
        cursor += 60
        let ctLen = data.subdata(in: cursor..<(cursor+4)).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        cursor += 4 + Int(ctLen)
        cursor += 60
        let signerLen = data.subdata(in: cursor..<(cursor+4)).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        cursor += 4 + Int(signerLen)
        let idxLen = data.subdata(in: cursor..<(cursor+4)).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        cursor += 4 + Int(idxLen)
        let manLen = data.subdata(in: cursor..<(cursor+4)).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        cursor += 4
        let manBlob = data.subdata(in: cursor..<(cursor + Int(manLen)))
        return try JSONDecoder().decode(Manifest.self, from: manBlob)
    }
}
