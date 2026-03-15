import Foundation
import SwiftUI
import AppKit
import AegiroCore
import UniformTypeIdentifiers
import Security
@preconcurrency import LocalAuthentication

@MainActor
final class VaultModel: ObservableObject {
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
    @Published var allowTouchID: Bool
    @Published var supportsBiometricUnlock: Bool = false
    @Published var biometricKeychainAvailable: Bool = true
    @Published var biometricKeychainIssue: String?
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
    @Published var autoLockRemaining: TimeInterval = 0
    private var timer: Timer?
    private var diskEncryptionProgressTimer: Timer?
    private var lastActivity: Date = .now
    private var globalMonitors: [Any] = []
    private var localMonitors: [Any] = []
    private var autoLockDeadline: Date?

    init() {
        let defaults = UserDefaults.standard
        if let p = defaults.string(forKey: "defaultVaultDir"), !p.isEmpty {
            self.defaultVaultDir = URL(fileURLWithPath: p, isDirectory: true)
        } else {
            let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AegiroVaults")
            self.defaultVaultDir = base
        }
        let ttl = defaults.integer(forKey: "autoLockTTL")
        self.autoLockTTL = ttl > 0 ? ttl : 300
        if defaults.object(forKey: "allowTouchID") != nil {
            self.allowTouchID = defaults.bool(forKey: "allowTouchID")
        } else {
            self.allowTouchID = true
        }
        self.biometricKeychainAvailable = BiometricKeychain.supportsBiometricKeychainStorage()
        self.biometricKeychainIssue = self.biometricKeychainAvailable ? nil : "This build is missing secure keychain entitlements required for Touch ID storage."
        self.supportsBiometricUnlock = canEvaluateBiometrics() && self.biometricKeychainAvailable
    }

    func createVault(at url: URL, passphrase: String, touchID: Bool) {
        do {
            let v = try AegiroVault.create(at: url, passphrase: passphrase, touchID: touchID)
            self.vaultURL = v.url
            self.passphrase = passphrase
            self.status = "Vault created"
            self.allowTouchID = touchID
            UserDefaults.standard.set(touchID, forKey: "allowTouchID")
            UserDefaults.standard.set(v.url.path, forKey: "lastVaultPath")
            UserDefaults.standard.set(true, forKey: "onboardingCompleted")
            self.refreshStatus()
            if touchID {
                storePassphraseForBiometrics(passphrase)
            } else {
                removeBiometricPassphrase()
            }
        } catch {
            self.status = "Create failed: \(error)"
        }
    }

    func openVault(at url: URL) {
        do {
            _ = try AegiroVault.open(at: url)
            self.vaultURL = url
            UserDefaults.standard.set(url.path, forKey: "lastVaultPath")
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
            refreshBiometricBuildSupport()
            let info = try VaultStatus.get(vaultURL: url, passphrase: passphrase.isEmpty ? nil : passphrase)
            self.locked = info.locked
            self.vaultFileCount = info.entries
            self.vaultSizeBytes = info.vaultSizeBytes
            self.vaultLastEdited = info.vaultLastModified
            self.sidecarPending = info.sidecarPending
            self.manifestOK = info.manifestOK
            self.supportsBiometricUnlock = info.touchIDEnabled && canEvaluateBiometrics() && biometricKeychainAvailable
            if info.touchIDEnabled {
                if !allowTouchID {
                    allowTouchID = true
                    UserDefaults.standard.set(true, forKey: "allowTouchID")
                }
            } else {
                allowTouchID = false
                UserDefaults.standard.set(false, forKey: "allowTouchID")
                removeBiometricPassphrase()
            }
            if !info.locked, !passphrase.isEmpty {
                self.entries = (try? Exporter.list(vaultURL: url, passphrase: passphrase)) ?? []
                if autoLockDeadline == nil {
                    resetAutoLockDeadline()
                } else {
                    updateAutoLockRemaining()
                }
            } else {
                self.entries = []
                autoLockDeadline = nil
                autoLockRemaining = 0
            }
        } catch {
            self.status = "Status failed: \(error)"
        }
    }

    func unlock(with pass: String) {
        touchActivity()
        guard let url = vaultURL else { return }
        do {
            _ = try Locker.unlockInfo(vaultURL: url, passphrase: pass)
            self.passphrase = pass
            self.locked = false
            self.status = "Unlocked"
            if allowTouchID {
                storePassphraseForBiometrics(pass)
            } else {
                removeBiometricPassphrase()
            }
            refreshStatus()
        } catch {
            self.status = "Unlock failed: \(error)"
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
            _ = try Exporter.export(vaultURL: url, passphrase: passphrase, filters: [logicalPath], outDir: tmpDir)
            let out = tmpDir.appendingPathComponent((logicalPath as NSString).lastPathComponent)
            NSWorkspace.shared.open(out)
        } catch {
            self.status = "Preview failed: \(error)"
        }
    }

