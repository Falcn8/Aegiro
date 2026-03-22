import Foundation
import SwiftUI
import AppKit
import AegiroCore
import UniformTypeIdentifiers

private final class USBDataEncryptionCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func isCancelled() -> Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }
}

struct USBDataEncryptionLogEntry: Identifiable, Sendable {
    let id: Int
    let timestamp: Date
    let message: String
}

@MainActor
final class VaultModel: ObservableObject {
    private static let supportedVaultExtensions: Set<String> = ["agvt", "aegirovault"]

    @Published var vaultURL: URL?
    @Published var locked: Bool = true
    @Published var entries: [VaultIndexEntry] = []
    @Published var vaultFileCount: Int?
    @Published var vaultSizeBytes: UInt64 = 0
    @Published var vaultLastEdited: Date?
    @Published var sidecarPending: Int = 0
    @Published var manifestOK: Bool = false
    @Published var status: String = ""
    @Published var passphrase: String = ""
    @Published var defaultVaultDir: URL
    @Published var autoLockTTL: Int
    @Published var apfsVolumeOptions: [APFSVolumeOption] = []
    @Published var mountedNonAPFSVolumes: [MountedNonAPFSVolume] = []
    @Published var apfsVolumeOptionsLoading: Bool = false
    @Published var apfsVolumeOptionsError: String?
    @Published var diskEncryptionMonitoringDiskIdentifier: String?
    @Published var diskEncryptionMonitoringActive: Bool = false
    @Published var diskEncryptionProgressFraction: Double?
    @Published var diskEncryptionProgressMessage: String = ""
    @Published var usbDataEncryptionTargetMountPoint: String?
    @Published var usbDataEncryptionActive: Bool = false
    @Published var usbDataEncryptionProgressFraction: Double?
    @Published var usbDataEncryptionProgressMessage: String = ""
    @Published var usbDataEncryptionProcessedFiles: Int = 0
    @Published var usbDataEncryptionTotalFiles: Int = 0
    @Published var usbDataEncryptionStage: USBUserDataEncryptProgress.Stage = .completed
    @Published var usbDataEncryptionLogs: [USBDataEncryptionLogEntry] = []
    @Published var usbDataEncryptionLastResult: USBUserDataEncryptResult?
    @Published var vaultEntriesLoading: Bool = false
    @Published var vaultEntriesPageLoading: Bool = false
    @Published var vaultEntriesHasMore: Bool = false
    @Published var autoLockRemaining: TimeInterval = 0
    private var timer: Timer?
    private var diskEncryptionProgressTimer: Timer?
    private var lastActivity: Date = .now
    private var globalMonitors: [Any] = []
    private var localMonitors: [Any] = []
    private var autoLockDeadline: Date?
    private var usbDataEncryptionCancellationFlag: USBDataEncryptionCancellationFlag?
    private var usbDataEncryptionLogSequence: Int = 0
    private var entriesLoadGeneration: Int = 0
    private var vaultEntriesActiveRevisionKey: String?
    private var vaultEntriesNextOffset: Int = 0
    private var cachedStatusRevisionKey: String?
    private var cachedStatusInfo: VaultStatusInfo?
    private let vaultEntriesPageSize: Int = 300

    init() {
        let defaults = UserDefaults.standard
        if let p = defaults.string(forKey: "defaultVaultDir"), !p.isEmpty {
            let configured = URL(fileURLWithPath: p, isDirectory: true).standardizedFileURL
            let legacy = legacyDefaultVaultDirectoryURL().standardizedFileURL.path
            if configured.path == legacy {
                let migrated = defaultVaultDirectoryURL()
                self.defaultVaultDir = migrated
                defaults.set(migrated.path, forKey: "defaultVaultDir")
            } else {
                self.defaultVaultDir = configured
            }
        } else {
            self.defaultVaultDir = defaultVaultDirectoryURL()
        }
        let ttl = defaults.integer(forKey: "autoLockTTL")
        self.autoLockTTL = ttl > 0 ? ttl : 300
    }

    func createVault(at url: URL, passphrase: String) {
        do {
            let v = try AegiroVault.create(at: url, passphrase: passphrase, touchID: false)
            self.vaultURL = v.url
            self.passphrase = passphrase
            self.locked = false
            self.status = "Vault created"
            UserDefaults.standard.set(v.url.path, forKey: "lastVaultPath")
            UserDefaults.standard.set(true, forKey: "onboardingCompleted")
            self.refreshStatus()
        } catch {
            self.status = "Create failed: \(error)"
        }
    }

    func openVault(at url: URL) {
        let normalizedURL = url.standardizedFileURL
        guard Self.supportedVaultExtensions.contains(normalizedURL.pathExtension.lowercased()) else {
            self.status = "Open failed: only .agvt or .aegirovault files are supported"
            return
        }
        do {
            _ = try AegiroVault.open(at: normalizedURL)
            self.vaultURL = normalizedURL
            self.passphrase = ""
            self.locked = true
            self.entries = []
            self.vaultFileCount = nil
            self.vaultEntriesHasMore = false
            UserDefaults.standard.set(normalizedURL.path, forKey: "lastVaultPath")
            UserDefaults.standard.set(true, forKey: "onboardingCompleted")
            self.status = "Vault loaded"
            self.refreshStatus()
        } catch {
            self.status = "Open failed: \(error)"
        }
    }

