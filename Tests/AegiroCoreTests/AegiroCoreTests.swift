
import XCTest
import CryptoKit
@testable import AegiroCore

final class AegiroCoreTests: XCTestCase {
    private func expectedImportedLogicalPath(for fileURL: URL) -> String {
        let normalized = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        let parent = normalized.deletingLastPathComponent().lastPathComponent
        if parent.isEmpty {
            return normalized.lastPathComponent
        }
        return "\(parent)/\(normalized.lastPathComponent)"
    }

    private func expectedImportedLogicalPath(for fileURL: URL, rootURL: URL) -> String {
        let normalizedRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let normalizedFile = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = normalizedRoot.path.hasSuffix("/") ? normalizedRoot.path : normalizedRoot.path + "/"
        let relativePath: String
        if normalizedFile.path == normalizedRoot.path {
            relativePath = normalizedFile.lastPathComponent
        } else if normalizedFile.path.hasPrefix(rootPrefix) {
            relativePath = String(normalizedFile.path.dropFirst(rootPrefix.count))
        } else {
            relativePath = normalizedFile.lastPathComponent
        }
        return "\(normalizedRoot.lastPathComponent)/\(relativePath)"
    }

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

    func testSupportsLegacyChunkAEADIDAndMixedChunkDomains() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aegiro-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let vaultURL = tmp.appendingPathComponent("vault.agvt")
        _ = try AegiroVault.create(at: vaultURL, passphrase: "test-pass", touchID: false)

        let f1 = tmp.appendingPathComponent("one.txt")
        let f2 = tmp.appendingPathComponent("two.txt")
        let d1 = Data("legacy-domain-file".utf8)
        let d2 = Data("current-domain-file".utf8)
        try d1.write(to: f1)
        try d2.write(to: f2)
        let logicalF1 = expectedImportedLogicalPath(for: f1)
        let logicalF2 = expectedImportedLogicalPath(for: f2)

        let firstImport = try Importer.sidecarImport(vaultURL: vaultURL, passphrase: "test-pass", files: [f1])
        XCTAssertEqual(firstImport.imported, 1)

        var data = try Data(contentsOf: vaultURL)
        let (header, hdrLen) = try parseHeaderAndOffset(data)
        let layout = computeLayout(data, afterHeader: hdrLen)
        let dek = try Exporter.deriveDEK(data: data, passphrase: "test-pass")
        let index = try IndexCrypto.decryptIndex(data.subdata(in: layout.idxRange), key: dek, aad: Data("AEGIRO-V1".utf8))
        let entry = try XCTUnwrap(index.entries.first(where: { $0.logicalPath == logicalF1 }))
        let chunkMap = try JSONDecoder().decode([ChunkInfo].self, from: data.subdata(in: layout.chunkMapRange))
        let entryChunks = chunkMap
            .filter { $0.fileID == entry.fileID }
            .sorted { $0.ordinal < $1.ordinal }
        XCTAssertFalse(entryChunks.isEmpty)

        let keyInfoV1 = Data("AEGIRO-FILE-KEY-V1".utf8)
        let keyInfoLegacyV2 = Data("AEGIRO-FILE-KEY-V2".utf8)
        let chunkAADV1 = Data("AEGIRO-CHUNK-V1".utf8)
        let chunkAADLegacyV2 = Data("AEGIRO-CHUNK-V2".utf8)
        let tagLength = 16

        func deriveChunkFileKey(infoPrefix: Data) -> SymmetricKey {
            let info = infoPrefix + entry.fileID + Data([entry.chunkCrypto.algorithm, entry.chunkCrypto.format])
            return HKDF<SHA256>.deriveKey(inputKeyMaterial: dek,
                                          salt: entry.chunkCrypto.keySalt,
                                          info: info,
                                          outputByteCount: 32)
        }