    func revealExport(logicalPath: String) {
        guard let url = vaultURL else { return }
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        do {
            _ = try Exporter.export(vaultURL: url, passphrase: passphrase, filters: [logicalPath], outDir: tmpDir)
            let out = tmpDir.appendingPathComponent((logicalPath as NSString).lastPathComponent)
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
                                   completion: ((Bool) -> Void)? = nil) {
        let sourceRoot = sourceRootURL.standardizedFileURL
        let vault = vaultURL.standardizedFileURL
        let pass = vaultPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let mountPointTrimmed = targetMountPoint?.trimmingCharacters(in: .whitespacesAndNewlines)

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

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try USBUserDataCrypto.encryptUserFiles(sourceRootURL: sourceRoot,
                                                                    vaultURL: vault,
                                                                    passphrase: pass,
                                                                    deleteOriginals: deleteOriginals,
                                                                    dryRun: dryRun) { progress in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.usbDataEncryptionStage = progress.stage
                        self.usbDataEncryptionProcessedFiles = progress.processedFileCount
                        self.usbDataEncryptionTotalFiles = progress.totalFileCount
                        self.usbDataEncryptionProgressFraction = progress.fraction
                        self.usbDataEncryptionProgressMessage = progress.message
                    }
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.usbDataEncryptionActive = false
                    self.usbDataEncryptionStage = .completed
                    self.usbDataEncryptionProcessedFiles = result.encryptedFileCount
                    self.usbDataEncryptionTotalFiles = result.scannedFileCount
                    self.usbDataEncryptionProgressFraction = result.scannedFileCount > 0 ? 1.0 : nil
                    if result.dryRun {
                        self.usbDataEncryptionProgressMessage = "Scan complete: \(result.scannedFileCount) user file(s)."
                        self.status = "Scan complete: \(result.scannedFileCount) user file(s), \(result.skippedPathCount) skipped system path(s)."
                        completion?(true)
                        return
                    }

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

                    if self.vaultURL == nil || self.vaultURL?.standardizedFileURL.path == result.vaultURL.path {
                        self.vaultURL = result.vaultURL
                        self.passphrase = pass
                        self.locked = false
                        self.refreshStatus()
                    }
                    completion?(true)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.usbDataEncryptionActive = false
                    self.usbDataEncryptionStage = .completed
                    if self.usbDataEncryptionProgressMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.usbDataEncryptionProgressMessage = "Encryption failed."
                    }
                    self.status = "USB user-data encryption failed: \(error)"
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
                    self?.status = "Backup exported to \(outURL.path) (directory created; zip externally)."
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

    func verifyManifest(vaultURL: URL,
                        completion: ((Result<Bool, Error>) -> Void)? = nil) {
        status = "Verifying manifest signature..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let manifest = try ManifestIO.load(from: vaultURL)
                #if REAL_CRYPTO
                let signer = Dilithium2()
                #else
                let signer = StubSig()
                #endif
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
        self.passphrase = ""
        self.locked = true
        self.entries = []
        self.vaultFileCount = nil
        self.status = "Auto-locked"
        autoLockDeadline = nil
        autoLockRemaining = 0
    }

    func unlockWithBiometrics() {
        refreshBiometricBuildSupport()
        guard biometricKeychainAvailable else {
            status = biometricKeychainIssue ?? "Touch ID unavailable in this build."
            return
        }
        guard supportsBiometricUnlock, allowTouchID else {
            status = "Touch ID is not enabled for this vault"
            return
        }
        guard let url = vaultURL else { return }
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passphrase"
        let reason = "Authenticate to unlock \(url.lastPathComponent)"
        context.localizedReason = reason
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            status = error?.localizedDescription ?? "Touch ID unavailable on this Mac"
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { [weak self] success, evalError in
            guard let self else { return }
            if success {
                do {
                    let stored = try BiometricKeychain.loadPassphrase(for: url, context: context)
                    Task { @MainActor in
                        self.unlock(with: stored)
                    }
                } catch {
                    Task { @MainActor in
                        self.status = "Touch ID failed: \(self.message(for: error))"
                    }
                }
            } else if let evalError {
                Task { @MainActor in
                    self.status = "Touch ID failed: \(evalError.localizedDescription)"
                }
            } else {
                Task { @MainActor in
                    self.status = "Touch ID cancelled"
                }
            }
        }
    }

    func addTouchIDForUnlockedVault() {
        touchActivity()
        refreshBiometricBuildSupport()
        guard biometricKeychainAvailable else {
            status = biometricKeychainIssue ?? "Touch ID unavailable in this build."
            return
        }
        guard let url = vaultURL else {
            status = "Open a vault first"
            return
        }
        guard !locked else {
            status = "Unlock to add Touch ID"
            return
        }
        guard !passphrase.isEmpty else {
            status = "Unlock with passphrase once to add Touch ID"
            return
        }
        guard canEvaluateBiometrics() else {
            status = "Touch ID unavailable on this Mac"
            return
        }

        do {
            try VaultSettings.setTouchIDEnabled(vaultURL: url, enabled: true)
            allowTouchID = true
            UserDefaults.standard.set(true, forKey: "allowTouchID")
            supportsBiometricUnlock = true
            storePassphraseForBiometrics(passphrase)
            status = "Touch ID enabled for this vault"
            refreshStatus()
        } catch {
            status = "Touch ID setup failed: \(error)"
        }
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

    private func storePassphraseForBiometrics(_ passphrase: String) {
        guard supportsBiometricUnlock, allowTouchID, !passphrase.isEmpty, let url = vaultURL else { return }
        refreshBiometricBuildSupport()
        guard biometricKeychainAvailable else {
            status = biometricKeychainIssue ?? "Touch ID unavailable in this build."
            return
        }
        guard canEvaluateBiometrics() else {
            status = "Touch ID unavailable on this Mac"
            return
        }
        do {
            try BiometricKeychain.save(passphrase: passphrase, for: url)
        } catch {
            status = "Touch ID storage failed: \(message(for: error))"
            if case BiometricKeychainError.unexpectedStatus(let code) = error, code == errSecMissingEntitlement {
                biometricKeychainAvailable = false
                biometricKeychainIssue = "This build is missing secure keychain entitlements required for Touch ID storage."
            }
        }
    }

    private func removeBiometricPassphrase() {
        guard let url = vaultURL else { return }
        BiometricKeychain.removePassphrase(for: url)
    }

    private func canEvaluateBiometrics() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    private func refreshBiometricBuildSupport() {
        let available = BiometricKeychain.supportsBiometricKeychainStorage()
        biometricKeychainAvailable = available
        biometricKeychainIssue = available ? nil : "This build is missing secure keychain entitlements required for Touch ID storage."
    }

    private func message(for error: Error) -> String {
        if let keychainError = error as? BiometricKeychainError {
            switch keychainError {
            case .accessControlCreationFailed:
                return "Could not create secure storage for Touch ID."
            case .itemNotFound:
                return "No Touch ID passphrase is stored for this vault. Unlock once with your passphrase to save it."
            case .unexpectedStatus(let status):
                if status == errSecMissingEntitlement {
                    return "This app build cannot access the secure keychain for Touch ID."
                }
                return "Keychain error (\(status))."
            case .stringDecodingFailed:
                return "Stored credential is invalid."
            }
        }
        return error.localizedDescription
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

func defaultVaultURL() -> URL {
    let base = UserDefaults.standard.string(forKey: "defaultVaultDir").flatMap { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AegiroVaults")
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base.appendingPathComponent("alpha.agvt")
}

extension VaultModel {
    func openVaultWithPanel() {
        let p = NSOpenPanel()
        p.title = "Open Vault (AegiroVault)"
        p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        p.allowedContentTypes = [
            UTType(filenameExtension: "agvt") ?? .data,
            UTType(filenameExtension: "aegirovault") ?? .data
        ]
        if p.runModal() == .OK, let url = p.url {
            openVault(at: url)
        }
    }

    func saveSettings() {
        let d = UserDefaults.standard
        d.set(defaultVaultDir.path, forKey: "defaultVaultDir")
        d.set(autoLockTTL, forKey: "autoLockTTL")
        d.set(allowTouchID, forKey: "allowTouchID")
        if allowTouchID {
            if !passphrase.isEmpty {
                storePassphraseForBiometrics(passphrase)
            }
        } else {
            removeBiometricPassphrase()
        }
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
        lines.append("Touch ID: \(info.touchIDEnabled ? "enabled" : "disabled")")
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