    func refreshStatus() {
        touchActivity()
        guard let url = vaultURL else { return }
        do {
            let statusRevisionKey = makeStatusRevisionKey(vaultURL: url)
            let info: VaultStatusInfo
            if let statusRevisionKey,
               cachedStatusRevisionKey == statusRevisionKey,
               let cachedStatusInfo {
                info = cachedStatusInfo
            } else {
                info = try VaultStatus.get(vaultURL: url, passphrase: nil)
                cachedStatusInfo = info
                cachedStatusRevisionKey = statusRevisionKey
            }
            if passphrase.isEmpty {
                self.locked = true
            }
            self.vaultSizeBytes = info.vaultSizeBytes
            self.vaultLastEdited = info.vaultLastModified
            self.sidecarPending = info.sidecarPending
            self.manifestOK = info.manifestOK
            if !self.locked, !passphrase.isEmpty {
                let revisionKey = makeEntriesRevisionKey(vaultURL: url, vaultLastModified: info.vaultLastModified)
                if vaultEntriesActiveRevisionKey != revisionKey || vaultFileCount == nil {
                    requestVaultEntriesRefresh(vaultURL: url, passphrase: passphrase, revisionKey: revisionKey)
                }
                if autoLockDeadline == nil {
                    resetAutoLockDeadline()
                } else {
                    updateAutoLockRemaining()
                }
            } else {
                invalidateVaultEntriesRefresh()
                self.entries = []
                self.vaultFileCount = nil
                self.vaultEntriesHasMore = false
                autoLockDeadline = nil
                autoLockRemaining = 0
            }
        } catch {
            invalidateVaultEntriesRefresh()
            cachedStatusInfo = nil
            cachedStatusRevisionKey = nil
            self.status = "Status failed: \(error)"
        }
    }

