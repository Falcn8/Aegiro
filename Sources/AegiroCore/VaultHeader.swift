
import Foundation

public struct AlgIDs: Codable {
    public var aead: UInt16 // 1 = AGVT chunk AEAD (AES-GCM or ChaCha20-Poly1305)
    public var kdf: UInt16  // 2 = Argon2id
    public var kem: UInt16  // 3 = Kyber512
    public var sig: UInt16  // 4 = Dilithium2
}

public struct Argon2Params: Codable {
    public var mMiB: UInt32
    public var t: UInt16
    public var p: UInt8
}

public struct PQPublicKeys: Codable {
    public var kyber_pk: Data
    public var dilithium_pk: Data
}

public struct WrapOffsets: Codable {
    public var pdk_off: UInt32
    public var sdk_off: UInt32
    public var pqc_off: UInt32
}

public struct VaultHeader: Codable {
    public var magic: [UInt8] // "AEGIRO\0\1"
    public var header_len: UInt32
    public var version: UInt16
    public var created_unix: UInt64
    public var alg_ids: AlgIDs
    public var kdf_salt: Data // 32B
    public var index_salt: Data // 32B
    public var argon2: Argon2Params
    public var pq_pubkeys: PQPublicKeys
    public var wraps_offsets: WrapOffsets
    public var flags: UInt32 // bitfield
    public var reserved: Data // 128B

    public static let MAGIC: [UInt8] = Array("AEGIRO".utf8) + [0x00, 0x01]

    public init(alg: AlgIDs, argon2: Argon2Params, pq: PQPublicKeys) {
        self.magic = Self.MAGIC
        self.header_len = 0
        self.version = 1
        self.created_unix = UInt64(Date().timeIntervalSince1970)
        self.alg_ids = alg
        self.kdf_salt = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        self.index_salt = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        self.argon2 = argon2
        self.pq_pubkeys = pq
        self.wraps_offsets = WrapOffsets(pdk_off: 0, sdk_off: 0, pqc_off: 0)
        self.flags = 0
        self.reserved = Data(count: 128)
    }
}

extension VaultHeader {
    public func serialize() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        var hdr = self
        // Set header_len to 0 inside JSON for stable encoding size
        hdr.header_len = 0
        let json = try enc.encode(hdr)
        var out = Data(Self.MAGIC)
        var lenLE = UInt32(json.count).littleEndian
        withUnsafeBytes(of: &lenLE) { out.append(contentsOf: $0) }
        out.append(json)
        return out
    }

    public static func parse(_ data: Data) throws -> VaultHeader {
        guard data.count > 12 else { throw NSError(domain: "VaultHeader", code: -1) }
        let prefix = data.prefix(8)
        guard Array(prefix) == Self.MAGIC else { throw NSError(domain: "VaultHeader", code: -2) }
        let lenBytes = data.dropFirst(8).prefix(4)
        let headerLen = lenBytes.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        let jsonStart = 12
        guard data.count >= jsonStart + Int(headerLen) else { throw NSError(domain: "VaultHeader", code: -3) }
        let json = data.subdata(in: jsonStart..<(jsonStart + Int(headerLen)))
        let dec = JSONDecoder()
        return try dec.decode(VaultHeader.self, from: json)
    }
}
