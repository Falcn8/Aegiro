import Foundation
import AppKit
import UniformTypeIdentifiers
import AegiroCore

func defaultVaultDirectoryURL() -> URL {
    let documents = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents", isDirectory: true)
    return documents.appendingPathComponent("Aegiro Vaults", isDirectory: true)
}

func legacyDefaultVaultDirectoryURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AegiroVaults", isDirectory: true)
}

func defaultVaultURL() -> URL {
    let base = UserDefaults.standard.string(forKey: "defaultVaultDir")
        .flatMap { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? defaultVaultDirectoryURL()
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base.appendingPathComponent("alpha.agvt")
}

extension VaultModel {
    func openVaultWithPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Vault (AegiroVault)"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let allowedTypes = Self.supportedVaultExtensions
            .sorted()
            .compactMap { UTType(filenameExtension: $0, conformingTo: .data) }
        guard !allowedTypes.isEmpty else {
            self.status = "Open failed: supported vault file types are unavailable"
            return
        }
        panel.allowedContentTypes = allowedTypes
        if panel.runModal() == .OK, let url = panel.url {
            openVault(at: url)
        }
    }

    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(defaultVaultDir.path, forKey: "defaultVaultDir")
        defaults.set(autoLockTTL, forKey: "autoLockTTL")
        status = "Preferences saved"
    }

    func exportBackup(vaultURL: URL,
                      outURL: URL,
                      passphrase: String,
                      completion: ((Result<Void, Error>) -> Void)? = nil) {
        status = "Exporting backup..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let vault = try AegiroVault.open(at: vaultURL)
                try Backup.exportBackup(from: vault, to: outURL, passphrase: passphrase)
                DispatchQueue.main.async {
                    self?.status = "Backup archive created at \(outURL.path)."
                    completion?(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    self?.status = "Backup failed: \(Self.formattedError(error))"
                    completion?(.failure(error))
                }
            }
        }
    }

    func restoreBackup(backupURL: URL,
                       outURL: URL,
                       overwrite: Bool,
                       completion: ((Result<BackupArchiveInfo, Error>) -> Void)? = nil) {
        status = "Restoring backup..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let info = try Backup.restoreBackup(from: backupURL, to: outURL, overwrite: overwrite)
                DispatchQueue.main.async {
                    self?.status = "Backup restored to \(outURL.path)."
                    completion?(.success(info))
                }
            } catch {
                DispatchQueue.main.async {
                    self?.status = Self.formattedError(error)
                    completion?(.failure(error))
                }
            }
        }
    }

    func verifyManifest(vaultURL: URL,
                        completion: ((Result<Bool, Error>) -> Void)? = nil) {
        status = "Verifying manifest signature..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let manifest = try ManifestIO.load(from: vaultURL)
                let signer = Dilithium2()
                let ok = ManifestBuilder.verify(manifest, signer: signer)
                DispatchQueue.main.async {
                    self?.status = ok ? "Manifest signature: OK" : "Manifest signature: INVALID"
                    completion?(.success(ok))
                }
            } catch {
                DispatchQueue.main.async {
                    self?.status = "Verify failed: \(Self.formattedError(error))"
                    completion?(.failure(error))
                }
            }
        }
    }

    func renderVaultStatus(vaultURL: URL,
                           passphrase: String?,
                           asJSON: Bool,
                           completion: ((Result<String, Error>) -> Void)? = nil) {
        status = "Loading vault status..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let trimmed = passphrase?.trimmingCharacters(in: .whitespacesAndNewlines)
                let info = try VaultStatus.get(vaultURL: vaultURL, passphrase: (trimmed?.isEmpty ?? true) ? nil : trimmed)
                let output = try Self.makeStatusOutput(info: info, asJSON: asJSON)
                DispatchQueue.main.async {
                    self?.status = "Status loaded."
                    completion?(.success(output))
                }
            } catch {
                DispatchQueue.main.async {
                    self?.status = "Status failed: \(Self.formattedError(error))"
                    completion?(.failure(error))
                }
            }
        }
    }

    func scanPrivacy(paths: [String],
                     completion: (([PrivacyMatch]) -> Void)? = nil) {
        let expanded = paths
            .map { NSString(string: $0).expandingTildeInPath }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !expanded.isEmpty else {
            status = "Select at least one path to scan"
            completion?([])
            return
        }

        status = "Scanning \(expanded.count) path(s)..."
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let matches = PrivacyMonitor.scan(paths: expanded)
            DispatchQueue.main.async {
                self?.status = matches.isEmpty
                    ? "Scan complete: no privacy pattern matches."
                    : "Scan complete: \(matches.count) potential privacy match(es)."
                completion?(matches)
            }
        }
    }

    func shred(paths: [String],
               completion: ((Result<[String], Error>) -> Void)? = nil) {
        let expanded = paths
            .map { NSString(string: $0).expandingTildeInPath }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !expanded.isEmpty else {
            status = "Select at least one file to shred"
            completion?(.success([]))
            return
        }

        status = "Shredding \(expanded.count) file(s)..."
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                var shredded: [String] = []
                for path in expanded {
                    try Shredder.shred(path: path)
                    shredded.append(path)
                }
                DispatchQueue.main.async {
                    self?.status = "Shredded \(shredded.count) file(s)."
                    completion?(.success(shredded))
                }
            } catch {
                DispatchQueue.main.async {
                    self?.status = "Shred failed: \(Self.formattedError(error))"
                    completion?(.failure(error))
                }
            }
        }
    }

    nonisolated private static func makeStatusOutput(info: VaultStatusInfo, asJSON: Bool) throws -> String {
        if asJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(info)
            return String(data: data, encoding: .utf8) ?? "{}"
        }

        var lines: [String] = []
        lines.append("Vault Info")
        lines.append("File count: \(info.entries != nil ? String(info.entries!) : "unknown (locked)")")
        lines.append("Vault size: \(formatByteCount(info.vaultSizeBytes)) (\(info.vaultSizeBytes) bytes)")
        if let modified = info.vaultLastModified {
            lines.append("Last edited: \(formatTimestamp(modified))")
        } else {
            lines.append("Last edited: unknown")
        }
        lines.append("")
        lines.append("Status")
        lines.append("Locked: \(info.locked ? "yes" : "no")")
        lines.append("Sidecar pending: \(info.sidecarPending)")
        lines.append("Manifest: \(info.manifestOK ? "OK" : "INVALID")")
        return lines.joined(separator: "\n")
    }

    nonisolated private static func formatByteCount(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    nonisolated private static func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}
