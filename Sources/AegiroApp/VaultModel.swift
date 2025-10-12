import Foundation
import SwiftUI
import AppKit
import AegiroCore
import UniformTypeIdentifiers
@preconcurrency import LocalAuthentication

@MainActor
final class VaultModel: ObservableObject {
    @Published var vaultURL: URL?
    @Published var locked: Bool = true
    @Published var entries: [VaultIndexEntry] = []
    @Published var sidecarPending: Int = 0
    @Published var manifestOK: Bool = false
    @Published var status: String = ""
    @Published var passphrase: String = ""
    @Published var defaultVaultDir: URL
    @Published var autoLockTTL: Int
    @Published var allowTouchID: Bool
    @Published var supportsBiometricUnlock: Bool = false
    private var timer: Timer?
    private var lastActivity: Date = .now
    private var globalMonitors: [Any] = []
    private var localMonitors: [Any] = []

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
    }

    func createVault(at url: URL, passphrase: String, touchID: Bool) {
        do {
            let v = try AegiroVault.create(at: url, passphrase: passphrase, touchID: touchID)
            self.vaultURL = v.url
            self.passphrase = passphrase
            self.status = "Vault created"
            self.allowTouchID = touchID
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
            self.sidecarPending = info.sidecarPending
            self.manifestOK = info.manifestOK
            self.supportsBiometricUnlock = info.touchIDEnabled
            if !info.touchIDEnabled {
                removeBiometricPassphrase()
            }
            if !info.locked, !passphrase.isEmpty {
                self.entries = (try? Exporter.list(vaultURL: url, passphrase: passphrase)) ?? []
            } else {
                self.entries = []
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
            self.entries = (try? Exporter.list(vaultURL: url, passphrase: pass)) ?? []
            self.status = "Unlocked"
            if allowTouchID {
                storePassphraseForBiometrics(pass)
            } else {
                removeBiometricPassphrase()
            }
        } catch {
            self.status = "Unlock failed: \(error)"
        }
    }

    func lockNow() {
        touchActivity()
        guard let url = vaultURL else { return }
        do {
            let added = try Locker.lockFromSidecar(vaultURL: url, passphrase: passphrase)
            self.status = "Locked. Ingested \(added) item(s)"
            self.refreshStatus()
        } catch {
            self.status = "Lock failed: \(error)"
        }
    }

    func importFiles() {
        touchActivity()
        guard let url = vaultURL else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            do {
                let (_, sidecar) = try Importer.sidecarImport(vaultURL: url, passphrase: passphrase, files: panel.urls)
                self.status = "Imported to sidecar: \(sidecar.lastPathComponent)"
                self.refreshStatus()
            } catch {
                self.status = "Import failed: \(error)"
            }
        }
    }

    func exportSelected(to dir: URL, filters: [String] = []) {
        touchActivity()
        guard let url = vaultURL else { return }
        do {
            let res = try Exporter.export(vaultURL: url, passphrase: passphrase, filters: filters, outDir: dir)
            self.status = res.isEmpty ? "Nothing exported" : "Exported \(res.count) file(s)"
        } catch {
            self.status = "Export failed: \(error)"
        }
    }

    func exportSelectedWithPanel(filter: String? = nil) {
        touchActivity()
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
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let dir = panel.url {
            exportSelected(to: dir, filters: filters)
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

    func startAutoLockTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !self.locked {
                let elapsed = Date().timeIntervalSince(self.lastActivity)
                if elapsed >= TimeInterval(self.autoLockTTL) {
                    self.lockSession()
                }
            }
        }
        // Event monitors to track user activity
        let types: [NSEvent.EventTypeMask] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
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
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.lockSession() }
        nc.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.lockSession() }
    }

    func lockSession() {
        self.passphrase = ""
        self.locked = true
        self.entries = []
        self.status = "Auto-locked"
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

    private func touchActivity() { lastActivity = .now }

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
                return "No Touch ID passphrase stored for this vault."
            case .unexpectedStatus(let status):
                return "Keychain error (\(status))."
            case .stringDecodingFailed:
                return "Stored credential is invalid."
            }
        }
        return error.localizedDescription
    }
}

func defaultVaultURL() -> URL {
    let base = UserDefaults.standard.string(forKey: "defaultVaultDir").flatMap { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AegiroVaults")
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base.appendingPathComponent("alpha.aegirovault")
}

extension VaultModel {
    func openVaultWithPanel() {
        let p = NSOpenPanel()
        p.title = "Open Aegiro Vault"
        p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        p.allowedContentTypes = [UTType(filenameExtension: "aegirovault") ?? .data]
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
