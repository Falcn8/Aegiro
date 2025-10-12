
import Foundation
import CryptoKit

public final class Backup {
    public static func exportBackup(from vault: AegiroVault, to outURL: URL, passphrase: String) throws {
        let tmp = outURL.deletingPathExtension().appendingPathExtension("backup_tmp")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let manifestURL = tmp.appendingPathComponent("manifest.json")
        let keysURL = tmp.appendingPathComponent("keys.bin")
        let dataDir = tmp.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let m = try JSONEncoder().encode(vault.manifest)
        try m.write(to: manifestURL)

        try Data("PQC_WRAP_PLACEHOLDER".utf8).write(to: keysURL)
    }
}