        func makeNonceData(ordinal: UInt32) -> Data {
            var out = Data()
            out.reserveCapacity(12)
            out.append(entry.chunkCrypto.noncePrefix)
            var ctr = UInt64(ordinal).littleEndian
            withUnsafeBytes(of: &ctr) { out.append(contentsOf: $0) }
            return out
        }

        func makeChunkAAD(prefix: Data, ordinal: UInt32) -> Data {
            var out = Data()
            out.reserveCapacity(prefix.count + header.kdf_salt.count + entry.fileID.count + 8)
            out.append(prefix)
            out.append(header.kdf_salt)
            out.append(entry.fileID)
            out.append(Data([entry.chunkCrypto.algorithm, entry.chunkCrypto.format]))
            var ordinalLE = ordinal.littleEndian
            withUnsafeBytes(of: &ordinalLE) { out.append(contentsOf: $0) }
            return out
        }

        func openChunkPayload(_ payload: Data, key: SymmetricKey, nonceData: Data, aad: Data, algorithm: UInt8) throws -> Data {
            let ct = payload.prefix(payload.count - tagLength)
            let tag = payload.suffix(tagLength)
            switch algorithm {
            case 1:
                let nonce = try AES.GCM.Nonce(data: nonceData)
                let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
                return try AES.GCM.open(box, using: key, authenticating: aad)
            case 2:
                let nonce = try ChaChaPoly.Nonce(data: nonceData)
                let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
                return try ChaChaPoly.open(box, using: key, authenticating: aad)
            default:
                XCTFail("Unsupported chunk algorithm in test: \(algorithm)")
                return Data()
            }
        }

        func sealChunkPayload(_ plaintext: Data, key: SymmetricKey, nonceData: Data, aad: Data, algorithm: UInt8) throws -> Data {
            switch algorithm {
            case 1:
                let nonce = try AES.GCM.Nonce(data: nonceData)
                let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
                return sealed.ciphertext + sealed.tag
            case 2:
                let nonce = try ChaChaPoly.Nonce(data: nonceData)
                let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
                return sealed.ciphertext + sealed.tag
            default:
                XCTFail("Unsupported chunk algorithm in test: \(algorithm)")
                return Data()
            }
        }

        let v1FileKey = deriveChunkFileKey(infoPrefix: keyInfoV1)
        let legacyFileKey = deriveChunkFileKey(infoPrefix: keyInfoLegacyV2)
        for chunk in entryChunks {
            let start = layout.chunkAreaStart + Int(chunk.relOffset)
            let end = start + chunk.length
            XCTAssertLessThanOrEqual(end, data.count)
            let payload = data.subdata(in: start..<end)
            let nonceData = makeNonceData(ordinal: chunk.ordinal)
            let plain = try openChunkPayload(payload,
                                             key: v1FileKey,
                                             nonceData: nonceData,
                                             aad: makeChunkAAD(prefix: chunkAADV1, ordinal: chunk.ordinal),
                                             algorithm: entry.chunkCrypto.algorithm)
            let legacyPayload = try sealChunkPayload(plain,
                                                     key: legacyFileKey,
                                                     nonceData: nonceData,
                                                     aad: makeChunkAAD(prefix: chunkAADLegacyV2, ordinal: chunk.ordinal),
                                                     algorithm: entry.chunkCrypto.algorithm)
            XCTAssertEqual(legacyPayload.count, payload.count)
            data.replaceSubrange(start..<end, with: legacyPayload)
        }

        var modified = header
        modified.alg_ids.aead = 2
        let modifiedHeader = try modified.serialize()
        XCTAssertEqual(modifiedHeader.count, hdrLen, "AEAD id mutation must preserve header length for in-place rewrite")

        data.replaceSubrange(0..<hdrLen, with: modifiedHeader)
        try data.write(to: vaultURL, options: .atomic)

        let secondImport = try Importer.sidecarImport(vaultURL: vaultURL, passphrase: "test-pass", files: [f2])
        XCTAssertEqual(secondImport.imported, 1)

