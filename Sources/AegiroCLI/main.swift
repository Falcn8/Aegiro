import Foundation
import ArgumentParser
import AegiroCore
import Darwin

let AEGIRO_CLI_VERSION = "0.1.3-beta"

private enum CLIHelpers {
    static func expandedPath(_ value: String) -> String {
        NSString(string: value).expandingTildeInPath
    }

    static func fileURL(_ path: String, directory: Bool = false) -> URL {
        URL(fileURLWithPath: expandedPath(path), isDirectory: directory)
    }

    static func requireNonEmpty(_ value: String?, message: String) throws -> String {
        guard let value, !value.isEmpty else {
            throw ValidationError(message)
        }
        return value
    }

    static func resolvedPassphrase(passphrase: String?,
                                   passphraseStdin: Bool,
                                   required: Bool,
                                   prompt: String) throws -> String? {
        if passphrase != nil && passphraseStdin {
            throw ValidationError("Use either --passphrase or --passphrase-stdin, not both.")
        }

        if passphraseStdin {
            guard let line = readLine(strippingNewline: true) else {
                throw ValidationError("No passphrase found on stdin.")
            }
            if required && line.isEmpty {
                throw ValidationError("Passphrase is required.")
            }
            return line.isEmpty ? nil : line
        }

        if let passphrase {
            if required && passphrase.isEmpty {
                throw ValidationError("Passphrase is required.")
            }
            return passphrase
        }

        if required {
            if isatty(STDIN_FILENO) == 1 {
                guard let cString = getpass(prompt) else {
                    throw ValidationError("Unable to read passphrase from terminal.")
                }
                let value = String(cString: cString)
                if value.isEmpty {
                    throw ValidationError("Passphrase is required.")
                }
                return value
            }
            throw ValidationError("Passphrase is required. Provide --passphrase or --passphrase-stdin.")
        }

        return nil
    }

    static func readRequiredPassphrase(_ passphrase: String?,
                                       stdin: Bool,
                                       prompt: String) throws -> String {
        guard let value = try resolvedPassphrase(passphrase: passphrase,
                                                 passphraseStdin: stdin,
                                                 required: true,
                                                 prompt: prompt) else {
            throw ValidationError("Passphrase is required.")
        }
        return value
    }

    static func readOptionalPassphrase(_ passphrase: String?,
                                       stdin: Bool,
                                       prompt: String) throws -> String? {
        try resolvedPassphrase(passphrase: passphrase,
                               passphraseStdin: stdin,
                               required: false,
                               prompt: prompt)
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }

    static func formatTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f.string(from: date)
    }

    static func defaultDiskRecoveryURL(diskIdentifier: String) -> URL {
        let safeID = diskIdentifier.replacingOccurrences(of: "/", with: "_")
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("\(safeID).aegiro-diskkey.json")
    }

    static func defaultUSBContainerRecoveryURL(imageURL: URL) -> URL {
        let base = imageURL.deletingPathExtension().lastPathComponent
        return imageURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(base).aegiro-usbkey.json")
    }
}

private protocol PassphraseInput {
    var passphrase: String? { get }
    var passphraseStdin: Bool { get }
}

private extension PassphraseInput {
    func requiredPassphrase(prompt: String) throws -> String {
        try CLIHelpers.readRequiredPassphrase(passphrase, stdin: passphraseStdin, prompt: prompt)
    }

    func optionalPassphrase(prompt: String) throws -> String? {
        try CLIHelpers.readOptionalPassphrase(passphrase, stdin: passphraseStdin, prompt: prompt)
    }
}

struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "version", abstract: "Show CLI version and build info")

    func run() {
        print("""
Aegiro CLI v\(AEGIRO_CLI_VERSION)
Commit: \(AEGIRO_BUILD_COMMIT)
Built: \(AEGIRO_BUILD_DATE)
""")
    }
}

struct CreateCommand: ParsableCommand, PassphraseInput {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a new vault")

    @Option(name: .long, help: "Path to the vault file (.agvt).") var vault: String
    @Option(name: .long, help: "Vault passphrase.") var passphrase: String?
    @Flag(name: .long, help: "Read passphrase from stdin.") var passphraseStdin = false
    @Flag(name: .long, help: "Enable Touch ID flag in the vault header.") var touchid = false

    func run() throws {
        let pass = try requiredPassphrase(prompt: "Enter vault passphrase: ")
        let v = try AegiroVault.create(at: CLIHelpers.fileURL(vault), passphrase: pass, touchID: touchid)
        print("Vault created at \(v.url.path)")
    }
}

