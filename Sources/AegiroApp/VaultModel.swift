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
    @Published var autoLockRemaining: TimeInterval = 0
    private var timer: Timer?
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
        self.supportsBiometricUnlock = canEvaluateBiometrics()
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
            let info = try VaultStatus.get(vaultURL: url, passphrase: passphrase.isEmpty ? nil : passphrase)
            self.locked = info.locked
            self.vaultFileCount = info.entries
            self.vaultSizeBytes = info.vaultSizeBytes
            self.vaultLastEdited = info.vaultLastModified
            self.sidecarPending = info.sidecarPending
            self.manifestOK = info.manifestOK
            self.supportsBiometricUnlock = info.touchIDEnabled && canEvaluateBiometrics()
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
                    }
                }
            } catch {
                DispatchQueue.main.async {
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

        status = dryRun ? "Validating PQC bundle for \(disk)..." : "Unlocking \(disk)..."
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
                        self.status = "Unlock command sent for \(disk)."
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.status = "Disk unlock failed: \(error)"
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
        self.passphrase = ""
        self.locked = true
        self.entries = []
        self.vaultFileCount = nil
        self.status = "Auto-locked"
        autoLockDeadline = nil
        autoLockRemaining = 0
    }

    func unlockWithBiometrics() {
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
        guard canEvaluateBiometrics() else {
            status = "Touch ID unavailable on this Mac"
            return
        }
        do {
            try BiometricKeychain.save(passphrase: passphrase, for: url)
        } catch {
            status = "Touch ID storage failed: \(message(for: error))"
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
}
