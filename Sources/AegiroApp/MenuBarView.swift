
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var model: VaultModel
    @State private var unlockPass = ""
    @State private var showUnlock = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().frame(width: 8, height: 8).foregroundStyle(model.locked ? .red : .green)
                Text(model.locked ? "Locked" : "Unlocked")
                Spacer()
                Text(model.vaultURL?.lastPathComponent ?? "No vault")
            }
            Divider()
            if model.locked {
                Button("Unlock…") { showUnlock = true }
            } else {
                Button("Lock Now") { model.lockNow() }
                Button("Add Files…") { model.importFiles() }
                Button("Export…") { model.exportSelectedWithPanel() }
                Button("Preferences…") { NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil) }
            }
            if !model.status.isEmpty {
                Divider()
                Text(model.status).font(.footnote).foregroundStyle(.secondary)
            }
        }.padding(8).frame(width: 260)
        .sheet(isPresented: $showUnlock) {
            VStack(spacing: 12) {
                Text("Unlock Vault").font(.title3).bold()
                SecureField("Passphrase", text: $unlockPass)
                HStack {
                    Spacer()
                    Button("Cancel") { showUnlock = false }
                    Button("Unlock") { model.unlock(with: unlockPass); showUnlock = false }
                        .buttonStyle(.borderedProminent)
                        .disabled(unlockPass.isEmpty)
                }
            }.padding(16).frame(width: 320)
        }
    }
}
