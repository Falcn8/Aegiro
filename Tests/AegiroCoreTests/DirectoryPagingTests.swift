import XCTest
@testable import AegiroCore

final class DirectoryPagingTests: XCTestCase {
    func testCreateDirectoryMarkerAppearsInFirstListPage() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aegiro-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let vaultURL = tmp.appendingPathComponent("vault.agvt")
        _ = try AegiroVault.create(at: vaultURL, passphrase: "test-pass", touchID: false)

        let fileURL = tmp.appendingPathComponent("seed.txt")
        try Data("seed".utf8).write(to: fileURL)
        let imported = try Importer.sidecarImport(vaultURL: vaultURL, passphrase: "test-pass", files: [fileURL])
        XCTAssertEqual(imported.imported, 1)

        XCTAssertTrue(try Editor.createDirectory(vaultURL: vaultURL, passphrase: "test-pass", logicalPath: "Recent"))
        let page = try Exporter.listPage(vaultURL: vaultURL, passphrase: "test-pass", offset: 0, limit: 1)
        XCTAssertEqual(page.entries.count, 1)
        XCTAssertEqual(page.entries.first?.logicalPath, "Recent/\(vaultDirectoryMarkerFileName)")
    }
}
