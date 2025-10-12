import SwiftUI
import AppKit

struct PreferencesView: View {
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Preferences").font(.title3).bold()
            HStack {
                Text("Default vaults folder:")
                TextField("/path/to/folder", text: .constant(model.defaultVaultDir.path))
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)
                Button("Choose…") { chooseDir() }
            }
            HStack {
                Text("Auto-lock (seconds):")
                Stepper(value: Binding(get: { model.autoLockTTL }, set: { model.autoLockTTL = $0 }), in: 30...3600, step: 30) {
                    Text("\(model.autoLockTTL)")
                }
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                Button("Save") { model.saveSettings(); dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 600)
    }

    private func chooseDir() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        if p.runModal() == .OK, let url = p.url {
            model.defaultVaultDir = url
        }
    }
}