struct ImportCommand: ParsableCommand, PassphraseInput {
    static let configuration = CommandConfiguration(commandName: "import", abstract: "Import files into a vault")

    @Option(name: .long) var vault: String
    @Option(name: .long) var passphrase: String?
    @Flag(name: .long, help: "Read passphrase from stdin.") var passphraseStdin = false
    @Argument(help: "Files to import") var files: [String] = []

    func run() throws {
        guard !files.isEmpty else {
            throw ValidationError("No files provided to import.")
        }
        let pass = try requiredPassphrase(prompt: "Enter vault passphrase: ")
        let urls = files.map { CLIHelpers.fileURL($0) }
        let (imported, _) = try Importer.sidecarImport(vaultURL: CLIHelpers.fileURL(vault), passphrase: pass, files: urls)
        print("Imported \(imported) file(s) directly into encrypted vault.")
    }
}

struct DeleteCommand: ParsableCommand, PassphraseInput {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete logical entries from a vault")

    @Option(name: .long) var vault: String
    @Option(name: .long) var passphrase: String?
    @Flag(name: .long, help: "Read passphrase from stdin.") var passphraseStdin = false
    @Argument(help: "Logical paths to delete") var logicalPaths: [String] = []

    func run() throws {
        guard !logicalPaths.isEmpty else {
            throw ValidationError("No logical paths provided to delete.")
        }
        let pass = try requiredPassphrase(prompt: "Enter vault passphrase: ")
        let removed = try Editor.deleteEntries(vaultURL: CLIHelpers.fileURL(vault),
                                               passphrase: pass,
                                               logicalPaths: logicalPaths)
        print("Deleted \(removed) file(s) from vault.")
    }
}

struct UnlockCommand: ParsableCommand, PassphraseInput {
    static let configuration = CommandConfiguration(commandName: "unlock", abstract: "Validate unlock and report entry count")

    @Option(name: .long) var vault: String
    @Option(name: .long) var passphrase: String?
    @Flag(name: .long, help: "Read passphrase from stdin.") var passphraseStdin = false

    func run() throws {
        let pass = try requiredPassphrase(prompt: "Enter vault passphrase: ")
        let count = try Locker.unlockInfo(vaultURL: CLIHelpers.fileURL(vault), passphrase: pass)
        print("Unlocked OK. Index entries: \(count)")
    }
}

struct ListCommand: ParsableCommand, PassphraseInput {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List vault entries")

    @Option(name: .long) var vault: String
    @Option(name: .long) var passphrase: String?
    @Flag(name: .long, help: "Read passphrase from stdin.") var passphraseStdin = false

    func run() throws {
        let pass = try requiredPassphrase(prompt: "Enter vault passphrase: ")
        let entries = try Exporter.list(vaultURL: CLIHelpers.fileURL(vault), passphrase: pass)
        for e in entries {
            print("\(e.logicalPath)\t\(e.size) bytes")
        }
    }
}

struct ExportCommand: ParsableCommand, PassphraseInput {
    static let configuration = CommandConfiguration(commandName: "export", abstract: "Export vault entries")

    @Option(name: .long) var vault: String
    @Option(name: .long) var passphrase: String?
    @Flag(name: .long, help: "Read passphrase from stdin.") var passphraseStdin = false
    @Option(name: .long, help: "Output directory") var out: String = "."
    @Argument(help: "Optional filters") var filters: [String] = []

    func run() throws {
        let pass = try requiredPassphrase(prompt: "Enter vault passphrase: ")
        let results = try Exporter.export(vaultURL: CLIHelpers.fileURL(vault),
                                          passphrase: pass,
                                          filters: filters,
                                          outDir: CLIHelpers.fileURL(out, directory: true))
        for (logical, output, bytes) in results {
            print("Exported \(logical) -> \(output.path) (\(bytes) bytes)")
        }
    }
}

struct PreviewCommand: ParsableCommand, PassphraseInput {
    static let configuration = CommandConfiguration(commandName: "preview", abstract: "Export and open first matching file")

    @Option(name: .long) var vault: String
    @Option(name: .long) var passphrase: String?
    @Flag(name: .long, help: "Read passphrase from stdin.") var passphraseStdin = false
    @Argument(help: "Filter text") var filter: String

