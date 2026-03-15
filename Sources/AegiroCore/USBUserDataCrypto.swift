import Foundation

public struct USBUserDataScanResult: Sendable {
    public let sourceRootURL: URL
    public let files: [URL]
    public let skippedPaths: [String]

    public var scannedFileCount: Int { files.count }
    public var skippedPathCount: Int { skippedPaths.count }

    public init(sourceRootURL: URL, files: [URL], skippedPaths: [String]) {
        self.sourceRootURL = sourceRootURL
        self.files = files
        self.skippedPaths = skippedPaths
    }
}

public struct USBUserDataEncryptResult: Sendable {
    public let vaultURL: URL
    public let createdVault: Bool
    public let scannedFileCount: Int
    public let encryptedFileCount: Int
    public let skippedPathCount: Int
    public let deletedOriginalCount: Int
    public let deletionErrors: [String]
    public let dryRun: Bool

    public init(vaultURL: URL,
                createdVault: Bool,
                scannedFileCount: Int,
                encryptedFileCount: Int,
                skippedPathCount: Int,
                deletedOriginalCount: Int,
                deletionErrors: [String],
                dryRun: Bool) {
        self.vaultURL = vaultURL
        self.createdVault = createdVault
        self.scannedFileCount = scannedFileCount
        self.encryptedFileCount = encryptedFileCount
        self.skippedPathCount = skippedPathCount
        self.deletedOriginalCount = deletedOriginalCount
        self.deletionErrors = deletionErrors
        self.dryRun = dryRun
    }
}

public struct USBUserDataEncryptProgress: Sendable {
    public enum Stage: String, Sendable {
        case scanning
        case preparing
        case encrypting
        case deletingOriginals
        case completed
    }

    public let stage: Stage
    public let processedFileCount: Int
    public let totalFileCount: Int
    public let currentPath: String?
    public let message: String

    public var fraction: Double? {
        guard totalFileCount > 0 else { return nil }
        let clamped = min(max(processedFileCount, 0), totalFileCount)
        return Double(clamped) / Double(totalFileCount)
    }

    public init(stage: Stage,
                processedFileCount: Int,
                totalFileCount: Int,
                currentPath: String?,
                message: String) {
        self.stage = stage
        self.processedFileCount = processedFileCount
        self.totalFileCount = totalFileCount
        self.currentPath = currentPath
        self.message = message
    }
}

public enum USBUserDataCrypto {
    private static func throwIfCancelled(_ isCancelled: (() -> Bool)?) throws {
        if isCancelled?() == true {
            throw AEGError.io("USB vault-pack cancelled by user.")
        }
    }

    // Keep USB/OS metadata intact so volume behavior is not damaged.
    private static let excludedRootEntryNames: Set<String> = [
        ".spotlight-v100",
        ".fseventsd",
        ".trashes",
        ".temporaryitems",
        ".documentrevisions-v100",
        ".trash",
        "system volume information",
        "$recycle.bin",
        "found.000"
    ]

    private static let excludedFileNames: Set<String> = [
        ".ds_store",
        ".volumeicon.icns",
        ".apdisk",
        ".com.apple.timemachine.supported",
        ".metadata_never_index",
        ".metadata_never_index_unless_rootfs",
        "indexervolumeguid",
        "wpsettings.dat",
        "icon\r"
    ]

    private static let excludedFileSuffixes: [String] = [
        ".aegiro-diskkey.json",
        ".aegiro-usbkey.json"
    ]

    private static let excludedExtensions: Set<String> = [
        "agvt",
        "aegirovault"
    ]

    public static func scanUserFiles(sourceRootURL: URL) throws -> USBUserDataScanResult {
        let sourceRoot = sourceRootURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AEGError.io("Source folder does not exist: \(sourceRoot.path)")
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: sourceRoot,
                                                              includingPropertiesForKeys: Array(keys),
                                                              options: [.skipsPackageDescendants],
                                                              errorHandler: { _, _ in true }) else {
            throw AEGError.io("Unable to scan source folder: \(sourceRoot.path)")
        }

        var files: [URL] = []
        var skipped = Set<String>()
        let rootPrefix = sourceRoot.path.hasSuffix("/") ? sourceRoot.path : sourceRoot.path + "/"

