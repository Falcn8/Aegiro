
import SwiftUI
import AegiroCore
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func shouldShowFirstRun() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "onboardingCompleted") {
            return false
        }

        if let lastVaultPath = defaults.string(forKey: "lastVaultPath"),
           FileManager.default.fileExists(atPath: lastVaultPath) {
            return false
        }

        let defaultDirPath = defaults.string(forKey: "defaultVaultDir")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AegiroVaults", isDirectory: true).path
        let defaultDir = URL(fileURLWithPath: defaultDirPath, isDirectory: true)
        if let contents = try? FileManager.default.contentsOfDirectory(at: defaultDir, includingPropertiesForKeys: nil) {
            let hasVault = contents.contains {
                let ext = $0.pathExtension.lowercased()
                return ext == "agvt" || ext == "aegirovault"
            }
            if hasVault {
                return false
            }
        }

        return true
    }
}

@main
struct AegiroAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = VaultModel()
    @State private var showFirstRun = true
    var body: some Scene {
        WindowGroup {
            if showFirstRun {
                FirstRunView(onDone: {
                    UserDefaults.standard.set(true, forKey: "onboardingCompleted")
                    showFirstRun = false
                })
                .environmentObject(model)
            } else {
                MainView()
                    .environmentObject(model)
            }
        }
        .windowStyle(.hiddenTitleBar)
        MenuBarExtra("Aegiro Vaults", systemImage: "lock.shield") {
            MenuBarView()
                .environmentObject(model)
        }
        Settings {
            PreferencesView()
                .environmentObject(model)
        }
        .commands {
            CommandMenu("Vault") {
                Button("Open Vault…") { model.openVaultWithPanel() }
                    .keyboardShortcut("o", modifiers: [.command])
                Button(model.locked ? "Unlock Vault" : "Lock Vault") {
                    if model.locked { NSApp.sendAction(Selector(("showUnlock:")), to: nil, from: nil) } else { model.lockNow() }
                }
                .keyboardShortcut("l", modifiers: [.command])
                Divider()
                Button("Import…") { model.importFiles() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(model.locked)
                Button("Export…") { model.exportSelectedWithPanel() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.locked)
            }
        }
    }
}
