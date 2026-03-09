import XCTest
@testable import AegiroCore

final class FormatV2Tests: XCTestCase {
    func testSuperblockRoundTrip() throws {
        let uuid = UUID()
        let hash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let sb = try AGVTV2Superblock(profileID: 2,
                                      vaultUUID: uuid,
                                      epoch: 7,
                                      activeManifestOffset: 123_456,
                                      activeManifestLength: 8192,
                                      activeManifestHash: hash)

        let encoded = try sb.encode()
        XCTAssertEqual(encoded.count, AGVTV2.superblockSize)

        let decoded = try AGVTV2Superblock.decode(from: encoded)
        XCTAssertEqual(decoded.superblockVersion, 1)
        XCTAssertEqual(decoded.profileID, 2)
        XCTAssertEqual(decoded.vaultUUID, uuid)
        XCTAssertEqual(decoded.epoch, 7)
        XCTAssertEqual(decoded.activeManifestOffset, 123_456)
        XCTAssertEqual(decoded.activeManifestLength, 8192)
        XCTAssertEqual(decoded.activeManifestHash, hash)
    }

    func testSuperblockRejectsCRCFailure() throws {
        let sb = try AGVTV2Superblock(profileID: 1,
                                      vaultUUID: UUID(),
                                      epoch: 1,
                                      activeManifestOffset: 0,
                                      activeManifestLength: 0,
                                      activeManifestHash: Data(repeating: 0xAB, count: 32))
        var encoded = try sb.encode()
        encoded[20] ^= 0x01
        XCTAssertThrowsError(try AGVTV2Superblock.decode(from: encoded))
    }

    func testSelectActivePrefersHigherEpoch() throws {
        let uuid = UUID()
        let hashA = Data(repeating: 0x11, count: 32)
        let hashB = Data(repeating: 0x22, count: 32)
        let a = try AGVTV2Superblock(profileID: 2,
                                     vaultUUID: uuid,
                                     epoch: 10,
                                     activeManifestOffset: 1024,
                                     activeManifestLength: 32,
                                     activeManifestHash: hashA)
        let b = try AGVTV2Superblock(profileID: 2,
                                     vaultUUID: uuid,
                                     epoch: 12,
                                     activeManifestOffset: 2048,
                                     activeManifestLength: 32,
                                     activeManifestHash: hashB)
        let selected = AGVTV2SuperblockSelector.selectActive(a, b)
        XCTAssertEqual(selected.epoch, 12)
        XCTAssertEqual(selected.activeManifestOffset, 2048)
    }

    func testLoadActiveFallsBackWhenOneSlotInvalid() throws {
        let uuid = UUID()
        let good = try AGVTV2Superblock(profileID: 2,
                                        vaultUUID: uuid,
                                        epoch: 3,
                                        activeManifestOffset: 777,
                                        activeManifestLength: 99,
                                        activeManifestHash: Data(repeating: 0x77, count: 32))

        let goodBytes = try good.encode()
        var badBytes = Data(goodBytes)
        badBytes[0] ^= 0xFF // break magic

        let combined = badBytes + goodBytes
        let active = try AGVTV2SuperblockSelector.loadActive(from: combined)
        XCTAssertEqual(active.epoch, 3)
        XCTAssertEqual(active.activeManifestOffset, 777)
    }

    func testRecordHeaderRoundTrip() throws {
        let header = AGVTV2RecordHeader(recordType: 0x0004,
                                        recordVersion: 1,
                                        recordFlags: 0x10,
                                        payloadLength: 9001,
                                        payloadCRC32: 0xAABBCCDD)
        let encoded = header.encode()
        XCTAssertEqual(encoded.count, AGVTV2.recordHeaderSize)
        let decoded = try AGVTV2RecordHeader.decode(from: encoded)
        XCTAssertEqual(decoded, header)
    }

    func testRecordHeaderRejectsTruncation() {
        let truncated = Data(repeating: 0, count: AGVTV2.recordHeaderSize - 1)
        XCTAssertThrowsError(try AGVTV2RecordHeader.decode(from: truncated))
    }
}
