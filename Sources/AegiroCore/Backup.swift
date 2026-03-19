import Foundation
import CryptoKit

public struct BackupArchiveMetadata: Codable {
    public var formatVersion: Int
    public var createdAt: Date
    public var sourceVaultFileName: String
    public var sourceVaultSizeBytes: UInt64
    public var sourceVaultSHA256Hex: String
    public var manifestIndexRootHashHex: String
    public var manifestChunkMapHashHex: String
    public var manifestSignatureSHA256Hex: String
    public var manifestSignerPKSHA256Hex: String
    public var passphraseValidated: Bool
    public var decryptedEntryCount: Int?
}

public struct BackupArchiveInfo: Codable {
    public var metadata: BackupArchiveMetadata
    public var payloadSizeBytes: UInt64
    public var archiveSizeBytes: UInt64
}

public final class Backup {
    private static let magic = Data("AEGIROBK1".utf8)
    private static let streamChunkSize = 1_048_576

    public static func exportBackup(from vault: AegiroVault, to outURL: URL, passphrase: String) throws {
        let fm = FileManager.default
        let sourceVaultURL = vault.url.standardizedFileURL
        let targetURL = outURL.standardizedFileURL
        let trimmedPassphrase = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)

        guard sourceVaultURL.path != targetURL.path else {
            throw NSError(domain: "Backup", code: -1, userInfo: [NSLocalizedDescriptionKey: "Backup output path cannot be the same as the vault path."])
        }

        try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var passphraseValidated = false
        var decryptedEntryCount: Int? = nil
        if !trimmedPassphrase.isEmpty {
            let page = try Exporter.listPage(vaultURL: sourceVaultURL,
                                             passphrase: trimmedPassphrase,
                                             offset: 0,
                                             limit: 1)
            passphraseValidated = true
            decryptedEntryCount = page.totalCount
        }

        let sourceSummary = try computeSHA256AndSize(of: sourceVaultURL)
        let metadata = BackupArchiveMetadata(
            formatVersion: 1,
            createdAt: Date(),
            sourceVaultFileName: sourceVaultURL.lastPathComponent,
            sourceVaultSizeBytes: sourceSummary.sizeBytes,
            sourceVaultSHA256Hex: sourceSummary.sha256Hex,
            manifestIndexRootHashHex: hexString(vault.manifest.indexRootHash),
            manifestChunkMapHashHex: hexString(vault.manifest.chunkMapHash),
            manifestSignatureSHA256Hex: hexString(Data(SHA256.hash(data: vault.manifest.signature))),
            manifestSignerPKSHA256Hex: hexString(Data(SHA256.hash(data: vault.manifest.signerPK))),
            passphraseValidated: passphraseValidated,
            decryptedEntryCount: decryptedEntryCount
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let metadataBlob = try encoder.encode(metadata)
        guard metadataBlob.count <= Int(UInt32.max) else {
            throw NSError(domain: "Backup", code: -2, userInfo: [NSLocalizedDescriptionKey: "Backup metadata is too large to encode."])
        }

        let tmpURL = targetURL.deletingLastPathComponent()
            .appendingPathComponent(".\(targetURL.lastPathComponent).tmp.\(UUID().uuidString)")

        if fm.fileExists(atPath: tmpURL.path) {
            try? fm.removeItem(at: tmpURL)
        }
        guard fm.createFile(atPath: tmpURL.path, contents: nil) else {
            throw NSError(domain: "Backup", code: -3, userInfo: [NSLocalizedDescriptionKey: "Unable to create temporary backup file."])
        }

        var succeeded = false
        defer {
            if !succeeded {
                try? fm.removeItem(at: tmpURL)
            }
        }

        let outHandle = try FileHandle(forWritingTo: tmpURL)
        defer { try? outHandle.close() }

        try outHandle.write(contentsOf: magic)
        try outHandle.write(contentsOf: uint32LE(UInt32(metadataBlob.count)))
        try outHandle.write(contentsOf: metadataBlob)
        try outHandle.write(contentsOf: uint64LE(sourceSummary.sizeBytes))
        let copiedBytes = try copyBytes(from: sourceVaultURL, to: outHandle)
        guard copiedBytes == sourceSummary.sizeBytes else {
            throw NSError(domain: "Backup", code: -4, userInfo: [NSLocalizedDescriptionKey: "Backup payload copy was incomplete."])
        }
        try outHandle.synchronize()

        if fm.fileExists(atPath: targetURL.path) {
            try fm.removeItem(at: targetURL)
        }
        try fm.moveItem(at: tmpURL, to: targetURL)
        succeeded = true
    }

