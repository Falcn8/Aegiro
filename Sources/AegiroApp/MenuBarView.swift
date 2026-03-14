import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var model: VaultModel
    @State private var unlockPass = ""
    @State private var showUnlock = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Aegiro Vault")
                .font(AegiroTypography.display(14, weight: .semibold))

            HStack(spacing: 8) {
                Image(systemName: model.locked ? "lock.fill" : "circle.fill")
                    .foregroundStyle(model.locked ? AegiroPalette.warningAmber : AegiroPalette.securityGreen)
                Text(model.locked ? "Locked" : "Unlocked")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("Files: \(model.vaultFileCount ?? 0)")
                    .font(AegiroTypography.mono(11, weight: .regular))
                    .foregroundStyle(.secondary)
            }

            Divider()

            if model.locked {
                Button("Unlock Vault") {
                    showUnlock = true
                }
            } else {
                Button("Lock Vault") {
                    model.lockNow()
                }
                Button("Add Files") {
                    model.importFiles()
                }
                Button("Export") {
                    model.exportSelectedWithPanel()
                }
            }

            Divider()

            Button("Open App") {
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Preferences") {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
            Button("Quit") {
                NSApp.terminate(nil)
            }

            if !model.status.isEmpty {
                Divider()
                Text(model.status)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(10)
        .frame(width: 270)
        .sheet(isPresented: $showUnlock) {
            VStack(spacing: 12) {
                Text("Unlock Vault")
                    .font(AegiroTypography.display(20, weight: .semibold))

                SecureField("Passphrase", text: $unlockPass)
                    .textFieldStyle(.roundedBorder)

                if model.allowTouchID && model.supportsBiometricUnlock && model.biometricKeychainAvailable {
                    Button {
                        model.unlockWithBiometrics()
                        showUnlock = false
                    } label: {
                        Label("Use Touch ID", systemImage: "touchid")
                    }
                    .buttonStyle(.bordered)
                }

                if let issue = model.biometricKeychainIssue {
                    Text(issue)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                HStack {
                    Spacer()
                    Button("Cancel") {
                        unlockPass = ""
                        showUnlock = false
                    }
                    Button("Unlock") {
                        let trimmed = unlockPass.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        model.unlock(with: trimmed)
                        unlockPass = ""
                        showUnlock = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(unlockPass.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
            .frame(width: 320)
        }
    }
}