        let outDir = tmp.appendingPathComponent("out", isDirectory: true)
        let exported = try Exporter.export(vaultURL: vaultURL, passphrase: "test-pass", filters: [], outDir: outDir)
        XCTAssertEqual(exported.count, 2)

        let exportedByLogicalPath = Dictionary(uniqueKeysWithValues: exported.map { ($0.0, $0.1) })
        let out1 = try XCTUnwrap(exportedByLogicalPath[logicalF1])
        let out2 = try XCTUnwrap(exportedByLogicalPath[logicalF2])
        XCTAssertEqual(try Data(contentsOf: out1), d1)
        XCTAssertEqual(try Data(contentsOf: out2), d2)
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

    func testPrivacyScanDetectsNameAndContentPatterns() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aegiro-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let passportNamedFile = tmp.appendingPathComponent("passport_photo.jpg")
        let contentFile = tmp.appendingPathComponent("notes.txt")

        try Data("image".utf8).write(to: passportNamedFile)
        try Data("Contact: jane@example.com SSN: 123-45-6789".utf8).write(to: contentFile)

        let matches = PrivacyMonitor.scan(paths: [tmp.path])
        let reasons = Set(matches.map {
            "\(URL(fileURLWithPath: $0.path).standardizedFileURL.path)|\($0.reason)"
        })
        let expectedPassportPath = passportNamedFile.standardizedFileURL.path
        let expectedContentPath = contentFile.standardizedFileURL.path