    public static func inspectBackup(at backupURL: URL) throws -> BackupArchiveInfo {
        let normalizedURL = backupURL.standardizedFileURL
        let handle = try FileHandle(forReadingFrom: normalizedURL)
        defer { try? handle.close() }

        let storedMagic = try readExact(count: magic.count, from: handle)
        guard storedMagic == magic else {
            throw NSError(domain: "Backup", code: -10, userInfo: [NSLocalizedDescriptionKey: "Invalid backup file format (magic mismatch)."])
        }

        let metadataLength = Int(fromLEUInt32: try readExact(count: 4, from: handle))
        guard metadataLength >= 0 else {
            throw NSError(domain: "Backup", code: -11, userInfo: [NSLocalizedDescriptionKey: "Invalid backup metadata length."])
        }
        let metadataBlob = try readExact(count: metadataLength, from: handle)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(BackupArchiveMetadata.self, from: metadataBlob)

        let payloadSizeBytes = UInt64(fromLEUInt64: try readExact(count: 8, from: handle))
        let attrs = try FileManager.default.attributesOfItem(atPath: normalizedURL.path)
        let archiveSizeBytes = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

        let expectedSize = UInt64(magic.count + 4 + metadataLength + 8) + payloadSizeBytes
        guard archiveSizeBytes >= expectedSize else {
            throw NSError(domain: "Backup", code: -12, userInfo: [NSLocalizedDescriptionKey: "Backup file is truncated (payload is incomplete)."])
        }

        return BackupArchiveInfo(metadata: metadata,
                                 payloadSizeBytes: payloadSizeBytes,
                                 archiveSizeBytes: archiveSizeBytes)
    }