    func run() throws {
        let pass = try requiredPassphrase(prompt: "Enter vault passphrase: ")
        let entries = try Exporter.list(vaultURL: CLIHelpers.fileURL(vault), passphrase: pass)
        guard let match = entries.first(where: { $0.logicalPath.localizedCaseInsensitiveContains(filter) }) else {
            throw ValidationError("No file matches filter: \(filter)")
        }

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("aegiro-preview-\(UUID().uuidString)", isDirectory: true)
        let results = try Exporter.export(vaultURL: CLIHelpers.fileURL(vault),
                                          passphrase: pass,
                                          filters: [match.logicalPath],
                                          outDir: tmpDir)
        guard let out = results.first?.1 else {
            throw ValidationError("Nothing exported for preview.")
        }
        print("Preview at: \(out.path)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [out.path]
        try? process.run()
        process.waitUntilExit()
    }
}

struct DoctorCommand: ParsableCommand, PassphraseInput {
    static let configuration = CommandConfiguration(commandName: "doctor", abstract: "Inspect vault health")

    @Option(name: .long) var vault: String
    @Option(name: .long) var passphrase: String?
    @Flag(name: .long, help: "Read passphrase from stdin.") var passphraseStdin = false
    @Flag(name: .long) var fix = false

    func run() throws {
        let pass = try optionalPassphrase(prompt: "Enter vault passphrase (optional): ")
        let report = try Doctor.run(vaultURL: CLIHelpers.fileURL(vault), passphrase: pass, fix: fix)

        print("Header: \(report.headerOK ? "OK" : "BAD")")
        print("Manifest: \(report.manifestOK ? "OK" : "BAD")")
        print("Chunk area: \(report.chunkAreaOK ? "OK" : "BAD")")
        if let entries = report.entries {
            print("Entries: \(entries)")
        }
        if pass == nil || pass?.isEmpty == true {
            print("Note: passphrase not provided; deep chunk authentication and index hash checks were skipped.")
        }
        if !report.issues.isEmpty {
            print("Issues:")
            for issue in report.issues {
                print("- \(issue)")
            }
        }
        if report.fixed {
            print("Applied fix: re-signed manifest.")
        }
    }
}

struct LockCommand: ParsableCommand, PassphraseInput {
    static let configuration = CommandConfiguration(commandName: "lock", abstract: "Finalize staged sidecar entries")

    @Option(name: .long) var vault: String
    @Option(name: .long) var passphrase: String?
    @Flag(name: .long, help: "Read passphrase from stdin.") var passphraseStdin = false

    func run() throws {
        let pass = try requiredPassphrase(prompt: "Enter vault passphrase: ")
        let added = try Locker.lockFromSidecar(vaultURL: CLIHelpers.fileURL(vault), passphrase: pass)
        if added > 0 {
            print("Lock complete. Imported \(added) legacy staged item(s) from sidecar.")
        } else {
            print("Lock complete. No staged files found; imports are immediate.")
        }
    }
}

struct BackupCommand: ParsableCommand, PassphraseInput {
    static let configuration = CommandConfiguration(commandName: "backup", abstract: "Create a single-file backup archive")

    @Option(name: .long) var vault: String
    @Option(name: .long) var out: String
    @Option(name: .long) var passphrase: String?
    @Flag(name: .long, help: "Read passphrase from stdin.") var passphraseStdin = false

    func run() throws {
        let pass = try optionalPassphrase(prompt: "Enter vault passphrase (optional): ") ?? ""
        let v = try AegiroVault.open(at: CLIHelpers.fileURL(vault))
        try Backup.exportBackup(from: v, to: CLIHelpers.fileURL(out), passphrase: pass)
        print("Backup archive created at \(CLIHelpers.expandedPath(out)).")
    }
}

struct RestoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restore", abstract: "Restore vault bytes from a backup archive")

    @Option(name: .long) var backup: String
    @Option(name: .long) var out: String
    @Flag(name: .long, help: "Overwrite output vault when it already exists") var force = false

    func run() throws {
        let info = try Backup.restoreBackup(from: CLIHelpers.fileURL(backup),
                                            to: CLIHelpers.fileURL(out),
                                            overwrite: force)
        print("Restored vault to \(CLIHelpers.expandedPath(out)).")
        print("Backup created: \(CLIHelpers.formatTimestamp(info.metadata.createdAt))")
        print("Source vault SHA256: \(info.metadata.sourceVaultSHA256Hex)")
    }
}

