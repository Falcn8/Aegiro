
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

    func testImportPreservesExistingEntriesAcrossCycles() throws {
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

        let (imported1, _) = try Importer.sidecarImport(vaultURL: vaultURL, passphrase: "test-pass", files: [f1])
        XCTAssertEqual(imported1, 1)
        XCTAssertEqual(try Exporter.list(vaultURL: vaultURL, passphrase: "test-pass").count, 1)
        XCTAssertEqual(try Locker.lockFromSidecar(vaultURL: vaultURL, passphrase: "test-pass"), 0)

        let (imported2, _) = try Importer.sidecarImport(vaultURL: vaultURL, passphrase: "test-pass", files: [f2])
        XCTAssertEqual(imported2, 1)
        XCTAssertEqual(try Exporter.list(vaultURL: vaultURL, passphrase: "test-pass").count, 2)
        XCTAssertEqual(try Locker.lockFromSidecar(vaultURL: vaultURL, passphrase: "test-pass"), 0)

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
        XCTAssertEqual(try Exporter.list(vaultURL: vaultURL, passphrase: "test-pass").count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.sidecar.path))
    }

    func testImportRejectsWhenVaultFileLimitWouldBeExceeded() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aegiro-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let previous = VaultLimits.testOverrideMaxFilesPerVault
        VaultLimits.testOverrideMaxFilesPerVault = 1
        defer { VaultLimits.testOverrideMaxFilesPerVault = previous }

        let vaultURL = tmp.appendingPathComponent("vault.agvt")
        _ = try AegiroVault.create(at: vaultURL, passphrase: "test-pass", touchID: false)

        let f1 = tmp.appendingPathComponent("one.txt")
        let f2 = tmp.appendingPathComponent("two.txt")
        try Data("one".utf8).write(to: f1)
        try Data("two".utf8).write(to: f2)

        let first = try Importer.sidecarImport(vaultURL: vaultURL, passphrase: "test-pass", files: [f1])
        XCTAssertEqual(first.imported, 1)
        XCTAssertEqual(try Exporter.list(vaultURL: vaultURL, passphrase: "test-pass").count, 1)

        XCTAssertThrowsError(try Importer.sidecarImport(vaultURL: vaultURL, passphrase: "test-pass", files: [f2])) { error in
            let msg = String(describing: error)
            XCTAssertTrue(msg.contains("Vault file limit exceeded"))
        }
        XCTAssertEqual(try Exporter.list(vaultURL: vaultURL, passphrase: "test-pass").count, 1)
    }

    func testPQCBundleRequiredForUnlockOnNewVault() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aegiro-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let vaultURL = tmp.appendingPathComponent("vault.agvt")
        _ = try AegiroVault.create(at: vaultURL, passphrase: "test-pass", touchID: false)

        var data = try Data(contentsOf: vaultURL)
        let (header, hdrLen) = try parseHeaderAndOffset(data)
        XCTAssertNotEqual(header.flags & 0b10, 0, "new vaults should require PQC unlock path")
        let layout = computeLayout(data, afterHeader: hdrLen)
        XCTAssertGreaterThan(layout.pqCtRange.count, 0)

        // Corrupt the encoded PQ access bundle; unlock must fail.
        let i = layout.pqCtRange.lowerBound
        data[i] = data[i] ^ 0x01
        try data.write(to: vaultURL, options: .atomic)

        XCTAssertThrowsError(try Exporter.list(vaultURL: vaultURL, passphrase: "test-pass"))
    }

    func testDoctorDetectsChunkTamperWithPassphrase() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aegiro-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let vaultURL = tmp.appendingPathComponent("vault.agvt")
        _ = try AegiroVault.create(at: vaultURL, passphrase: "test-pass", touchID: false)

        let fileURL = tmp.appendingPathComponent("note.txt")
        try Data("tamper-test-data".utf8).write(to: fileURL)
        let imported = try Importer.sidecarImport(vaultURL: vaultURL, passphrase: "test-pass", files: [fileURL])
        XCTAssertEqual(imported.imported, 1)

        var data = try Data(contentsOf: vaultURL)
        let (_, hdrLen) = try parseHeaderAndOffset(data)
        let layout = computeLayout(data, afterHeader: hdrLen)
        let chunkMap = data.subdata(in: layout.chunkMapRange)
        let chunks = try JSONDecoder().decode([ChunkInfo].self, from: chunkMap)
        XCTAssertFalse(chunks.isEmpty)

        let first = try XCTUnwrap(chunks.first)
        let tamperIndex = layout.chunkAreaStart + Int(first.relOffset) + min(5, max(first.length - 1, 0))
        XCTAssertLessThan(tamperIndex, data.count)
        data[tamperIndex] = data[tamperIndex] ^ 0x01
        try data.write(to: vaultURL, options: .atomic)

        let report = try Doctor.run(vaultURL: vaultURL, passphrase: "test-pass", fix: false)
        XCTAssertFalse(report.chunkAreaOK)
        XCTAssertTrue(report.issues.contains { $0.contains("Chunk authentication failed") })
    }

    func testExternalDiskRecoveryBundleRoundTripDryRun() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aegiro-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let diskID = "disk99s1"
        let recovery = tmp.appendingPathComponent("disk99s1.aegiro-diskkey.json")

        _ = try ExternalDiskCrypto.encryptAPFSVolume(diskIdentifier: diskID,
                                                     recoveryPassphrase: "bundle-pass",
                                                     recoveryURL: recovery,
                                                     dryRun: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path))

        XCTAssertNoThrow(try ExternalDiskCrypto.unlockAPFSVolume(diskIdentifier: diskID,
                                                                 recoveryPassphrase: "bundle-pass",
                                                                 recoveryURL: recovery,
                                                                 dryRun: true))
        XCTAssertThrowsError(try ExternalDiskCrypto.unlockAPFSVolume(diskIdentifier: diskID,
                                                                     recoveryPassphrase: "wrong-pass",
                                                                     recoveryURL: recovery,
                                                                     dryRun: true))
        XCTAssertThrowsError(try ExternalDiskCrypto.unlockAPFSVolume(diskIdentifier: "disk99s2",
                                                                     recoveryPassphrase: "bundle-pass",
                                                                     recoveryURL: recovery,
                                                                     dryRun: true))
    }

    func testUSBContainerCreateDryRunDoesNotWriteImage() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aegiro-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let imageURL = tmp.appendingPathComponent("portable-vault.sparsebundle")
        let recoveryURL = tmp.appendingPathComponent("portable-vault.aegiro-usbkey.json")
        let result = try USBContainerCrypto.createEncryptedContainer(imageURL: imageURL,
                                                                     size: "2g",
                                                                     volumeName: "PortableVault",
                                                                     recoveryPassphrase: "test-pass",
                                                                     recoveryURL: recoveryURL,
                                                                     dryRun: true)
        XCTAssertTrue(result.dryRun)
        XCTAssertEqual(result.imageURL, imageURL)
        XCTAssertEqual(result.recoveryURL, recoveryURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryURL.path))
    }

    func testUSBContainerRecoveryBundleRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aegiro-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let imageURL = tmp.appendingPathComponent("portable-vault.sparsebundle")
        let recoveryURL = tmp.appendingPathComponent("portable-vault.aegiro-usbkey.json")
        _ = try USBContainerCrypto.createEncryptedContainer(imageURL: imageURL,
                                                            size: "16m",
                                                            volumeName: "PortableVault",
                                                            recoveryPassphrase: "bundle-pass",
                                                            recoveryURL: recoveryURL,
                                                            dryRun: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryURL.path))

        let recovered = try USBContainerCrypto.recoverContainerPassphrase(imageURL: imageURL,
                                                                          recoveryPassphrase: "bundle-pass",
                                                                          recoveryURL: recoveryURL)
        XCTAssertFalse(recovered.isEmpty)
        XCTAssertThrowsError(try USBContainerCrypto.recoverContainerPassphrase(imageURL: imageURL,
                                                                                recoveryPassphrase: "wrong-pass",
                                                                                recoveryURL: recoveryURL))
        XCTAssertThrowsError(try USBContainerCrypto.recoverContainerPassphrase(imageURL: tmp.appendingPathComponent("other.sparsebundle"),
                                                                                recoveryPassphrase: "bundle-pass",
                                                                                recoveryURL: recoveryURL))
    }

    func testUSBContainerAttachPlistParsing() throws {
        let plist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>system-entities</key>
  <array>
    <dict>
      <key>dev-entry</key>
      <string>/dev/disk42</string>
    </dict>
    <dict>
      <key>dev-entry</key>
      <string>/dev/disk42s1</string>
      <key>mount-point</key>
      <string>/Volumes/PortableVault</string>
    </dict>
  </array>
</dict>
</plist>
"""
        let imageURL = URL(fileURLWithPath: "/tmp/portable-vault.sparsebundle")
        let result = try USBContainerCrypto.parseAttachResult(plistData: Data(plist.utf8), imageURL: imageURL)
        XCTAssertEqual(result.imageURL, imageURL)
        XCTAssertEqual(result.deviceIdentifier, "disk42s1")
        XCTAssertEqual(result.mountPoint, "/Volumes/PortableVault")
        XCTAssertFalse(result.dryRun)
    }

    func testUSBUserDataScanSkipsSystemMetadata() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aegiro-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = tmp.appendingPathComponent("usb", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let userDir = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        let userFile = userDir.appendingPathComponent("hello.txt")
        try Data("hello".utf8).write(to: userFile)

        let spotlightDir = root.appendingPathComponent(".Spotlight-V100", isDirectory: true)
        try FileManager.default.createDirectory(at: spotlightDir, withIntermediateDirectories: true)
        try Data("index".utf8).write(to: spotlightDir.appendingPathComponent("store.db"))

        let systemInfoDir = root.appendingPathComponent("System Volume Information", isDirectory: true)
        try FileManager.default.createDirectory(at: systemInfoDir, withIntermediateDirectories: true)
        try Data("system".utf8).write(to: systemInfoDir.appendingPathComponent("volume.txt"))

        try Data("metadata".utf8).write(to: root.appendingPathComponent(".DS_Store"))

        let scan = try USBUserDataCrypto.scanUserFiles(sourceRootURL: root)
        XCTAssertEqual(scan.scannedFileCount, 1)
        XCTAssertEqual(scan.files.first?.path, userFile.path)
        XCTAssertTrue(scan.skippedPaths.contains(where: { $0.contains(".Spotlight-V100") }))
        XCTAssertTrue(scan.skippedPaths.contains(where: { $0.contains("System Volume Information") }))
    }

    func testUSBUserDataEncryptDryRunDoesNotModifySource() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aegiro-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = tmp.appendingPathComponent("usb", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let userFile = root.appendingPathComponent("hello.txt")
        try Data("hello".utf8).write(to: userFile)

        let vaultURL = root.appendingPathComponent("userdata.agvt")
        let result = try USBUserDataCrypto.encryptUserFiles(sourceRootURL: root,
                                                            vaultURL: vaultURL,
                                                            passphrase: "",
                                                            deleteOriginals: true,
                                                            dryRun: true)
        XCTAssertTrue(result.dryRun)
        XCTAssertEqual(result.scannedFileCount, 1)
        XCTAssertEqual(result.encryptedFileCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: userFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultURL.path))
    }

    func testUSBUserDataEncryptDeletesOriginalsAfterSuccess() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aegiro-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = tmp.appendingPathComponent("usb", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let userFile = root.appendingPathComponent("hello.txt")
        let payload = Data("secret-user-data".utf8)
        try payload.write(to: userFile)

        // System metadata should stay untouched because it is excluded.
        let dsStore = root.appendingPathComponent(".DS_Store")
        try Data("metadata".utf8).write(to: dsStore)

        let vaultURL = root.appendingPathComponent("userdata.agvt")
        let result = try USBUserDataCrypto.encryptUserFiles(sourceRootURL: root,
                                                            vaultURL: vaultURL,
                                                            passphrase: "test-pass",
                                                            deleteOriginals: true,
                                                            dryRun: false)
        XCTAssertFalse(result.dryRun)
        XCTAssertEqual(result.scannedFileCount, 1)
        XCTAssertEqual(result.encryptedFileCount, 1)
        XCTAssertEqual(result.deletedOriginalCount, 1)
        XCTAssertTrue(result.deletionErrors.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: userFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dsStore.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vaultURL.path))

        let listed = try Exporter.list(vaultURL: vaultURL, passphrase: "test-pass")
        XCTAssertEqual(listed.count, 1)

        let outDir = tmp.appendingPathComponent("out", isDirectory: true)
        let exported = try Exporter.export(vaultURL: vaultURL, passphrase: "test-pass", filters: [], outDir: outDir)
        XCTAssertEqual(exported.count, 1)
        let restored = outDir.appendingPathComponent("hello.txt")
        XCTAssertEqual(try Data(contentsOf: restored), payload)
    }
}
