
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
            ?? defaultVaultDirectoryURL().path
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
    @State private var startOnUSBEncryption = false

    init() {
        AegiroFontRegistry.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if showFirstRun {
                    FirstRunView(onDone: {
                        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
                        startOnUSBEncryption = false
                        showFirstRun = false
                    }, onOpenUSBEncryption: {
                        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
                        startOnUSBEncryption = true
                        showFirstRun = false
                    })
                    .environmentObject(model)
                } else {
                    MainView(startOnUSBEncryption: startOnUSBEncryption)
                        .environmentObject(model)
                }
            }
            .frame(minWidth: 1080, minHeight: 720)
            .font(AegiroTypography.body(13))
            .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        Settings {
            PreferencesView()
                .environmentObject(model)
        }
        .commands {
            CommandMenu("Vault") {
                Button("Open Vault...") { model.openVaultWithPanel() }
                    .keyboardShortcut("o", modifiers: [.command])
                Button(model.locked ? "Unlock Vault" : "Lock Vault") {
                    if model.locked { NSApp.sendAction(Selector(("showUnlock:")), to: nil, from: nil) } else { model.lockNow() }
                }
                .keyboardShortcut("l", modifiers: [.command])
                Divider()
                Button("Import...") { model.importFiles() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(model.locked)
                Button("Export...") { model.exportSelectedWithPanel() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.locked)
            }
        }
    }
}