struct ScanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "scan", abstract: "Scan file names and contents for privacy patterns")

    @Flag(name: .long, help: "Scan names only (skip file contents).") var namesOnly = false
    @Option(name: .long, help: "Maximum file size (bytes) to inspect for content patterns.") var maxFileBytes = 2_000_000
    @Argument(help: "Paths to scan") var paths: [String] = []

    func run() throws {
        guard !paths.isEmpty else {
            throw ValidationError("No paths provided to scan.")
        }
        guard maxFileBytes > 0 else {
            throw ValidationError("--max-file-bytes must be a positive integer.")
        }

        let options = PrivacyScanOptions(includeFileContents: !namesOnly,
                                         maxFileBytes: maxFileBytes)
        let matches = PrivacyMonitor.scan(paths: paths.map { CLIHelpers.expandedPath($0) },
                                          options: options)
        if matches.isEmpty {
            print("No privacy matches found.")
        }
        for match in matches {
            print("\(match.path)\t\(match.reason)")
        }
    }
}

struct ShredCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "shred", abstract: "Securely overwrite and remove files")

    @Argument(help: "Paths to shred") var paths: [String] = []

    func run() throws {
        guard !paths.isEmpty else {
            throw ValidationError("No paths provided to shred.")
        }
        for path in paths {
            try Shredder.shred(path: CLIHelpers.expandedPath(path))
            print("Shredded \(path)")
        }
    }
}

struct VerifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "verify", abstract: "Verify manifest signature")

    @Option(name: .long) var vault: String

    func run() throws {
        let manifest = try ManifestIO.load(from: CLIHelpers.fileURL(vault))
        let signer = Dilithium2()
        let ok = ManifestBuilder.verify(manifest, signer: signer)
        print(ok ? "Manifest signature: OK" : "Manifest signature: INVALID")
    }
}

struct StatusCommand: ParsableCommand, PassphraseInput {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show vault status")

    @Option(name: .long) var vault: String
    @Option(name: .long) var passphrase: String?
    @Flag(name: .long, help: "Read passphrase from stdin.") var passphraseStdin = false
    @Flag(name: .long) var json = false

    func run() throws {
        let pass = try optionalPassphrase(prompt: "Enter vault passphrase (optional): ")
        let info = try VaultStatus.get(vaultURL: CLIHelpers.fileURL(vault), passphrase: pass)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(info)
            print(String(data: data, encoding: .utf8) ?? "{}")
            return
        }

        print("Vault Info")
        print("File count: \(info.entries != nil ? String(info.entries!) : "unknown (locked)")")
        print("Vault size: \(CLIHelpers.formatBytes(info.vaultSizeBytes)) (\(info.vaultSizeBytes) bytes)")
        if let modified = info.vaultLastModified {
            print("Last edited: \(CLIHelpers.formatTimestamp(modified))")
        } else {
            print("Last edited: unknown")
        }
        print("")
        print("Status")
        print("Locked: \(info.locked ? "yes" : "no")")
        print("Sidecar pending: \(info.sidecarPending)")
        print("Manifest: \(info.manifestOK ? "OK" : "INVALID")")
        print("Touch ID: \(info.touchIDEnabled ? "enabled" : "disabled")")
    }
}

struct APFSVolumeEncryptCommand: ParsableCommand, PassphraseInput {
    static let configuration = CommandConfiguration(commandName: "apfs-volume-encrypt", abstract: "Encrypt APFS volume and write recovery bundle")

    @Option(name: .long) var disk: String
    @Option(name: .long) var passphrase: String?
    @Flag(name: .long, help: "Read passphrase from stdin.") var passphraseStdin = false
    @Option(name: .long) var recovery: String?
    @Flag(name: .long) var dryRun = false
    @Flag(name: .long) var force = false

    func run() throws {
        let pass = try requiredPassphrase(prompt: "Enter APFS recovery passphrase: ")
        let recoveryURL: URL
        if let recovery {
            recoveryURL = CLIHelpers.fileURL(recovery)
        } else {
            recoveryURL = CLIHelpers.defaultDiskRecoveryURL(diskIdentifier: disk)
        }

        let result = try ExternalDiskCrypto.encryptAPFSVolume(diskIdentifier: disk,
                                                              recoveryPassphrase: pass,
                                                              recoveryURL: recoveryURL,
                                                              dryRun: dryRun,
                                                              overwrite: force)
        if result.dryRun {
            print("Dry run: generated PQC recovery bundle without calling diskutil encrypt.")
        } else {
            print("Started APFS encryption for \(disk).")
        }
        print("PQC recovery bundle: \(result.recoveryURL.path)")
    }
}

