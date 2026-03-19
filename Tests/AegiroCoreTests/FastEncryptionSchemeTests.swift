import XCTest
import CryptoKit
@testable import AegiroCore

final class FastEncryptionSchemeTests: XCTestCase {
    func testRoundTripAESGCM() throws {
        let key = try FastEncryptionScheme.generateMasterKey()
        let plain = sampleData(count: 2 * 1024 * 1024 + 137)
        let encrypted = try FastEncryptionScheme.encrypt(plaintext: plain,
                                                         masterKey: key,
                                                         chunkSize: 64 * 1024,
                                                         algorithm: .aesGCM256)
        let decrypted = try FastEncryptionScheme.decrypt(ciphertext: encrypted, masterKey: key)
        XCTAssertEqual(decrypted, plain)
    }

    func testRoundTripChaChaPoly() throws {
        let key = try FastEncryptionScheme.generateMasterKey()
        let plain = sampleData(count: 512 * 1024 + 11)
        let encrypted = try FastEncryptionScheme.encrypt(plaintext: plain,
                                                         masterKey: key,
                                                         chunkSize: 32 * 1024,
                                                         algorithm: .chaChaPoly1305)
        let decrypted = try FastEncryptionScheme.decrypt(ciphertext: encrypted, masterKey: key)
        XCTAssertEqual(decrypted, plain)
    }

    func testTamperDetected() throws {
        let key = try FastEncryptionScheme.generateMasterKey()
        let plain = Data("high-throughput tamper test".utf8)
        var encrypted = try FastEncryptionScheme.encrypt(plaintext: plain,
                                                         masterKey: key,
                                                         chunkSize: 4096,
                                                         algorithm: .aesGCM256)
        encrypted[FastEncryptionScheme.headerSize + 3] ^= 0x80

        XCTAssertThrowsError(try FastEncryptionScheme.decrypt(ciphertext: encrypted, masterKey: key))
    }

    func testEmptyPayloadRoundTrip() throws {
        let key = try FastEncryptionScheme.generateMasterKey()
        let encrypted = try FastEncryptionScheme.encrypt(plaintext: Data(), masterKey: key)
        let decrypted = try FastEncryptionScheme.decrypt(ciphertext: encrypted, masterKey: key)
        XCTAssertTrue(decrypted.isEmpty)
        XCTAssertEqual(encrypted.count, FastEncryptionScheme.headerSize)
    }

    private func sampleData(count: Int) -> Data {
        let pattern = Data((0..<251).map { UInt8($0) })
        var out = Data()
        out.reserveCapacity(count)
        while out.count < count {
            let remaining = count - out.count
            out.append(pattern.prefix(remaining))
        }
        return out
    }
}
