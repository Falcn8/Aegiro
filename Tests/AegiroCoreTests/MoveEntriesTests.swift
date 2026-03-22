import XCTest
@testable import AegiroCore

final class MoveEntriesTests: XCTestCase {
    func testMoveFileIntoDirectory() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aegiro-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let vaultURL = tmp.appendingPathComponent("vault.agvt")
        _ = try AegiroVault.create(at: vaultURL, passphrase: "test-pass", touchID: false)
        XCTAssertTrue(try Editor.createDirectory(vaultURL: vaultURL, passphrase: "test-pass", logicalPath: "Dest"))

        let sourceRoot = tmp.appendingPathComponent("import", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let sourceFile = sourceRoot.appendingPathComponent("one.txt")
        let sourceData = Data("move-me".utf8)
        try sourceData.write(to: sourceFile)

        let imported = try Importer.sidecarImport(vaultURL: vaultURL,
                                                  passphrase: "test-pass",
                                                  files: [sourceFile],
                                                  logicalRootURL: sourceRoot,
                                                  destinationDirectoryPath: "Inbox")
        XCTAssertEqual(imported.imported, 1)

        let before = try Exporter.list(vaultURL: vaultURL, passphrase: "test-pass")
        let sourceLogicalPath = try XCTUnwrap(before.first(where: { !isVaultDirectoryMarkerPath($0.logicalPath) })?.logicalPath)
        XCTAssertEqual(sourceLogicalPath, "Inbox/one.txt")

        let moved = try Editor.moveEntries(vaultURL: vaultURL,
                                           passphrase: "test-pass",
                                           logicalPaths: [sourceLogicalPath],
                                           directoryPaths: [],
                                           destinationDirectoryPath: "Dest")
        XCTAssertEqual(moved, 1)

        let after = try Exporter.list(vaultURL: vaultURL, passphrase: "test-pass")
        XCTAssertTrue(after.contains { $0.logicalPath == "Dest/one.txt" })
        XCTAssertFalse(after.contains { $0.logicalPath == sourceLogicalPath })

        let outDir = tmp.appendingPathComponent("out", isDirectory: true)
        let exported = try Exporter.export(vaultURL: vaultURL, passphrase: "test-pass", filters: [], outDir: outDir)
        XCTAssertEqual(exported.count, 1)
        XCTAssertEqual(exported.first?.0, "Dest/one.txt")
        let exportedURL = try XCTUnwrap(exported.first?.1)
        XCTAssertEqual(try Data(contentsOf: exportedURL), sourceData)
    }

    func testMoveFolderMovesMarkerAndDescendants() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aegiro-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let vaultURL = tmp.appendingPathComponent("vault.agvt")
        _ = try AegiroVault.create(at: vaultURL, passphrase: "test-pass", touchID: false)
        XCTAssertTrue(try Editor.createDirectory(vaultURL: vaultURL, passphrase: "test-pass", logicalPath: "Projects"))
        XCTAssertTrue(try Editor.createDirectory(vaultURL: vaultURL, passphrase: "test-pass", logicalPath: "Archive"))

        let sourceRoot = tmp.appendingPathComponent("import", isDirectory: true)
        let nested = sourceRoot.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let sourceFile = nested.appendingPathComponent("report.txt")
        let sourceData = Data("folder-move".utf8)
        try sourceData.write(to: sourceFile)

        let imported = try Importer.sidecarImport(vaultURL: vaultURL,
                                                  passphrase: "test-pass",
                                                  files: [sourceFile],
                                                  logicalRootURL: sourceRoot,
                                                  destinationDirectoryPath: "Projects")
        XCTAssertEqual(imported.imported, 1)

        let moved = try Editor.moveEntries(vaultURL: vaultURL,
                                           passphrase: "test-pass",
                                           logicalPaths: [],
                                           directoryPaths: ["Projects"],
                                           destinationDirectoryPath: "Archive")
        XCTAssertEqual(moved, 2)

        let after = try Exporter.list(vaultURL: vaultURL, passphrase: "test-pass")
        XCTAssertTrue(after.contains { $0.logicalPath == "Archive/Projects/\(vaultDirectoryMarkerFileName)" })
        XCTAssertTrue(after.contains { $0.logicalPath == "Archive/Projects/a/b/report.txt" })
        XCTAssertFalse(after.contains { $0.logicalPath.hasPrefix("Projects/") })

        let outDir = tmp.appendingPathComponent("out", isDirectory: true)
        let exported = try Exporter.export(vaultURL: vaultURL, passphrase: "test-pass", filters: [], outDir: outDir)
        XCTAssertEqual(exported.count, 1)
        XCTAssertEqual(exported.first?.0, "Archive/Projects/a/b/report.txt")
        let exportedURL = try XCTUnwrap(exported.first?.1)
        XCTAssertEqual(try Data(contentsOf: exportedURL), sourceData)
    }
}