        while let item = enumerator.nextObject() as? URL {
            let candidate = item.standardizedFileURL
            guard candidate.path.hasPrefix(rootPrefix) else { continue }
            let relativePath = String(candidate.path.dropFirst(rootPrefix.count))
            guard !relativePath.isEmpty else { continue }

            let relativeComponents = relativePath
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard let first = relativeComponents.first else { continue }

            if excludedRootEntryNames.contains(first.lowercased()) {
                if (try? candidate.resourceValues(forKeys: keys).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                skipped.insert(candidate.path)
                continue
            }

            if shouldSkipFile(candidate, relativeComponents: relativeComponents) {
                skipped.insert(candidate.path)
                continue
            }

            let values = try? candidate.resourceValues(forKeys: keys)
            if values?.isSymbolicLink == true {
                if values?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                skipped.insert(candidate.path)
                continue
            }
            if values?.isDirectory == true {
                continue
            }
            if values?.isRegularFile == true {
                files.append(candidate)
            }
        }

        files.sort { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        let skippedPaths = skipped.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return USBUserDataScanResult(sourceRootURL: sourceRoot, files: files, skippedPaths: skippedPaths)
    }

    public static func encryptUserFiles(sourceRootURL: URL,
                                        vaultURL: URL,
                                        passphrase: String,
                                        deleteOriginals: Bool,
                                        dryRun: Bool,
                                        progress: ((USBUserDataEncryptProgress) -> Void)? = nil,
                                        isCancelled: (() -> Bool)? = nil) throws -> USBUserDataEncryptResult {
        try throwIfCancelled(isCancelled)
        progress?(USBUserDataEncryptProgress(stage: .scanning,
                                             processedFileCount: 0,
                                             totalFileCount: 0,
                                             currentPath: nil,
                                             message: "Scanning source files..."))
        let scan = try scanUserFiles(sourceRootURL: sourceRootURL)
        try throwIfCancelled(isCancelled)
        let normalizedVaultURL = vaultURL.standardizedFileURL
        progress?(USBUserDataEncryptProgress(stage: .encrypting,
                                             processedFileCount: 0,
                                             totalFileCount: scan.scannedFileCount,
                                             currentPath: nil,
                                             message: "Found \(scan.scannedFileCount) user file(s)."))
        if dryRun {
            progress?(USBUserDataEncryptProgress(stage: .completed,
                                                 processedFileCount: scan.scannedFileCount,
                                                 totalFileCount: scan.scannedFileCount,
                                                 currentPath: nil,
                                                 message: "Scan complete: \(scan.scannedFileCount) file(s)."))
            return USBUserDataEncryptResult(vaultURL: normalizedVaultURL,
                                            createdVault: false,
                                            scannedFileCount: scan.scannedFileCount,
                                            encryptedFileCount: 0,
                                            skippedPathCount: scan.skippedPathCount,
                                            deletedOriginalCount: 0,
                                            deletionErrors: [],
                                            dryRun: true)
        }

        let trimmedPassphrase = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPassphrase.isEmpty else {
            throw AEGError.io("Missing vault passphrase")
        }

        progress?(USBUserDataEncryptProgress(stage: .preparing,
                                             processedFileCount: 0,
                                             totalFileCount: scan.scannedFileCount,
                                             currentPath: nil,
                                             message: "Preparing \(scan.scannedFileCount) user file(s) for encryption..."))
        try throwIfCancelled(isCancelled)

        try FileManager.default.createDirectory(at: normalizedVaultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let createdVault: Bool
        if FileManager.default.fileExists(atPath: normalizedVaultURL.path) {
            _ = try AegiroVault.open(at: normalizedVaultURL)
            createdVault = false
        } else {
            _ = try AegiroVault.create(at: normalizedVaultURL, passphrase: trimmedPassphrase, touchID: false)
            createdVault = true
        }

        let imported = try Importer.sidecarImport(vaultURL: normalizedVaultURL,
                                                  passphrase: trimmedPassphrase,
                                                  files: scan.files,
                                                  progress: { importedCount, totalCount, path in
                                                      let name = URL(fileURLWithPath: path).lastPathComponent
                                                      progress?(USBUserDataEncryptProgress(stage: .encrypting,
                                                                                           processedFileCount: importedCount,
                                                                                           totalFileCount: totalCount,
                                                                                           currentPath: path,
                                                                                           message: "Encrypting \(importedCount)/\(totalCount): \(name)"))
                                                  },
                                                  preparationProgress: { preparedCount, totalCount, path in
                                                      let name = URL(fileURLWithPath: path).lastPathComponent
                                                      progress?(USBUserDataEncryptProgress(stage: .preparing,
                                                                                           processedFileCount: preparedCount,
                                                                                           totalFileCount: totalCount,
                                                                                           currentPath: path,
                                                                                           message: "Preparing \(preparedCount)/\(totalCount): \(name)"))
                                                  },
                                                  isCancelled: isCancelled).imported

        var deletedOriginalCount = 0
        var deletionErrors: [String] = []
        if deleteOriginals && !scan.files.isEmpty {
            guard imported == scan.scannedFileCount else {
                throw AEGError.integrity("Imported \(imported) of \(scan.scannedFileCount) files. Original files were left untouched.")
            }
            progress?(USBUserDataEncryptProgress(stage: .deletingOriginals,
                                                 processedFileCount: 0,
                                                 totalFileCount: scan.files.count,
                                                 currentPath: nil,
                                                 message: "Deleting original files..."))
            let deletion = deleteSourceFiles(scan.files,
                                             sourceRootURL: scan.sourceRootURL) { deletedCount, totalCount, path in
                let name = URL(fileURLWithPath: path).lastPathComponent
                progress?(USBUserDataEncryptProgress(stage: .deletingOriginals,
                                                     processedFileCount: deletedCount,
                                                     totalFileCount: totalCount,
                                                     currentPath: path,
                                                     message: "Deleting \(deletedCount)/\(totalCount): \(name)"))
            }
            deletedOriginalCount = deletion.deleted
            deletionErrors = deletion.errors
        }

        progress?(USBUserDataEncryptProgress(stage: .completed,
                                             processedFileCount: imported,
                                             totalFileCount: scan.scannedFileCount,
                                             currentPath: nil,
                                             message: "Encryption complete: \(imported)/\(scan.scannedFileCount) file(s)."))

        return USBUserDataEncryptResult(vaultURL: normalizedVaultURL,
                                        createdVault: createdVault,
                                        scannedFileCount: scan.scannedFileCount,
                                        encryptedFileCount: imported,
                                        skippedPathCount: scan.skippedPathCount,
                                        deletedOriginalCount: deletedOriginalCount,
                                        deletionErrors: deletionErrors,
                                        dryRun: false)
    }

    private static func shouldSkipFile(_ fileURL: URL, relativeComponents: [String]) -> Bool {
        let name = fileURL.lastPathComponent
        let lowerName = name.lowercased()
        if excludedFileNames.contains(lowerName) {
            return true
        }
        if excludedExtensions.contains(fileURL.pathExtension.lowercased()) {
            return true
        }
        if excludedFileSuffixes.contains(where: { lowerName.hasSuffix($0) }) {
            return true
        }
        if lowerName.hasPrefix("._") {
            return true
        }
        // Extra defense for root-level system folders that can vary in case.
        if let first = relativeComponents.first, excludedRootEntryNames.contains(first.lowercased()) {
            return true
        }
        return false
    }

    private static func deleteSourceFiles(_ files: [URL],
                                          sourceRootURL: URL,
                                          progress: ((Int, Int, String) -> Void)? = nil) -> (deleted: Int, errors: [String]) {
        var deleted = 0
        var errors: [String] = []
        let total = files.count

        for file in files {
            do {
                try Shredder.shred(path: file.path)
                deleted += 1
                progress?(deleted, total, file.path)
            } catch {
                do {
                    try FileManager.default.removeItem(at: file)
                    deleted += 1
                    progress?(deleted, total, file.path)
                } catch {
                    errors.append("\(file.path): \(error)")
                }
            }
        }

        removeEmptyDirectories(from: files, sourceRootURL: sourceRootURL)
        return (deleted, errors)
    }

    private static func removeEmptyDirectories(from files: [URL], sourceRootURL: URL) {
        let rootPath = sourceRootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var directories = Set<String>()

        for file in files {
            var current = file.deletingLastPathComponent().standardizedFileURL.path
            while current.hasPrefix(rootPrefix) && current != rootPath {
                directories.insert(current)
                let parent = URL(fileURLWithPath: current, isDirectory: true).deletingLastPathComponent().path
                if parent == current { break }
                current = parent
            }
        }

        let sorted = directories.sorted {
            $0.split(separator: "/").count > $1.split(separator: "/").count
        }
        for directory in sorted {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
                continue
            }
            if contents.isEmpty {
                try? FileManager.default.removeItem(atPath: directory)
            }
        }
    }
}