    func reloadVaultEntriesNow() {
        touchActivity()
        guard let url = vaultURL?.standardizedFileURL else { return }
        let trimmedPass = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !locked, !trimmedPass.isEmpty else {
            status = "Unlock with your passphrase to reload vault files"
            return
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attrs?[.modificationDate] as? Date
        let revisionKey = makeEntriesRevisionKey(vaultURL: url, vaultLastModified: modified) + "|manual:\(UUID().uuidString)"
        status = "Reloading vault files..."
        requestVaultEntriesRefresh(vaultURL: url, passphrase: trimmedPass, revisionKey: revisionKey)
    }

    func unlock(with pass: String) {
        touchActivity()
        guard let url = vaultURL else { return }
        let normalizedVaultURL = url.standardizedFileURL
        let trimmedPass = pass.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPass.isEmpty else {
            status = "Enter a passphrase"
            return
        }

        entriesLoadGeneration += 1
        let generation = entriesLoadGeneration
        status = "Unlocking..."
        vaultEntriesLoading = true
        vaultEntriesPageLoading = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try Exporter.listPage(vaultURL: normalizedVaultURL,
                                      passphrase: trimmedPass,
                                      offset: 0,
                                      limit: self?.vaultEntriesPageSize ?? 300)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.entriesLoadGeneration == generation else { return }
                self.vaultEntriesLoading = false

                guard self.vaultURL?.standardizedFileURL.path == normalizedVaultURL.path else { return }

                switch result {
                case .success(let page):
                    let attrs = try? FileManager.default.attributesOfItem(atPath: normalizedVaultURL.path)
                    let modified = attrs?[.modificationDate] as? Date
                    let revisionKey = self.makeEntriesRevisionKey(vaultURL: normalizedVaultURL, vaultLastModified: modified)
                    self.passphrase = trimmedPass
                    self.locked = false
                    self.entries = page.entries
                    self.vaultFileCount = page.totalCount
                    self.vaultEntriesActiveRevisionKey = revisionKey
                    self.vaultEntriesNextOffset = page.nextOffset
                    self.vaultEntriesHasMore = page.hasMore
                    self.status = "Unlocked"
                    self.refreshStatus()
                case .failure(let error):
                    self.entries = []
                    self.vaultFileCount = nil
                    self.vaultEntriesHasMore = false
                    self.status = "Unlock failed: \(error)"
                }
            }
        }
    }

    func lockNow() {
        touchActivity()
        guard let url = vaultURL else { return }
        do {
            let added = try Locker.lockFromSidecar(vaultURL: url, passphrase: passphrase)
            lockSession()
            if added > 0 {
                self.status = "Locked. Imported \(added) legacy staged item(s)"
            } else {
                self.status = "Locked"
            }
            self.refreshStatus()
        } catch {
            self.status = "Lock failed: \(error)"
        }
    }

    func importFiles() {
        touchActivity()
        guard let url = vaultURL else { return }
        guard !locked else {
            status = "Unlock to import files"
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            do {
                let (imported, _) = try Importer.sidecarImport(vaultURL: url, passphrase: passphrase, files: panel.urls)
                self.status = imported == 0 ? "No files imported" : "Imported \(imported) file(s) into encrypted vault"
                self.refreshStatus()
            } catch {
                self.status = "Import failed: \(error)"
            }
        }
    }

    func importFiles(urls: [URL]) {
        touchActivity()
        guard let vaultURL else { return }
        guard !locked else {
            status = "Unlock to import files"
            return
        }

        let readableFiles = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !readableFiles.isEmpty else {
            status = "No readable files were dropped"
            return
        }

        do {
            let (imported, _) = try Importer.sidecarImport(vaultURL: vaultURL, passphrase: passphrase, files: readableFiles)
            status = imported == 0 ? "No files imported" : "Imported \(imported) file(s) into encrypted vault"
            refreshStatus()
        } catch {
            status = "Import failed: \(error)"
        }
    }

    func exportSelected(to dir: URL, filters: [String] = []) {
        touchActivity()
        guard let url = vaultURL else { return }
        guard !locked else {
            status = "Unlock to export files"
            return
        }
        do {
            let res = try Exporter.export(vaultURL: url, passphrase: passphrase, filters: filters, outDir: dir)
            self.status = res.isEmpty ? "Nothing exported" : "Exported \(res.count) file(s)"
        } catch {
            self.status = "Export failed: \(error)"
        }
    }

    func exportSelectedWithPanel(filter: String? = nil) {
        touchActivity()
        guard !locked else {
            status = "Unlock to export files"
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let dir = panel.url {
            exportSelected(to: dir, filters: filter.map { [$0] } ?? [])
        }
    }

    func exportSelectedWithPanel(filters: [String]) {
        touchActivity()
        guard !locked else {
            status = "Unlock to export files"
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let dir = panel.url {
            exportSelected(to: dir, filters: filters)
        }
    }

    func deleteEntries(logicalPaths: [String]) {
        touchActivity()
        guard let vaultURL else { return }
        guard !locked else {
            status = "Unlock to delete files"
            return
        }
        guard !passphrase.isEmpty else {
            status = "Unlock with your passphrase to delete files"
            return
        }

        let targets = Array(Set(logicalPaths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        guard !targets.isEmpty else {
            status = "No files selected for deletion"
            return
        }

        do {
            let removed = try Editor.deleteEntries(vaultURL: vaultURL, passphrase: passphrase, logicalPaths: targets)
            if removed == 0 {
                status = "No matching files found to delete"
            } else {
                status = "Deleted \(removed) file(s)"
            }
            refreshStatus()
        } catch {
            status = "Delete failed: \(error)"
        }
    }

    func preview(logicalPath: String) {
        guard let url = vaultURL else { return }
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        do {
            let results = try Exporter.export(vaultURL: url, passphrase: passphrase, filters: [logicalPath], outDir: tmpDir)
            guard let out = results.first?.1 else {
                status = "Preview failed: no file exported"
                return
            }
            NSWorkspace.shared.open(out)
        } catch {
            self.status = "Preview failed: \(error)"
        }
    }

    func revealExport(logicalPath: String) {
        guard let url = vaultURL else { return }
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        do {
            let results = try Exporter.export(vaultURL: url, passphrase: passphrase, filters: [logicalPath], outDir: tmpDir)
            guard let out = results.first?.1 else {
                status = "Reveal failed: no file exported"
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([out])
        } catch {
            self.status = "Reveal failed: \(error)"
        }
    }

    func copyPathToClipboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        status = "Copied path"
    }

    func revealOriginal(logicalPath: String) {
        let p = URL(fileURLWithPath: logicalPath)
        if FileManager.default.fileExists(atPath: p.path) {
            NSWorkspace.shared.activateFileViewerSelecting([p])
        } else {
            status = "Original file not found; use Export or Preview instead"
        }
    }

    func refreshAPFSVolumeOptions() {
        if apfsVolumeOptionsLoading {
            return
        }
        apfsVolumeOptionsLoading = true
        apfsVolumeOptionsError = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                (
                    try ExternalDiskCrypto.listAPFSVolumes(),
                    try ExternalDiskCrypto.listMountedNonAPFSVolumes()
                )
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.apfsVolumeOptionsLoading = false
                switch result {
                case .success(let (options, nonAPFS)):
                    self.apfsVolumeOptions = options
                    self.mountedNonAPFSVolumes = nonAPFS
                    self.apfsVolumeOptionsError = nil
                case .failure(let error):
                    self.apfsVolumeOptions = []
                    self.mountedNonAPFSVolumes = []
                    self.apfsVolumeOptionsError = String(describing: error)
                }
            }
        }
    }

    func encryptExternalDisk(diskIdentifier: String,
                             recoveryPassphrase: String,
                             recoveryURL: URL,
                             dryRun: Bool,
                             overwrite: Bool) {
        let disk = diskIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = recoveryPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !disk.isEmpty else {
            status = "Enter an APFS disk identifier (for example, disk9s1)"
            return
        }
        guard !pass.isEmpty else {
            status = "Enter a recovery passphrase"
            return
        }

        status = dryRun ? "Generating PQC recovery bundle for \(disk)..." : "Starting encryption for \(disk)..."
        if !dryRun {
            startDiskEncryptionProgressMonitoring(diskIdentifier: disk)
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try ExternalDiskCrypto.encryptAPFSVolume(diskIdentifier: disk,
                                                                      recoveryPassphrase: pass,
                                                                      recoveryURL: recoveryURL,
                                                                      dryRun: dryRun,
                                                                      overwrite: overwrite)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if result.dryRun {
                        self.status = "Dry run complete. Bundle: \(result.recoveryURL.path)"
                    } else {
                        self.status = "Disk encryption started for \(result.diskIdentifier). Bundle: \(result.recoveryURL.path)"
                        self.startDiskEncryptionProgressMonitoring(diskIdentifier: result.diskIdentifier)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.stopDiskEncryptionProgressMonitoring()
                    self?.status = "Disk encrypt failed: \(error)"
                }
            }
        }
    }

    func unlockExternalDisk(diskIdentifier: String,
                            recoveryPassphrase: String,
                            recoveryURL: URL,
                            dryRun: Bool) {
        let disk = diskIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = recoveryPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !disk.isEmpty else {
            status = "Enter an APFS disk identifier (for example, disk9s1)"
            return
        }
        guard !pass.isEmpty else {
            status = "Enter the recovery passphrase"
            return
        }

        status = dryRun ? "Validating PQC bundle for \(disk)..." : "Decrypting (unlocking) \(disk)..."
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try ExternalDiskCrypto.unlockAPFSVolume(diskIdentifier: disk,
                                                        recoveryPassphrase: pass,
                                                        recoveryURL: recoveryURL,
                                                        dryRun: dryRun)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if dryRun {
                        self.status = "Dry run complete. PQC decapsulation succeeded for \(disk)."
                    } else {
                        self.status = "Decrypt/unlock command sent for \(disk)."
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.status = "Disk decrypt/unlock failed: \(error)"
                }
            }
        }
    }

    func stopDiskEncryptionProgressMonitoring() {
        diskEncryptionProgressTimer?.invalidate()
        diskEncryptionProgressTimer = nil
        diskEncryptionMonitoringActive = false
    }

    func clearUSBDataEncryptionProgressIfIdle() {
        guard !usbDataEncryptionActive else { return }
        usbDataEncryptionTargetMountPoint = nil
        usbDataEncryptionProgressFraction = nil
        usbDataEncryptionProgressMessage = ""
        usbDataEncryptionProcessedFiles = 0
        usbDataEncryptionTotalFiles = 0
        usbDataEncryptionStage = .completed
        usbDataEncryptionCancellationFlag = nil
        usbDataEncryptionLastResult = nil
    }

    func clearUSBDataEncryptionLogs() {
        usbDataEncryptionLogs = []
    }

    func cancelUSBDataEncryption() {
        guard usbDataEncryptionActive else { return }
        usbDataEncryptionCancellationFlag?.cancel()
        usbDataEncryptionActive = false
        usbDataEncryptionStage = .completed
        usbDataEncryptionProgressFraction = nil
        usbDataEncryptionProgressMessage = "Cancellation requested. Stopping current operation..."
        appendUSBDataEncryptionLog("Cancellation requested by user.")
        status = "Cancelling USB user-data encryption and cleaning partial output..."
        usbDataEncryptionLastResult = nil
    }

    private func appendUSBDataEncryptionLog(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if usbDataEncryptionLogs.last?.message == trimmed {
            return
        }
        usbDataEncryptionLogSequence += 1
        usbDataEncryptionLogs.append(USBDataEncryptionLogEntry(id: usbDataEncryptionLogSequence,
                                                               timestamp: Date(),
                                                               message: trimmed))
        if usbDataEncryptionLogs.count > 4_000 {
            usbDataEncryptionLogs.removeFirst(usbDataEncryptionLogs.count - 4_000)
        }
    }

    private func invalidateVaultEntriesRefresh() {
        entriesLoadGeneration += 1
        vaultEntriesLoading = false
        vaultEntriesPageLoading = false
        vaultEntriesHasMore = false
        vaultEntriesNextOffset = 0
        vaultEntriesActiveRevisionKey = nil
    }

    private func makeEntriesRevisionKey(vaultURL: URL, vaultLastModified: Date?) -> String {
        let modifiedEpoch = vaultLastModified?.timeIntervalSince1970 ?? 0
        return "\(vaultURL.standardizedFileURL.path)|\(modifiedEpoch)"
    }

    private func makeStatusRevisionKey(vaultURL: URL) -> String? {
        let fm = FileManager.default
        let normalizedVaultURL = vaultURL.standardizedFileURL
        guard let vaultAttrs = try? fm.attributesOfItem(atPath: normalizedVaultURL.path) else {
            return nil
        }
        let vaultSize = (vaultAttrs[.size] as? NSNumber)?.uint64Value ?? 0
        let vaultMod = (vaultAttrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        let sidecarIndexURL = normalizedVaultURL
            .deletingPathExtension()
            .appendingPathExtension("aegirofiles")
            .appendingPathComponent("index.json")
        let sidecarStamp: String
        if let sidecarAttrs = try? fm.attributesOfItem(atPath: sidecarIndexURL.path) {
            let sidecarSize = (sidecarAttrs[.size] as? NSNumber)?.uint64Value ?? 0
            let sidecarMod = (sidecarAttrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            sidecarStamp = "\(sidecarSize)|\(sidecarMod)"
        } else {
            sidecarStamp = "none"
        }

        return "\(normalizedVaultURL.path)|\(vaultSize)|\(vaultMod)|\(sidecarStamp)"
    }

    private func requestVaultEntriesRefresh(vaultURL: URL, passphrase: String, revisionKey: String) {
        entriesLoadGeneration += 1
        let generation = entriesLoadGeneration
        let normalizedVaultURL = vaultURL.standardizedFileURL
        vaultEntriesActiveRevisionKey = revisionKey
        vaultEntriesNextOffset = 0
        vaultEntriesHasMore = false
        vaultEntriesLoading = true
        vaultEntriesPageLoading = false
        entries = []
        vaultFileCount = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try Exporter.listPage(vaultURL: normalizedVaultURL,
                                      passphrase: passphrase,
                                      offset: 0,
                                      limit: self?.vaultEntriesPageSize ?? 300)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.entriesLoadGeneration == generation else { return }
                self.vaultEntriesLoading = false

                guard self.vaultURL?.standardizedFileURL.path == normalizedVaultURL.path else { return }
                guard !self.locked, self.passphrase == passphrase else { return }

                switch result {
                case .success(let page):
                    self.entries = page.entries
                    self.vaultFileCount = page.totalCount
                    self.vaultEntriesNextOffset = page.nextOffset
                    self.vaultEntriesHasMore = page.hasMore
                case .failure(let error):
                    self.entries = []
                    self.vaultFileCount = nil
                    self.vaultEntriesHasMore = false
                    self.status = "List failed: \(error)"
                }
            }
        }
    }

    func loadNextVaultEntriesPageIfNeeded() {
        guard !locked, !passphrase.isEmpty, !vaultEntriesLoading, !vaultEntriesPageLoading, vaultEntriesHasMore else { return }
        loadNextVaultEntriesPage(continueUntilComplete: false)
    }

    func loadRemainingVaultEntriesInBackground() {
        guard !locked, !passphrase.isEmpty, !vaultEntriesLoading, vaultEntriesHasMore else { return }
        loadNextVaultEntriesPage(continueUntilComplete: true)
    }

    private func loadNextVaultEntriesPage(continueUntilComplete: Bool) {
        guard !vaultEntriesPageLoading else { return }
        guard let vaultURL, let revisionKey = vaultEntriesActiveRevisionKey else { return }
        let normalizedVaultURL = vaultURL.standardizedFileURL
        let generation = entriesLoadGeneration
        let offset = vaultEntriesNextOffset
        let pass = passphrase

        vaultEntriesPageLoading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try Exporter.listPage(vaultURL: normalizedVaultURL,
                                      passphrase: pass,
                                      offset: offset,
                                      limit: self?.vaultEntriesPageSize ?? 300)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.entriesLoadGeneration == generation else { return }
                self.vaultEntriesPageLoading = false

                guard self.vaultURL?.standardizedFileURL.path == normalizedVaultURL.path else { return }
                guard !self.locked, self.passphrase == pass else { return }
                guard self.vaultEntriesActiveRevisionKey == revisionKey else { return }

                switch result {
                case .success(let page):
                    if page.entries.isEmpty {
                        self.vaultEntriesHasMore = false
                        self.vaultEntriesNextOffset = page.nextOffset
                        return
                    }
                    self.entries.append(contentsOf: page.entries)
                    self.vaultFileCount = page.totalCount
                    self.vaultEntriesNextOffset = page.nextOffset
                    self.vaultEntriesHasMore = page.hasMore
                    if continueUntilComplete && page.hasMore {
                        self.loadNextVaultEntriesPage(continueUntilComplete: true)
                    }
                case .failure(let error):
                    self.vaultEntriesHasMore = false
                    self.status = "List page failed: \(error)"
                }
            }
        }
    }

    private func mergedUSBDataEncryptionStage(for stage: USBUserDataEncryptProgress.Stage) -> USBUserDataEncryptProgress.Stage {
        switch stage {
        case .scanning, .preparing:
            return .scanning
        default:
            return stage
        }
    }

    private func mergedUSBDataEncryptionMessage(for progress: USBUserDataEncryptProgress) -> String {
        switch progress.stage {
        case .scanning, .preparing:
            if progress.totalFileCount > 0 {
                if progress.processedFileCount > 0, let path = progress.currentPath {
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    return "Analyzing \(progress.processedFileCount)/\(progress.totalFileCount): \(name)"
                }
                if progress.processedFileCount > 0 {
                    return "Analyzing \(progress.processedFileCount)/\(progress.totalFileCount) files..."
                }
                return "Analyzing \(progress.totalFileCount) files..."
            }
            if progress.processedFileCount > 0 {
                if let path = progress.currentPath {
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    return "Analyzing... found \(progress.processedFileCount) file(s). Latest: \(name)"
                }
                return "Analyzing... found \(progress.processedFileCount) file(s)."
            }
            return "Analyzing source files..."
        default:
            return progress.message
        }
    }
    private func startDiskEncryptionProgressMonitoring(diskIdentifier: String) {
        let trimmed = diskIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        diskEncryptionProgressTimer?.invalidate()
        diskEncryptionProgressTimer = nil
        diskEncryptionMonitoringDiskIdentifier = trimmed
        diskEncryptionMonitoringActive = true
        diskEncryptionProgressFraction = nil
        diskEncryptionProgressMessage = "Waiting for encryption progress..."

        pollDiskEncryptionProgress(for: trimmed)
        diskEncryptionProgressTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollDiskEncryptionProgress(for: trimmed)
            }
        }
    }

    private func pollDiskEncryptionProgress(for diskIdentifier: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result {
                try ExternalDiskCrypto.encryptionProgress(diskIdentifier: diskIdentifier)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.diskEncryptionMonitoringDiskIdentifier == diskIdentifier else { return }

                switch result {
                case .success(let progress):
                    self.diskEncryptionProgressFraction = progress.percentComplete
                    self.diskEncryptionProgressMessage = progress.message
                    if progress.encrypted && !progress.migrationActive {
                        self.diskEncryptionProgressFraction = max(self.diskEncryptionProgressFraction ?? 0, 1.0)
                        self.diskEncryptionProgressMessage = "Disk encryption complete."
                        self.stopDiskEncryptionProgressMonitoring()
                        self.refreshAPFSVolumeOptions()
                    }
                case .failure(let error):
                    self.diskEncryptionProgressMessage = "Progress unavailable: \(error)"
                }
            }
        }
    }

    func encryptNonAPFSUSBUserData(sourceRootURL: URL,
                                   vaultURL: URL,
                                   vaultPassphrase: String,
                                   deleteOriginals: Bool,
                                   dryRun: Bool,
                                   targetMountPoint: String?,
                                   excludedSourcePaths: [String] = [],
                                   completion: ((Bool) -> Void)? = nil) {
        let sourceRoot = sourceRootURL.standardizedFileURL
        let vault = vaultURL.standardizedFileURL
        let pass = vaultPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let mountPointTrimmed = targetMountPoint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExcludedSourcePaths = Array(Set(excludedSourcePaths.map {
            URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        })).sorted()

        guard dryRun || !pass.isEmpty else {
            status = "Enter a vault passphrase"
            completion?(false)
            return
        }
        if !dryRun && !PassphraseStrengthReport.evaluate(pass).isRequired {
            status = "Passphrase is too weak. Use 8+ chars with uppercase, lowercase, and a number."
            completion?(false)
            return
        }

        status = dryRun
        ? "Scanning USB user data in \(sourceRoot.path)..."
        : "Encrypting USB user data from \(sourceRoot.path)..."
        usbDataEncryptionTargetMountPoint = mountPointTrimmed
        usbDataEncryptionActive = true
        usbDataEncryptionProgressFraction = nil
        usbDataEncryptionProgressMessage = dryRun ? "Scanning source files..." : "Preparing file encryption..."
        usbDataEncryptionProcessedFiles = 0
        usbDataEncryptionTotalFiles = 0
        usbDataEncryptionStage = .scanning
        usbDataEncryptionLogs = []
        usbDataEncryptionLastResult = nil
        appendUSBDataEncryptionLog(dryRun
                                   ? "Starting scan for user files under \(sourceRoot.path)"
                                   : "Starting encryption of user files under \(sourceRoot.path)")
        appendUSBDataEncryptionLog("Vault output: \(vault.path)")
        if FileManager.default.fileExists(atPath: vault.path) {
            appendUSBDataEncryptionLog("Warning: target vault already exists. Matching paths will be replaced.")
        }
        if !normalizedExcludedSourcePaths.isEmpty {
            appendUSBDataEncryptionLog("Excluded path count: \(normalizedExcludedSourcePaths.count)")
            for path in normalizedExcludedSourcePaths {
                appendUSBDataEncryptionLog("Exclude: \(path)")
            }
        }
        let cancellationFlag = USBDataEncryptionCancellationFlag()
        usbDataEncryptionCancellationFlag = cancellationFlag

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try USBUserDataCrypto.encryptUserFiles(sourceRootURL: sourceRoot,
                                                                    vaultURL: vault,
                                                                    passphrase: pass,
                                                                    deleteOriginals: deleteOriginals,
                                                                    dryRun: dryRun,
                                                                    excludingPaths: normalizedExcludedSourcePaths.map {
                    URL(fileURLWithPath: $0, isDirectory: true)
                },
                                                                    progress: { progress in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if cancellationFlag.isCancelled() {
                            return
                        }
                        self.usbDataEncryptionStage = progress.stage
                        self.usbDataEncryptionProcessedFiles = progress.processedFileCount
                        self.usbDataEncryptionTotalFiles = progress.totalFileCount
                        self.usbDataEncryptionProgressFraction = progress.fraction
                        self.usbDataEncryptionProgressMessage = progress.message
                        self.appendUSBDataEncryptionLog(progress.message)
                    }
                },
                                                                    isCancelled: {
                    cancellationFlag.isCancelled()
                })
                DispatchQueue.main.async {
                    guard let self else { return }
                    if cancellationFlag.isCancelled() {
                        self.usbDataEncryptionActive = false
                        self.usbDataEncryptionStage = .completed
                        self.usbDataEncryptionCancellationFlag = nil
                        self.usbDataEncryptionProgressMessage = "Encryption cancelled."
                        self.appendUSBDataEncryptionLog("Operation cancelled. Partial new vault output was cleaned when possible.")
                        self.status = "USB user-data encryption cancelled. Partial new vault output was cleaned."
                        self.usbDataEncryptionLastResult = nil
                        completion?(false)
                        return
                    }
                    self.usbDataEncryptionActive = false
                    self.usbDataEncryptionStage = .completed
                    self.usbDataEncryptionCancellationFlag = nil
                    self.usbDataEncryptionLastResult = result
                    if result.dryRun {
                        self.usbDataEncryptionProcessedFiles = result.scannedFileCount
                        self.usbDataEncryptionTotalFiles = result.scannedFileCount
                        self.usbDataEncryptionProgressFraction = result.scannedFileCount > 0 ? 1.0 : nil
                        self.usbDataEncryptionProgressMessage = "Scan complete: \(result.scannedFileCount) user file(s)."
                        self.appendUSBDataEncryptionLog("Scan complete: \(result.scannedFileCount) user file(s), \(result.skippedPathCount) skipped.")
                        self.status = "Scan complete: \(result.scannedFileCount) user file(s), \(result.skippedPathCount) skipped system path(s)."
                        completion?(true)
                        return
                    }

                    self.usbDataEncryptionProcessedFiles = result.encryptedFileCount
                    self.usbDataEncryptionTotalFiles = result.scannedFileCount
                    self.usbDataEncryptionProgressFraction = result.scannedFileCount > 0 ? 1.0 : nil

                    var message = "Encrypted \(result.encryptedFileCount) user file(s) into \(result.vaultURL.path)."
                    if deleteOriginals {
                        message += " Deleted \(result.deletedOriginalCount) original file(s)."
                        if !result.deletionErrors.isEmpty {
                            message += " \(result.deletionErrors.count) file(s) could not be deleted."
                        }
                    }
                    if result.createdVault {
                        message += " Created vault."
                    }
                    self.status = message
                    self.usbDataEncryptionProgressMessage = "Encryption complete: \(result.encryptedFileCount)/\(result.scannedFileCount) file(s)."
                    self.appendUSBDataEncryptionLog("Encryption complete: \(result.encryptedFileCount)/\(result.scannedFileCount) file(s).")
                    if deleteOriginals {
                        self.appendUSBDataEncryptionLog("Original file deletion: \(result.deletedOriginalCount) removed, \(result.deletionErrors.count) errors.")
                    }

                    // Always switch to the packed vault after a successful run so
                    // the workspace reflects the newly encrypted files immediately.
                    self.vaultURL = result.vaultURL
                    self.passphrase = pass
                    self.locked = false
                    self.refreshStatus()
                    completion?(true)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.usbDataEncryptionActive = false
                    self.usbDataEncryptionStage = .completed
                    self.usbDataEncryptionCancellationFlag = nil
                    let errorText = String(describing: error).lowercased()
                    if errorText.contains("cancelled by user") {
                        self.usbDataEncryptionProgressMessage = "Encryption cancelled."
                        self.appendUSBDataEncryptionLog("Operation cancelled. Partial new vault output was cleaned when possible.")
                        self.status = "USB user-data encryption cancelled. Partial new vault output was cleaned."
                        self.usbDataEncryptionLastResult = nil
                        completion?(false)
                        return
                    }
                    if self.usbDataEncryptionProgressMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || self.usbDataEncryptionProgressMessage == "Cancelling..." {
                        self.usbDataEncryptionProgressMessage = "Encryption failed."
                    }
                    self.appendUSBDataEncryptionLog("Operation failed: \(error)")
                    self.status = "USB user-data encryption failed: \(error)"
                    self.usbDataEncryptionLastResult = nil
                    completion?(false)
                }
            }
        }
    }

    func createUSBContainer(imageURL: URL,
                            size: String,
                            volumeName: String,
                            recoveryPassphrase: String,
                            recoveryURL: URL,
                            overwrite: Bool,
                            containerPassphrase: String?,
                            dryRun: Bool,
                            completion: ((Result<USBContainerCreateResult, Error>) -> Void)? = nil) {
        let trimmedSize = size.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = volumeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPass = recoveryPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSize.isEmpty else {
            status = "Enter a container size (for example, 16g)"
            completion?(.failure(NSError(domain: "VaultModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing container size"])))
            return
        }
        guard !trimmedName.isEmpty else {
            status = "Enter a container volume name"
            completion?(.failure(NSError(domain: "VaultModel", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing container volume name"])))
            return
        }
        guard !trimmedPass.isEmpty else {
            status = "Enter a recovery passphrase"
            completion?(.failure(NSError(domain: "VaultModel", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing recovery passphrase"])))
            return
        }

        status = dryRun
            ? "Validating USB container creation request..."
            : "Creating encrypted USB container..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try USBContainerCrypto.createEncryptedContainer(
                    imageURL: imageURL,
                    size: trimmedSize,
                    volumeName: trimmedName,
                    recoveryPassphrase: trimmedPass,
                    recoveryURL: recoveryURL,
                    overwrite: overwrite,
                    containerPassphrase: containerPassphrase,
                    dryRun: dryRun
                )
                DispatchQueue.main.async {
                    guard let self else { return }
                    if result.dryRun {
                        self.status = "Dry run complete. Recovery bundle: \(result.recoveryURL.path)"
                    } else {
                        self.status = "Created USB container image at \(result.imageURL.path). Recovery bundle: \(result.recoveryURL.path)"
                    }
                    completion?(.success(result))
                }
            } catch {
                DispatchQueue.main.async {
                    self?.status = "USB container create failed: \(error)"
                    completion?(.failure(error))
                }
            }
        }
    }

    func mountUSBContainer(imageURL: URL,
                           recoveryPassphrase: String,
                           recoveryURL: URL,
                           containerPassphraseOverride: String?,
                           dryRun: Bool,
                           completion: ((Result<USBContainerMountResult, Error>) -> Void)? = nil) {
        let recoveryPass = recoveryPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let overridePass = containerPassphraseOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        if recoveryPass.isEmpty && (overridePass?.isEmpty ?? true) {
            status = "Enter a recovery passphrase or a direct container passphrase"
            completion?(.failure(NSError(domain: "VaultModel", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing mount passphrase"])))
            return
        }

        status = dryRun
            ? "Validating USB container mount request..."
            : "Mounting encrypted USB container..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try USBContainerCrypto.mountEncryptedContainer(
                    imageURL: imageURL,
                    recoveryPassphrase: recoveryPass,
                    recoveryURL: recoveryURL,
                    containerPassphraseOverride: overridePass,
                    dryRun: dryRun
                )
                DispatchQueue.main.async {
                    guard let self else { return }
                    if result.dryRun {
                        self.status = "Dry run complete: USB container mount validated."
                    } else if let mountPoint = result.mountPoint {
                        self.status = "Mounted container at \(mountPoint)"
                    } else {
                        self.status = "Mounted container image. Mount point unavailable."
                    }
                    completion?(.success(result))
                }
            } catch {
                DispatchQueue.main.async {
                    self?.status = "USB container mount failed: \(error)"
                    completion?(.failure(error))
                }
            }
        }
    }

    func unmountUSBContainer(target: String,
                             force: Bool,
                             dryRun: Bool,
                             completion: ((Result<Void, Error>) -> Void)? = nil) {
        let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTarget.isEmpty else {
            status = "Enter a mount point or disk identifier to unmount"
            completion?(.failure(NSError(domain: "VaultModel", code: 5, userInfo: [NSLocalizedDescriptionKey: "Missing unmount target"])))
            return
        }

        status = dryRun
            ? "Validating unmount target..."
            : "Unmounting \(trimmedTarget)..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try USBContainerCrypto.unmountContainer(target: trimmedTarget, force: force, dryRun: dryRun)
                DispatchQueue.main.async {
                    self?.status = dryRun
                        ? "Dry run complete: unmount target validated."
                        : "Unmounted \(trimmedTarget)."
                    completion?(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    self?.status = "USB container unmount failed: \(error)"
                    completion?(.failure(error))
                }
            }
        }
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
                    self?.status = "Backup failed: \(error)"
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
                    self?.status = error.localizedDescription
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
                    self?.status = "Verify failed: \(error)"
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
                    self?.status = "Status failed: \(error)"
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
                    self?.status = "Shred failed: \(error)"
                    completion?(.failure(error))
                }
            }
        }
    }

    func startAutoLockTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if self.locked {
                    self.autoLockRemaining = 0
                    return
                }
                guard let deadline = self.autoLockDeadline else { return }
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    self.lockSession()
                } else {
                    self.autoLockRemaining = remaining
                }
            }
        }
        // Event monitors to track user activity
        let types: [NSEvent.EventTypeMask] = [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        for t in types {
            if let gm = NSEvent.addGlobalMonitorForEvents(matching: t, handler: { [weak self] _ in self?.touchActivity() }) {
                globalMonitors.append(gm)
            }
            if let lm = NSEvent.addLocalMonitorForEvents(matching: t, handler: { [weak self] ev in self?.touchActivity(); return ev }) {
                localMonitors.append(lm as Any)
            }
        }
        // Lock on screen sleep / session resign
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lockSession() }
        }
        nc.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lockSession() }
        }
    }

    func lockSession() {
        stopDiskEncryptionProgressMonitoring()
        clearUSBDataEncryptionProgressIfIdle()
        invalidateVaultEntriesRefresh()
        self.passphrase = ""
        self.locked = true
        self.entries = []
        self.vaultFileCount = nil
        self.status = "Auto-locked"
        autoLockDeadline = nil
        autoLockRemaining = 0
    }

    private func touchActivity() {
        lastActivity = .now
        resetAutoLockDeadline()
    }

    private func resetAutoLockDeadline() {
        guard !locked else {
            autoLockDeadline = nil
            autoLockRemaining = 0
            return
        }
        autoLockDeadline = Date().addingTimeInterval(TimeInterval(autoLockTTL))
        updateAutoLockRemaining()
    }

    private func updateAutoLockRemaining() {
        guard !locked, let deadline = autoLockDeadline else {
            autoLockRemaining = 0
            return
        }
        let remaining = deadline.timeIntervalSinceNow
        autoLockRemaining = max(0, remaining)
    }

    func extendAutoLock(by seconds: TimeInterval) {
        guard !locked else { return }
        if autoLockDeadline == nil {
            resetAutoLockDeadline()
        }
        autoLockDeadline = (autoLockDeadline ?? Date()).addingTimeInterval(seconds)
        updateAutoLockRemaining()
    }

    func normalizeUnlockFlagsIfNeeded() -> Bool {
        touchActivity()
        guard let vaultURL else {
            status = "Open a vault first"
            return false
        }
        let trimmedPass = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPass.isEmpty else {
            status = "Unlock with your passphrase to normalize vault flags"
            return false
        }

        do {
            let changed = try VaultSettings.normalizeUnlockFlags(vaultURL: vaultURL, passphrase: trimmedPass)
            if changed {
                status = "Normalized vault unlock flags"
            } else {
                status = "Vault flags already correct"
            }
            refreshStatus()
            return changed
        } catch {
            status = "Flag normalization failed: \(error)"
            return false
        }
    }
}

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
        let p = NSOpenPanel()
        p.title = "Open Vault (AegiroVault)"
        p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        let allowedTypes = Self.supportedVaultExtensions
            .sorted()
            .compactMap { UTType(filenameExtension: $0, conformingTo: .data) }
        guard !allowedTypes.isEmpty else {
            self.status = "Open failed: supported vault file types are unavailable"
            return
        }
        p.allowedContentTypes = allowedTypes
        if p.runModal() == .OK, let url = p.url {
            openVault(at: url)
        }
    }

    func saveSettings() {
        let d = UserDefaults.standard
        d.set(defaultVaultDir.path, forKey: "defaultVaultDir")
        d.set(autoLockTTL, forKey: "autoLockTTL")
        status = "Preferences saved"
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