struct APFSVolumeDecryptCommand: ParsableCommand, PassphraseInput {
    static let configuration = CommandConfiguration(commandName: "apfs-volume-decrypt", abstract: "Unlock APFS volume with recovery bundle")

    @Option(name: .long) var disk: String
    @Option(name: .long) var recovery: String
    @Option(name: .long) var passphrase: String?
    @Flag(name: .long, help: "Read passphrase from stdin.") var passphraseStdin = false
    @Flag(name: .long) var dryRun = false

    func run() throws {
        let pass = try requiredPassphrase(prompt: "Enter APFS recovery passphrase: ")
        try ExternalDiskCrypto.unlockAPFSVolume(diskIdentifier: disk,
                                                recoveryPassphrase: pass,
                                                recoveryURL: CLIHelpers.fileURL(recovery),
                                                dryRun: dryRun)
        if dryRun {
            print("Dry run: recovery bundle validated and PQC decapsulation succeeded.")
        } else {
            print("Unlock command sent for \(disk).")
        }
    }
}

struct USBContainerCreateCommand: ParsableCommand, PassphraseInput {
    static let configuration = CommandConfiguration(commandName: "usb-container-create", abstract: "Create encrypted APFS sparsebundle container")

    @Option(name: .long) var image: String
    @Option(name: .long) var size: String
    @Option(name: .long) var name: String = "Aegiro USB"
    @Option(name: .long) var passphrase: String?
    @Flag(name: .long, help: "Read passphrase from stdin.") var passphraseStdin = false
    @Option(name: .long) var recovery: String?
    @Option(name: .long) var containerPassphrase: String?
    @Flag(name: .long) var dryRun = false
    @Flag(name: .long) var force = false

    func run() throws {
        let recoveryPass = try requiredPassphrase(prompt: "Enter recovery passphrase: ")
        let imageURL = CLIHelpers.fileURL(image)
        let recoveryURL: URL
        if let recovery {
            recoveryURL = CLIHelpers.fileURL(recovery)
        } else {
            recoveryURL = CLIHelpers.defaultUSBContainerRecoveryURL(imageURL: imageURL)
        }

        let result = try USBContainerCrypto.createEncryptedContainer(imageURL: imageURL,
                                                                     size: size,
                                                                     volumeName: name,
                                                                     recoveryPassphrase: recoveryPass,
                                                                     recoveryURL: recoveryURL,
                                                                     overwrite: force,
                                                                     containerPassphrase: containerPassphrase,
                                                                     dryRun: dryRun)
        if result.dryRun {
            print("Dry run: validated encrypted USB container request and PQC recovery bundle creation.")
        } else {
            print("Created encrypted container image: \(result.imageURL.path)")
        }
        print("PQC recovery bundle: \(result.recoveryURL.path)")
    }
}

struct USBContainerOpenCommand: ParsableCommand, PassphraseInput {
    static let configuration = CommandConfiguration(commandName: "usb-container-open", abstract: "Open encrypted APFS sparsebundle container")

    @Option(name: .long) var image: String
    @Option(name: .long) var passphrase: String?
    @Flag(name: .long, help: "Read passphrase from stdin.") var passphraseStdin = false
    @Option(name: .long) var recovery: String?
    @Option(name: .long) var containerPassphrase: String?
    @Flag(name: .long) var dryRun = false

    func run() throws {
        let recoveryPass = try optionalPassphrase(prompt: "Enter recovery passphrase (optional): ") ?? ""
        if (containerPassphrase?.isEmpty ?? true) && recoveryPass.isEmpty {
            throw ValidationError("Provide --passphrase/--passphrase-stdin for recovery unlock, or --container-passphrase for direct mount.")
        }

        let imageURL = CLIHelpers.fileURL(image)
        let recoveryURL: URL
        if let recovery {
            recoveryURL = CLIHelpers.fileURL(recovery)
        } else {
            recoveryURL = CLIHelpers.defaultUSBContainerRecoveryURL(imageURL: imageURL)
        }

        let result = try USBContainerCrypto.mountEncryptedContainer(imageURL: imageURL,
                                                                    recoveryPassphrase: recoveryPass,
                                                                    recoveryURL: recoveryURL,
                                                                    containerPassphraseOverride: containerPassphrase,
                                                                    dryRun: dryRun)
        if result.dryRun {
            print("Dry run: validated encrypted USB container mount request.")
        } else {
            if let mountPoint = result.mountPoint {
                print("Mounted at: \(mountPoint)")
            } else {
                print("Mounted image (mount point unavailable from hdiutil output).")
            }
            if let device = result.deviceIdentifier {
                print("Device: \(device)")
            }
        }
    }
}

