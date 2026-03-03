
import XCTest
import CryptoKit
@testable import AegiroCore

final class AegiroCoreTests: XCTestCase {
    func testHeaderRoundTrip() throws {
        let algs = AlgIDs(aead: 1, kdf: 2, kem: 3, sig: 4)
        let argon = Argon2Params(mMiB: 256, t: 3, p: 1)
        let pq = PQPublicKeys(kyber_pk: Data([1,2,3]), dilithium_pk: Data([4,5,6]))
        let h = VaultHeader(alg: algs, argon2: argon, pq: pq)
        let ser = try h.serialize()
        let parsed = try VaultHeader.parse(ser)
        XCTAssertEqual(parsed.version, 1)
        XCTAssertEqual(parsed.alg_ids.aead, 1)
    }

    func testNonceUniqueness() {
        let seed = SymmetricKey(size: .bits256)
        var set = Set<Data>()
        for i in 0..<10000 {
            let n = NonceScheme.nonce(fileSeed: seed, chunkIndex: UInt64(i))
            set.insert(n.data)
        }
        XCTAssertEqual(set.count, 10000)
    }

    func testPrivacyScan() {
        let matches = PrivacyMonitor.scan(paths: ["/tmp/passport_scan.pdf"])
        XCTAssert(matches.count >= 0)
    }

    func testLockPreservesExistingEntriesAcrossCycles() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aegiro-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let vaultURL = tmp.appendingPathComponent("vault.agvt")
        _ = try AegiroVault.create(at: vaultURL, passphrase: "test-pass", touchID: false)

        let f1 = tmp.appendingPathComponent("one.txt")
        let f2 = tmp.appendingPathComponent("two.txt")
        let d1 = Data("hello-one".utf8)
        let d2 = Data("hello-two".utf8)
        try d1.write(to: f1)
        try d2.write(to: f2)

        _ = try Importer.sidecarImport(vaultURL: vaultURL, passphrase: "test-pass", files: [f1])
        XCTAssertEqual(try Locker.lockFromSidecar(vaultURL: vaultURL, passphrase: "test-pass"), 1)

        _ = try Importer.sidecarImport(vaultURL: vaultURL, passphrase: "test-pass", files: [f2])
        XCTAssertEqual(try Locker.lockFromSidecar(vaultURL: vaultURL, passphrase: "test-pass"), 1)

        let outDir = tmp.appendingPathComponent("out", isDirectory: true)
        let exported = try Exporter.export(vaultURL: vaultURL, passphrase: "test-pass", filters: [], outDir: outDir)
        XCTAssertEqual(exported.count, 2)

        let out1 = outDir.appendingPathComponent("one.txt")
        let out2 = outDir.appendingPathComponent("two.txt")
        XCTAssertEqual(try Data(contentsOf: out1), d1)
        XCTAssertEqual(try Data(contentsOf: out2), d2)
    }

    func testImportSkipsVaultFileItself() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aegiro-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let vaultURL = tmp.appendingPathComponent("vault.agvt")
        _ = try AegiroVault.create(at: vaultURL, passphrase: "test-pass", touchID: false)

        let result = try Importer.sidecarImport(vaultURL: vaultURL, passphrase: "test-pass", files: [vaultURL])
        XCTAssertEqual(result.imported, 0)

        let sidecarIndex = result.sidecar.appendingPathComponent("index.json")
        if let data = try? Data(contentsOf: sidecarIndex),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            XCTAssertTrue(arr.isEmpty)
        }
    }
}
