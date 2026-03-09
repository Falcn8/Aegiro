import Foundation

public enum AGVTV2 {
    public static let superblockSize = 4096
    public static let dualSuperblockSize = superblockSize * 2
    public static let recordHeaderSize = 20

    // Matches SPEC_AGVT_V2.md draft bytes; revisit only with coordinated format bump.
    public static let superblockMagic = Data([0x41, 0x47, 0x56, 0x54, 0x32, 0x00, 0x00, 0x01]) // "AGVT2\0\0\1"
}

public struct AGVTV2Superblock: Equatable, Sendable {
    public static let hashLength = 32
    public static let fixedFieldLengthWithoutCRC = 80
    public static let fixedFieldLengthWithCRC = fixedFieldLengthWithoutCRC + 4

    public var superblockVersion: UInt16
    public var profileID: UInt16
    public var vaultUUID: UUID
    public var epoch: UInt64
    public var activeManifestOffset: UInt64
    public var activeManifestLength: UInt32
    public var activeManifestHash: Data
    public var headerCRC32: UInt32

    public init(superblockVersion: UInt16 = 1,
                profileID: UInt16,
                vaultUUID: UUID,
                epoch: UInt64,
                activeManifestOffset: UInt64,
                activeManifestLength: UInt32,
                activeManifestHash: Data,
                headerCRC32: UInt32 = 0) throws {
        guard activeManifestHash.count == Self.hashLength else {
            throw AEGError.integrity("AGVTV2 superblock hash must be \(Self.hashLength) bytes")
        }
        self.superblockVersion = superblockVersion
        self.profileID = profileID
        self.vaultUUID = vaultUUID
        self.epoch = epoch
        self.activeManifestOffset = activeManifestOffset
        self.activeManifestLength = activeManifestLength
        self.activeManifestHash = activeManifestHash
        self.headerCRC32 = headerCRC32
    }

    public func encode() throws -> Data {
        var out = Data()
        out.reserveCapacity(AGVTV2.superblockSize)
        out.append(AGVTV2.superblockMagic)
        out.appendLE(superblockVersion)
        out.appendLE(profileID)
        out.append(vaultUUID.data)
        out.appendLE(epoch)
        out.appendLE(activeManifestOffset)
        out.appendLE(activeManifestLength)
        out.append(activeManifestHash)
        out.appendLE(UInt32(0)) // placeholder for CRC32

        let crc = AGVTV2CRC32.checksum(out.prefix(Self.fixedFieldLengthWithoutCRC))
        var withCRC = out
        withCRC.replaceSubrange(Self.fixedFieldLengthWithoutCRC..<Self.fixedFieldLengthWithCRC, with: crc.littleEndianData)
        if withCRC.count > AGVTV2.superblockSize {
            throw AEGError.integrity("AGVTV2 superblock overflow")
        }
        withCRC.append(Data(repeating: 0, count: AGVTV2.superblockSize - withCRC.count))
        return withCRC
    }

    public static func decode(from data: Data) throws -> AGVTV2Superblock {
        guard data.count >= AGVTV2.superblockSize else {
            throw AEGError.integrity("AGVTV2 superblock is truncated")
        }
        let block = data.prefix(AGVTV2.superblockSize)
        var cursor = AGVTV2DataCursor(data: Data(block))

        let magic = try cursor.read(count: AGVTV2.superblockMagic.count)
        guard magic == AGVTV2.superblockMagic else {
            throw AEGError.integrity("AGVTV2 superblock magic mismatch")
        }

        let superblockVersion = try cursor.readLEUInt16()
        let profileID = try cursor.readLEUInt16()
        let uuidBytes = try cursor.read(count: 16)
        guard let uuid = UUID(data: uuidBytes) else {
            throw AEGError.integrity("AGVTV2 superblock UUID is invalid")
        }

        let epoch = try cursor.readLEUInt64()
        let manifestOffset = try cursor.readLEUInt64()
        let manifestLength = try cursor.readLEUInt32()
        let manifestHash = try cursor.read(count: Self.hashLength)
        let storedCRC = try cursor.readLEUInt32()

        let expectedCRC = AGVTV2CRC32.checksum(block.prefix(Self.fixedFieldLengthWithoutCRC))
        guard storedCRC == expectedCRC else {
            throw AEGError.integrity("AGVTV2 superblock CRC mismatch")
        }

        return try AGVTV2Superblock(superblockVersion: superblockVersion,
                                    profileID: profileID,
                                    vaultUUID: uuid,
                                    epoch: epoch,
                                    activeManifestOffset: manifestOffset,
                                    activeManifestLength: manifestLength,
                                    activeManifestHash: manifestHash,
                                    headerCRC32: storedCRC)
    }
}