struct USBContainerCloseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "usb-container-close", abstract: "Unmount encrypted APFS sparsebundle container")

    @Option(name: .long) var target: String
    @Flag(name: .long) var force = false
    @Flag(name: .long) var dryRun = false

    func run() throws {
        try USBContainerCrypto.unmountContainer(target: target, force: force, dryRun: dryRun)
        if dryRun {
            print("Dry run: validated unmount target \(target).")
        } else {
            print("Unmounted \(target).")
        }
    }
}

struct USBVaultPackCommand: ParsableCommand, PassphraseInput {
    static let configuration = CommandConfiguration(commandName: "usb-vault-pack", abstract: "Encrypt non-APFS USB/user files into AGVT vault")

    @Option(name: .long) var source: String
    @Option(name: .long) var vault: String
    @Option(name: .long) var passphrase: String?
    @Flag(name: .long, help: "Read passphrase from stdin.") var passphraseStdin = false
    @Flag(name: .long) var dryRun = false
    @Flag(name: .long) var deleteOriginals = false

    func run() throws {
        if dryRun && deleteOriginals {
            throw ValidationError("--delete-originals cannot be used with --dry-run.")
        }

        let sourceURL = CLIHelpers.fileURL(source, directory: true).standardizedFileURL
        let vaultURL = CLIHelpers.fileURL(vault).standardizedFileURL
        let pass: String
        if dryRun {
            pass = (try optionalPassphrase(prompt: "Enter vault passphrase (optional): ") ?? "")
        } else {
            pass = try requiredPassphrase(prompt: "Enter vault passphrase: ")
        }

        let result = try USBUserDataCrypto.encryptUserFiles(sourceRootURL: sourceURL,
                                                            vaultURL: vaultURL,
                                                            passphrase: pass,
                                                            deleteOriginals: deleteOriginals,
                                                            dryRun: dryRun) { progress in
            print("[\(progress.stage.rawValue)] \(progress.message)")
        }

        if result.dryRun {
            print("Scan complete: \(result.scannedFileCount) user file(s), \(result.skippedPathCount) skipped system path(s).")
        } else {
            print("Encrypted \(result.encryptedFileCount) user file(s) into \(result.vaultURL.path).")
            if result.createdVault {
                print("Created vault file: \(result.vaultURL.path)")
            }
            if deleteOriginals {
                print("Deleted \(result.deletedOriginalCount) original file(s).")
                if !result.deletionErrors.isEmpty {
                    print("Deletion errors:")
                    for error in result.deletionErrors {
                        print("- \(error)")
                    }
                }
            }
        }
    }
}

struct AegiroRootCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "aegiro-cli",
        abstract: "Local-only encrypted vault for macOS.",
        discussion: """
Limits:
  Max files per vault: \(VaultLimits.defaultMaxFilesPerVault) by default.
  Override: set AEGIRO_MAX_FILES_PER_VAULT=<positive-int>.

Performance tips:
  Batch files in one import run: import --vault <path> --passphrase "<pass>" <files...>
  For whole folders, use: usb-vault-pack --source <folder> --vault <path.agvt> ...
  Avoid repeated single-file imports; each run rewrites vault metadata/chunk map.
  Export preserves logical paths under --out by default to avoid duplicate-name collisions.
""",
        version: """
Aegiro CLI v\(AEGIRO_CLI_VERSION)
Commit: \(AEGIRO_BUILD_COMMIT)
Built: \(AEGIRO_BUILD_DATE)
""",
        subcommands: [
            VersionCommand.self,
            CreateCommand.self,
            ImportCommand.self,
            DeleteCommand.self,
            LockCommand.self,
            UnlockCommand.self,
            ListCommand.self,
            ExportCommand.self,
            PreviewCommand.self,
            DoctorCommand.self,
            BackupCommand.self,
            RestoreCommand.self,
            ScanCommand.self,
            ShredCommand.self,
            VerifyCommand.self,
            StatusCommand.self,
            APFSVolumeEncryptCommand.self,
            APFSVolumeDecryptCommand.self,
            USBContainerCreateCommand.self,
            USBContainerOpenCommand.self,
            USBContainerCloseCommand.self,
            USBVaultPackCommand.self
        ]
    )
}

do {
    var command = try AegiroRootCommand.parseAsRoot()
    try command.run()
} catch {
    AegiroRootCommand.exit(withError: error)
}