        XCTAssertTrue(reasons.contains("\(expectedPassportPath)|name:passport"))
        XCTAssertTrue(reasons.contains("\(expectedContentPath)|content:ssn-pattern"))
        XCTAssertTrue(reasons.contains("\(expectedContentPath)|content:email-pattern"))
    }

    func testPrivacyScanNamesOnlySkipsContentChecks() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aegiro-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let contentFile = tmp.appendingPathComponent("report.txt")
        try Data("Card: 4111 1111 1111 1111".utf8).write(to: contentFile)

        let options = PrivacyScanOptions(includeFileContents: false)
        let matches = PrivacyMonitor.scan(paths: [contentFile.path], options: options)
        XCTAssertTrue(matches.isEmpty)
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
        let logicalF1 = expectedImportedLogicalPath(for: f1)
        let logicalF2 = expectedImportedLogicalPath(for: f2)

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

        let exportedByLogicalPath = Dictionary(uniqueKeysWithValues: exported.map { ($0.0, $0.1) })
        let out1 = try XCTUnwrap(exportedByLogicalPath[logicalF1])
        let out2 = try XCTUnwrap(exportedByLogicalPath[logicalF2])
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

    func testImportDirectoryBatchesFilesInSingleRun() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aegiro-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sourceRoot = tmp.appendingPathComponent("batch", isDirectory: true)
        let nested = sourceRoot.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let f1 = sourceRoot.appendingPathComponent("one.txt")
        let f2 = nested.appendingPathComponent("two.txt")
        let f3 = nested.appendingPathComponent("three.bin")
        let d1 = Data("one".utf8)
        let d2 = Data("two".utf8)
        let d3 = Data([0x00, 0x01, 0x02, 0x03])
        try d1.write(to: f1)
        try d2.write(to: f2)
        try d3.write(to: f3)
        let logicalF1 = expectedImportedLogicalPath(for: f1, rootURL: sourceRoot)
        let logicalF2 = expectedImportedLogicalPath(for: f2, rootURL: sourceRoot)
        let logicalF3 = expectedImportedLogicalPath(for: f3, rootURL: sourceRoot)

        let vaultURL = tmp.appendingPathComponent("vault.agvt")
        _ = try AegiroVault.create(at: vaultURL, passphrase: "test-pass", touchID: false)

        let imported = try Importer.sidecarImport(vaultURL: vaultURL,
                                                  passphrase: "test-pass",
                                                  files: [sourceRoot])
        XCTAssertEqual(imported.imported, 3)

        let entries = try Exporter.list(vaultURL: vaultURL, passphrase: "test-pass")
        XCTAssertEqual(entries.count, 3)

        let outDir = tmp.appendingPathComponent("out", isDirectory: true)
        let exported = try Exporter.export(vaultURL: vaultURL, passphrase: "test-pass", filters: [], outDir: outDir)
        let exportedByLogicalPath = Dictionary(uniqueKeysWithValues: exported.map { ($0.0, $0.1) })

        let out1 = try XCTUnwrap(exportedByLogicalPath[logicalF1])
        let out2 = try XCTUnwrap(exportedByLogicalPath[logicalF2])
        let out3 = try XCTUnwrap(exportedByLogicalPath[logicalF3])
        XCTAssertEqual(try Data(contentsOf: out1), d1)
        XCTAssertEqual(try Data(contentsOf: out2), d2)
        XCTAssertEqual(try Data(contentsOf: out3), d3)
    }

    func testImportTargetsDestinationDirectoryPath() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aegiro-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dirA = tmp.appendingPathComponent("alpha", isDirectory: true)
        let dirB = tmp.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)

        let f1 = dirA.appendingPathComponent("one.txt")
        let f2 = dirB.appendingPathComponent("two.txt")
        let d1 = Data("alpha-file".utf8)
        let d2 = Data("beta-file".utf8)
        try d1.write(to: f1)
        try d2.write(to: f2)

        let destinationDirectory = "Projects/Current"
        let expectedF1 = "\(destinationDirectory)/\(expectedImportedLogicalPath(for: f1))"
        let expectedF2 = "\(destinationDirectory)/\(expectedImportedLogicalPath(for: f2))"

        let vaultURL = tmp.appendingPathComponent("vault.agvt")
        _ = try AegiroVault.create(at: vaultURL, passphrase: "test-pass", touchID: false)

        let imported = try Importer.sidecarImport(vaultURL: vaultURL,
                                                  passphrase: "test-pass",
                                                  files: [f1, f2],
                                                  destinationDirectoryPath: destinationDirectory)
        XCTAssertEqual(imported.imported, 2)

        let entries = try Exporter.list(vaultURL: vaultURL, passphrase: "test-pass")
        let logicalPaths = Set(entries.map(\.logicalPath))
        XCTAssertEqual(logicalPaths, Set([expectedF1, expectedF2]))
        XCTAssertTrue(logicalPaths.allSatisfy { $0.hasPrefix(destinationDirectory + "/") })

        let outDir = tmp.appendingPathComponent("out", isDirectory: true)
        let exported = try Exporter.export(vaultURL: vaultURL, passphrase: "test-pass", filters: [], outDir: outDir)
        let exportedByLogicalPath = Dictionary(uniqueKeysWithValues: exported.map { ($0.0, $0.1) })
        let out1 = try XCTUnwrap(exportedByLogicalPath[expectedF1])
        let out2 = try XCTUnwrap(exportedByLogicalPath[expectedF2])
        XCTAssertEqual(try Data(contentsOf: out1), d1)
        XCTAssertEqual(try Data(contentsOf: out2), d2)
    }

    func testCreateDirectoryPersistsAsMarkerAndExportSkipsMarker() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aegiro-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let vaultURL = tmp.appendingPathComponent("vault.agvt")
        _ = try AegiroVault.create(at: vaultURL, passphrase: "test-pass", touchID: false)

        let directoryPath = "Projects/2026"
        let created = try Editor.createDirectory(vaultURL: vaultURL, passphrase: "test-pass", logicalPath: directoryPath)
        XCTAssertTrue(created)
        XCTAssertFalse(try Editor.createDirectory(vaultURL: vaultURL, passphrase: "test-pass", logicalPath: directoryPath))

        let markerLogicalPath = "\(directoryPath)/\(vaultDirectoryMarkerFileName)"
        let entriesAfterCreate = try Exporter.list(vaultURL: vaultURL, passphrase: "test-pass")
        XCTAssertEqual(entriesAfterCreate.count, 1)
        XCTAssertEqual(entriesAfterCreate.first?.logicalPath, markerLogicalPath)
        XCTAssertEqual(entriesAfterCreate.first?.mime, vaultDirectoryMarkerMIME)

        let outDir1 = tmp.appendingPathComponent("out-empty", isDirectory: true)
        let exportedBeforeFiles = try Exporter.export(vaultURL: vaultURL, passphrase: "test-pass", filters: [], outDir: outDir1)
        XCTAssertTrue(exportedBeforeFiles.isEmpty)

        let fileURL = tmp.appendingPathComponent("note.txt")
        let fileData = Data("hello-folder".utf8)
        try fileData.write(to: fileURL)
        let imported = try Importer.sidecarImport(vaultURL: vaultURL,
                                                  passphrase: "test-pass",
                                                  files: [fileURL],
                                                  destinationDirectoryPath: directoryPath)
        XCTAssertEqual(imported.imported, 1)

        let entries = try Exporter.list(vaultURL: vaultURL, passphrase: "test-pass")
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.contains { $0.logicalPath == markerLogicalPath })
        XCTAssertTrue(entries.contains { $0.logicalPath == "\(directoryPath)/note.txt" })

        let outDir2 = tmp.appendingPathComponent("out-with-file", isDirectory: true)
        let exported = try Exporter.export(vaultURL: vaultURL, passphrase: "test-pass", filters: [], outDir: outDir2)
        XCTAssertEqual(exported.count, 1)
        XCTAssertEqual(exported.first?.0, "\(directoryPath)/note.txt")
        let outFile = try XCTUnwrap(exported.first?.1)
        XCTAssertEqual(try Data(contentsOf: outFile), fileData)
    }

    func testImportSameFilenameFromDifferentDirectoriesUsesDistinctRelativePaths() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aegiro-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dirA = tmp.appendingPathComponent("alpha", isDirectory: true)
        let dirB = tmp.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)

        let f1 = dirA.appendingPathComponent("same.txt")
        let f2 = dirB.appendingPathComponent("same.txt")
        let d1 = Data("from-alpha".utf8)
        let d2 = Data("from-beta".utf8)
        try d1.write(to: f1)
        try d2.write(to: f2)
        let logicalF1 = expectedImportedLogicalPath(for: f1)
        let logicalF2 = expectedImportedLogicalPath(for: f2)

        let vaultURL = tmp.appendingPathComponent("vault.agvt")
        _ = try AegiroVault.create(at: vaultURL, passphrase: "test-pass", touchID: false)

        let imported = try Importer.sidecarImport(vaultURL: vaultURL, passphrase: "test-pass", files: [f1, f2])
        XCTAssertEqual(imported.imported, 2)

        let entries = try Exporter.list(vaultURL: vaultURL, passphrase: "test-pass")
        let logicalPaths = Set(entries.map(\.logicalPath))
        XCTAssertEqual(logicalPaths, Set([logicalF1, logicalF2]))
        XCTAssertTrue(logicalPaths.allSatisfy { !$0.hasPrefix("/") })

        let outDir = tmp.appendingPathComponent("out", isDirectory: true)
        let exported = try Exporter.export(vaultURL: vaultURL, passphrase: "test-pass", filters: [], outDir: outDir)
        let exportedByLogicalPath = Dictionary(uniqueKeysWithValues: exported.map { ($0.0, $0.1) })
        let out1 = try XCTUnwrap(exportedByLogicalPath[logicalF1])
        let out2 = try XCTUnwrap(exportedByLogicalPath[logicalF2])
        XCTAssertEqual(try Data(contentsOf: out1), d1)
        XCTAssertEqual(try Data(contentsOf: out2), d2)
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

    func testDeleteEntriesRemovesOnlyTargets() throws {
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
        let logicalF1 = expectedImportedLogicalPath(for: f1)
        let logicalF2 = expectedImportedLogicalPath(for: f2)

        let imported = try Importer.sidecarImport(vaultURL: vaultURL, passphrase: "test-pass", files: [f1, f2])
        XCTAssertEqual(imported.imported, 2)
        XCTAssertEqual(try Exporter.list(vaultURL: vaultURL, passphrase: "test-pass").count, 2)

        let removed = try Editor.deleteEntries(vaultURL: vaultURL,
                                               passphrase: "test-pass",
                                               logicalPaths: [logicalF1])
        XCTAssertEqual(removed, 1)

        let entries = try Exporter.list(vaultURL: vaultURL, passphrase: "test-pass")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.logicalPath, logicalF2)

        let outDir = tmp.appendingPathComponent("out", isDirectory: true)
        let exported = try Exporter.export(vaultURL: vaultURL, passphrase: "test-pass", filters: [], outDir: outDir)
        XCTAssertEqual(exported.count, 1)
        let exportedByLogicalPath = Dictionary(uniqueKeysWithValues: exported.map { ($0.0, $0.1) })
        XCTAssertNil(exportedByLogicalPath[logicalF1])
        let out2 = try XCTUnwrap(exportedByLogicalPath[logicalF2])
        XCTAssertEqual(try Data(contentsOf: out2), d2)
    }

    func testBackupExportCreatesSingleArchiveWithMetadata() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aegiro-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let vaultURL = tmp.appendingPathComponent("vault.agvt")
        _ = try AegiroVault.create(at: vaultURL, passphrase: "test-pass", touchID: false)

        let f1 = tmp.appendingPathComponent("one.txt")
        try Data("hello-one".utf8).write(to: f1)
        let imported = try Importer.sidecarImport(vaultURL: vaultURL, passphrase: "test-pass", files: [f1])
        XCTAssertEqual(imported.imported, 1)

        let vault = try AegiroVault.open(at: vaultURL)
        let backupURL = tmp.appendingPathComponent("vault.aegirobackup")
        try Backup.exportBackup(from: vault, to: backupURL, passphrase: "test-pass")

        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        let info = try Backup.inspectBackup(at: backupURL)
        XCTAssertEqual(info.metadata.formatVersion, 1)
        XCTAssertEqual(info.metadata.sourceVaultFileName, "vault.agvt")
        XCTAssertEqual(info.payloadSizeBytes, info.metadata.sourceVaultSizeBytes)
        XCTAssertTrue(info.metadata.passphraseValidated)
        XCTAssertEqual(info.metadata.decryptedEntryCount, 1)
        XCTAssertGreaterThanOrEqual(info.archiveSizeBytes, info.payloadSizeBytes)

        let sourceData = try Data(contentsOf: vaultURL)
        XCTAssertEqual(info.metadata.sourceVaultSizeBytes, UInt64(sourceData.count))
        let expectedHash = Data(SHA256.hash(data: sourceData)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(info.metadata.sourceVaultSHA256Hex, expectedHash)
    }

    func testBackupExportWithoutPassphraseSkipsEntryValidation() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aegiro-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let vaultURL = tmp.appendingPathComponent("vault.agvt")
        _ = try AegiroVault.create(at: vaultURL, passphrase: "test-pass", touchID: false)

        let vault = try AegiroVault.open(at: vaultURL)
        let backupURL = tmp.appendingPathComponent("vault.aegirobackup")
        try Backup.exportBackup(from: vault, to: backupURL, passphrase: "")

        let info = try Backup.inspectBackup(at: backupURL)
        XCTAssertFalse(info.metadata.passphraseValidated)
        XCTAssertNil(info.metadata.decryptedEntryCount)
    }

    func testBackupRestoreRoundTripRecreatesVaultBytes() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aegiro-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let vaultURL = tmp.appendingPathComponent("source.agvt")
        _ = try AegiroVault.create(at: vaultURL, passphrase: "test-pass", touchID: false)

        let fileURL = tmp.appendingPathComponent("one.txt")
        try Data("hello-restore".utf8).write(to: fileURL)
        let imported = try Importer.sidecarImport(vaultURL: vaultURL, passphrase: "test-pass", files: [fileURL])
        XCTAssertEqual(imported.imported, 1)

        let backupURL = tmp.appendingPathComponent("source.aegirobackup")
        let vault = try AegiroVault.open(at: vaultURL)
        try Backup.exportBackup(from: vault, to: backupURL, passphrase: "test-pass")

        let restoredURL = tmp.appendingPathComponent("restored.agvt")
        let info = try Backup.restoreBackup(from: backupURL, to: restoredURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredURL.path))
        XCTAssertEqual(info.metadata.sourceVaultFileName, "source.agvt")
        XCTAssertEqual(try Data(contentsOf: restoredURL), try Data(contentsOf: vaultURL))
    }

    func testBackupRestoreRejectsOverwriteWithoutFlag() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aegiro-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let vaultURL = tmp.appendingPathComponent("source.agvt")
        _ = try AegiroVault.create(at: vaultURL, passphrase: "test-pass", touchID: false)
        let backupURL = tmp.appendingPathComponent("source.aegirobackup")
        let vault = try AegiroVault.open(at: vaultURL)
        try Backup.exportBackup(from: vault, to: backupURL, passphrase: "test-pass")

        let restoredURL = tmp.appendingPathComponent("restored.agvt")
        try Data("placeholder".utf8).write(to: restoredURL)

        XCTAssertThrowsError(try Backup.restoreBackup(from: backupURL, to: restoredURL, overwrite: false))
        XCTAssertNoThrow(try Backup.restoreBackup(from: backupURL, to: restoredURL, overwrite: true))
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

    func testDoctorFixRepairsManifestIndexHashMismatch() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aegiro-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let vaultURL = tmp.appendingPathComponent("vault.agvt")
        _ = try AegiroVault.create(at: vaultURL, passphrase: "test-pass", touchID: false)

        let fileURL = tmp.appendingPathComponent("note.txt")
        try Data("manifest-index-fix".utf8).write(to: fileURL)
        let imported = try Importer.sidecarImport(vaultURL: vaultURL, passphrase: "test-pass", files: [fileURL])
        XCTAssertEqual(imported.imported, 1)

        var data = try Data(contentsOf: vaultURL)
        let (_, hdrLen) = try parseHeaderAndOffset(data)
        let layout = computeLayout(data, afterHeader: hdrLen)

        var manifest = try JSONDecoder().decode(Manifest.self, from: data.subdata(in: layout.manRange))
        XCTAssertFalse(manifest.indexRootHash.isEmpty)
        manifest.indexRootHash[0] = manifest.indexRootHash[0] ^ 0x01
        let badManifestBlob = try JSONEncoder().encode(manifest)

        let newLenLE = withUnsafeBytes(of: UInt32(badManifestBlob.count).littleEndian) { Data($0) }
        data.replaceSubrange(layout.manLenPos..<(layout.manLenPos + 4), with: newLenLE)
        data.replaceSubrange(layout.manRange, with: badManifestBlob)
        try data.write(to: vaultURL, options: .atomic)

        let pre = try Doctor.run(vaultURL: vaultURL, passphrase: "test-pass", fix: false)
        XCTAssertTrue(pre.issues.contains { $0.contains("Manifest index hash does not match decrypted index.") })
        XCTAssertFalse(pre.manifestOK)

        let post = try Doctor.run(vaultURL: vaultURL, passphrase: "test-pass", fix: true)
        XCTAssertTrue(post.fixed)
        XCTAssertTrue(post.manifestOK)
        XCTAssertFalse(post.issues.contains { $0.contains("Manifest index hash does not match decrypted index.") })
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
        try Data("vault".utf8).write(to: userDir.appendingPathComponent("old.agvt"))
        try Data("backup".utf8).write(to: userDir.appendingPathComponent("old.aegirobackup"))

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
        XCTAssertFalse(scan.files.contains(where: { $0.pathExtension.lowercased() == "agvt" }))
        XCTAssertFalse(scan.files.contains(where: { $0.pathExtension.lowercased() == "aegirobackup" }))
        XCTAssertTrue(scan.skippedPaths.contains(where: { $0.contains(".Spotlight-V100") }))
        XCTAssertTrue(scan.skippedPaths.contains(where: { $0.contains("System Volume Information") }))
        XCTAssertTrue(scan.skippedPaths.contains(where: { $0.hasSuffix("old.agvt") }))
        XCTAssertTrue(scan.skippedPaths.contains(where: { $0.hasSuffix("old.aegirobackup") }))
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

    func testUSBUserDataEncryptReportsPerFileProgress() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aegiro-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = tmp.appendingPathComponent("usb", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: root.appendingPathComponent("one.txt"))
        try Data("two".utf8).write(to: root.appendingPathComponent("two.txt"))

        let vaultURL = root.appendingPathComponent("userdata.agvt")
        var events: [USBUserDataEncryptProgress] = []
        let result = try USBUserDataCrypto.encryptUserFiles(sourceRootURL: root,
                                                            vaultURL: vaultURL,
                                                            passphrase: "test-pass",
                                                            deleteOriginals: false,
                                                            dryRun: false) { progress in
            events.append(progress)
        }

        XCTAssertEqual(result.encryptedFileCount, 2)
        XCTAssertFalse(events.contains { $0.stage == .preparing })
        let encryptEvents = events.filter { $0.stage == .encrypting && $0.totalFileCount > 0 }
        XCTAssertFalse(encryptEvents.isEmpty)
        XCTAssertEqual(encryptEvents.last?.processedFileCount, 2)
        XCTAssertEqual(encryptEvents.last?.totalFileCount, 2)
        XCTAssertEqual(encryptEvents.last?.fraction, 1.0)
    }

    func testUSBUserDataEncryptPreservesNestedRelativePathsFromSourceRoot() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aegiro-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = tmp.appendingPathComponent("usb", isDirectory: true)
        let nested = root.appendingPathComponent("asdf/ghjkl", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let sourceFile = nested.appendingPathComponent("template.cpp")
        let payload = Data("int main() { return 0; }\n".utf8)
        try payload.write(to: sourceFile)

        let vaultURL = root.appendingPathComponent("userdata.agvt")
        let result = try USBUserDataCrypto.encryptUserFiles(sourceRootURL: root,
                                                            vaultURL: vaultURL,
                                                            passphrase: "test-pass",
                                                            deleteOriginals: false,
                                                            dryRun: false)
        XCTAssertEqual(result.encryptedFileCount, 1)

        let listed = try Exporter.list(vaultURL: vaultURL, passphrase: "test-pass")
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.logicalPath, "asdf/ghjkl/template.cpp")

        let outDir = tmp.appendingPathComponent("out", isDirectory: true)
        let exported = try Exporter.export(vaultURL: vaultURL, passphrase: "test-pass", filters: [], outDir: outDir)
        XCTAssertEqual(exported.count, 1)
        XCTAssertEqual(exported.first?.0, "asdf/ghjkl/template.cpp")
        let restored = try XCTUnwrap(exported.first?.1)
        XCTAssertEqual(try Data(contentsOf: restored), payload)
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
        let restored = try XCTUnwrap(exported.first?.1)
        XCTAssertEqual(try Data(contentsOf: restored), payload)
    }
}