    public static func restoreBackup(from backupURL: URL,
                                     to outVaultURL: URL,
                                     overwrite: Bool = false) throws -> BackupArchiveInfo {
        let fm = FileManager.default
        let normalizedBackupURL = backupURL.standardizedFileURL
        let normalizedOutURL = outVaultURL.standardizedFileURL

        guard normalizedBackupURL.path != normalizedOutURL.path else {
            throw NSError(domain: "Backup", code: -30, userInfo: [NSLocalizedDescriptionKey: "Restore output path cannot be the same as the backup file path."])
        }

        if fm.fileExists(atPath: normalizedOutURL.path), !overwrite {
            throw NSError(domain: "Backup", code: -31, userInfo: [NSLocalizedDescriptionKey: "Restore output already exists. Re-run with overwrite enabled."])
        }

        try fm.createDirectory(at: normalizedOutURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let sourceHandle = try FileHandle(forReadingFrom: normalizedBackupURL)
        defer { try? sourceHandle.close() }
        let storedMagic = try readExact(count: magic.count, from: sourceHandle)
        guard storedMagic == magic else {
            throw NSError(domain: "Backup", code: -10, userInfo: [NSLocalizedDescriptionKey: "Invalid backup file format (magic mismatch)."])
        }
        let metadataLength = Int(fromLEUInt32: try readExact(count: 4, from: sourceHandle))
        guard metadataLength >= 0 else {
            throw NSError(domain: "Backup", code: -11, userInfo: [NSLocalizedDescriptionKey: "Invalid backup metadata length."])
        }
        let metadataBlob = try readExact(count: metadataLength, from: sourceHandle)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(BackupArchiveMetadata.self, from: metadataBlob)
        let payloadSizeBytes = UInt64(fromLEUInt64: try readExact(count: 8, from: sourceHandle))

        let attrs = try fm.attributesOfItem(atPath: normalizedBackupURL.path)
        let archiveSizeBytes = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let info = BackupArchiveInfo(metadata: metadata,
                                     payloadSizeBytes: payloadSizeBytes,
                                     archiveSizeBytes: archiveSizeBytes)

        let tmpURL = normalizedOutURL.deletingLastPathComponent()
            .appendingPathComponent(".\(normalizedOutURL.lastPathComponent).tmp.\(UUID().uuidString)")
        if fm.fileExists(atPath: tmpURL.path) {
            try? fm.removeItem(at: tmpURL)
        }
        guard fm.createFile(atPath: tmpURL.path, contents: nil) else {
            throw NSError(domain: "Backup", code: -3, userInfo: [NSLocalizedDescriptionKey: "Unable to create temporary restore file."])
        }

        var succeeded = false
        defer {
            if !succeeded {
                try? fm.removeItem(at: tmpURL)
            }
        }

        let outHandle = try FileHandle(forWritingTo: tmpURL)
        defer { try? outHandle.close() }

        var bytesRemaining = info.payloadSizeBytes
        var hasher = SHA256()
        while bytesRemaining > 0 {
            let readCount = Int(min(UInt64(streamChunkSize), bytesRemaining))
            guard let chunk = try sourceHandle.read(upToCount: readCount), !chunk.isEmpty else {
                throw NSError(domain: "Backup", code: -12, userInfo: [NSLocalizedDescriptionKey: "Backup file is truncated (payload is incomplete)."])
            }
            try outHandle.write(contentsOf: chunk)
            hasher.update(data: chunk)
            bytesRemaining -= UInt64(chunk.count)
        }
        try outHandle.synchronize()

        let restoredHash = hexString(Data(hasher.finalize()))
        if restoredHash != info.metadata.sourceVaultSHA256Hex {
            throw NSError(domain: "Backup",
                          code: -32,
                          userInfo: [NSLocalizedDescriptionKey: "Restored payload hash does not match backup metadata hash."])
        }

        if fm.fileExists(atPath: normalizedOutURL.path) {
            try fm.removeItem(at: normalizedOutURL)
        }
        try fm.moveItem(at: tmpURL, to: normalizedOutURL)
        succeeded = true
        return info
    }

    private static func computeSHA256AndSize(of fileURL: URL) throws -> (sha256Hex: String, sizeBytes: UInt64) {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        var total: UInt64 = 0
        while true {
            guard let chunk = try handle.read(upToCount: streamChunkSize), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
            total += UInt64(chunk.count)
        }

        return (hexString(Data(hasher.finalize())), total)
    }

    private static func copyBytes(from sourceURL: URL, to output: FileHandle) throws -> UInt64 {
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }

        var total: UInt64 = 0
        while true {
            guard let chunk = try input.read(upToCount: streamChunkSize), !chunk.isEmpty else {
                break
            }
            try output.write(contentsOf: chunk)
            total += UInt64(chunk.count)
        }
        return total
    }

    private static func readExact(count: Int, from handle: FileHandle) throws -> Data {
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw NSError(domain: "Backup", code: -20, userInfo: [NSLocalizedDescriptionKey: "Unexpected end of backup file."])
        }
        return data
    }

    private static func uint32LE(_ value: UInt32) -> Data {
        var little = value.littleEndian
        return Data(bytes: &little, count: MemoryLayout<UInt32>.size)
    }

    private static func uint64LE(_ value: UInt64) -> Data {
        var little = value.littleEndian
        return Data(bytes: &little, count: MemoryLayout<UInt64>.size)
    }

    private static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

private extension Int {
    init(fromLEUInt32 data: Data) {
        precondition(data.count == 4)
        self = data.enumerated().reduce(0) { partial, element in
            partial | (Int(element.element) << (8 * element.offset))
        }
    }
}

private extension UInt64 {
    init(fromLEUInt64 data: Data) {
        precondition(data.count == 8)
        self = data.enumerated().reduce(0) { partial, element in
            partial | (UInt64(element.element) << UInt64(8 * element.offset))
        }
    }
}
