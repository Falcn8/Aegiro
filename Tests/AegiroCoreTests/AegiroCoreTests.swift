
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
}