public enum AGVTV2SuperblockSelector {
    public static func selectActive(_ a: AGVTV2Superblock, _ b: AGVTV2Superblock) -> AGVTV2Superblock {
        if a.epoch != b.epoch {
            return a.epoch > b.epoch ? a : b
        }
        // Tie-breaker keeps behavior deterministic.
        if a.activeManifestOffset != b.activeManifestOffset {
            return a.activeManifestOffset > b.activeManifestOffset ? a : b
        }
        return a
    }

    public static func loadActive(from data: Data) throws -> AGVTV2Superblock {
        guard data.count >= AGVTV2.dualSuperblockSize else {
            throw AEGError.integrity("AGVTV2 file too small for dual superblocks")
        }
        let aData = data.subdata(in: 0..<AGVTV2.superblockSize)
        let bData = data.subdata(in: AGVTV2.superblockSize..<AGVTV2.dualSuperblockSize)
        let a = try? AGVTV2Superblock.decode(from: aData)
        let b = try? AGVTV2Superblock.decode(from: bData)
        switch (a, b) {
        case let (lhs?, rhs?):
            return selectActive(lhs, rhs)
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (nil, nil):
            throw AEGError.integrity("AGVTV2 could not decode either superblock slot")
        }
    }
}

public struct AGVTV2RecordHeader: Equatable, Sendable {
    public var recordType: UInt16
    public var recordVersion: UInt16
    public var recordFlags: UInt32
    public var payloadLength: UInt64
    public var payloadCRC32: UInt32

    public init(recordType: UInt16, recordVersion: UInt16, recordFlags: UInt32, payloadLength: UInt64, payloadCRC32: UInt32) {
        self.recordType = recordType
        self.recordVersion = recordVersion
        self.recordFlags = recordFlags
        self.payloadLength = payloadLength
        self.payloadCRC32 = payloadCRC32
    }

    public func encode() -> Data {
        var out = Data()
        out.reserveCapacity(AGVTV2.recordHeaderSize)
        out.appendLE(recordType)
        out.appendLE(recordVersion)
        out.appendLE(recordFlags)
        out.appendLE(payloadLength)
        out.appendLE(payloadCRC32)
        return out
    }

    public static func decode(from data: Data) throws -> AGVTV2RecordHeader {
        guard data.count >= AGVTV2.recordHeaderSize else {
            throw AEGError.integrity("AGVTV2 record header is truncated")
        }
        var cursor = AGVTV2DataCursor(data: data)
        return AGVTV2RecordHeader(recordType: try cursor.readLEUInt16(),
                                  recordVersion: try cursor.readLEUInt16(),
                                  recordFlags: try cursor.readLEUInt32(),
                                  payloadLength: try cursor.readLEUInt64(),
                                  payloadCRC32: try cursor.readLEUInt32())
    }
}

private struct AGVTV2DataCursor {
    private let data: Data
    private var offset: Int = 0

    init(data: Data) {
        self.data = data
    }

    mutating func read(count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw AEGError.integrity("AGVTV2 decode exceeded payload bounds")
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func readLEUInt16() throws -> UInt16 {
        let chunk = try read(count: MemoryLayout<UInt16>.size)
        return chunk.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
    }

    mutating func readLEUInt32() throws -> UInt32 {
        let chunk = try read(count: MemoryLayout<UInt32>.size)
        return chunk.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }

    mutating func readLEUInt64() throws -> UInt64 {
        let chunk = try read(count: MemoryLayout<UInt64>.size)
        return chunk.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
    }
}

private enum AGVTV2CRC32 {
    // Standard IEEE polynomial 0xEDB88320.
    private static let table: [UInt32] = {
        (0..<256).map { i in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func checksum(_ bytes: some DataProtocol) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for part in bytes.regions {
            for b in part {
                let idx = Int((crc ^ UInt32(b)) & 0xFF)
                crc = table[idx] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE(_ v: UInt16) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ v: UInt32) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ v: UInt64) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
}

private extension UUID {
    var data: Data {
        var u = uuid
        return withUnsafeBytes(of: &u) { Data($0) }
    }

    init?(data: Data) {
        guard data.count == 16 else { return nil }
        var bytes: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        _ = Swift.withUnsafeMutableBytes(of: &bytes) { dst in
            data.copyBytes(to: dst)
        }
        self = UUID(uuid: bytes)
    }
}

private extension UInt32 {
    var littleEndianData: Data {
        var value = littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
