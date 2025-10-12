
import SwiftUI
import AegiroCore

@main
struct AegiroAppMain: App {
    @StateObject private var model = VaultModel()
    @State private var showFirstRun = true
    var body: some Scene {
        WindowGroup {
            if showFirstRun {
                FirstRunView(onDone: { showFirstRun = false })
                    .environmentObject(model)
            } else {
                MainView()
                    .environmentObject(model)
            }
        }
        .windowStyle(.hiddenTitleBar)
        MenuBarExtra("Aegiro", systemImage: "lock.shield") {
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
