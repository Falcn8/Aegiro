import SwiftUI
import AppKit

struct PreferencesView: View {
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) private var dismiss

    @State private var ttlMinutes: Double = 5
    private let presets: [Int] = [1, 5, 10, 15, 30, 60]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Preferences")
                .font(AegiroTypography.display(24, weight: .semibold))
                .foregroundStyle(AegiroPalette.textPrimary)

            VStack(alignment: .leading, spacing: 16) {
                sectionLabel("Default Vault Folder")
                HStack(spacing: 10) {
                    Text(model.defaultVaultDir.path)
                        .font(AegiroTypography.mono(12, weight: .regular))
                        .foregroundStyle(AegiroPalette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose...") { chooseDir() }
                        .buttonStyle(.bordered)
                }

                Divider()

                HStack {
                    sectionLabel("Auto-lock Timeout")
                    Spacer()
                    Text("\(Int(ttlMinutes)) min")
                        .font(AegiroTypography.mono(12, weight: .regular))
                        .foregroundStyle(AegiroPalette.textSecondary)
                }

                HStack(spacing: 6) {
                    ForEach(presets, id: \.self) { minute in
                        Button("\(minute)") {
                            ttlMinutes = Double(minute)
                            applyTTL()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ttlMinutes == Double(minute) ? AegiroPalette.accentIndigo : AegiroPalette.backgroundPanel)
                    }
                }

                Slider(value: $ttlMinutes, in: 1...60, step: 1) { _ in
                    applyTTL()
                }
                .tint(AegiroPalette.accentIndigo)

                Divider()

                Toggle("Enable Touch ID", isOn: $model.allowTouchID)
                    .disabled(!model.supportsBiometricUnlock || !model.biometricKeychainAvailable)

                if let issue = model.biometricKeychainIssue {
                    Text(issue)
                        .font(AegiroTypography.body(12, weight: .regular))
                        .foregroundStyle(AegiroPalette.warningAmber)
                } else if !model.supportsBiometricUnlock {
                    Text("Touch ID is unavailable in the current vault configuration.")
                        .font(AegiroTypography.body(12, weight: .regular))
                        .foregroundStyle(AegiroPalette.textMuted)
                }
            }
            .padding(16)
            .background(AegiroPalette.backgroundCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AegiroPalette.borderSubtle, lineWidth: 1)
            )

            Spacer()

            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
                Button("Save") {
                    applyTTL()
                    model.saveSettings()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(AegiroPalette.accentIndigo)
            }
        }
        .padding(24)
        .frame(width: 620, height: 460)
        .background(AegiroPalette.backgroundPanel)
        .onAppear {
            ttlMinutes = max(1, min(60, Double(model.autoLockTTL) / 60.0))
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(AegiroTypography.body(14, weight: .semibold))
            .foregroundStyle(AegiroPalette.textPrimary)
    }

    private func chooseDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose default folder for new vaults"
        if panel.runModal() == .OK, let url = panel.url {
            model.defaultVaultDir = url
        }
    }

    private func applyTTL() {
        let clamped = max(1, min(60, ttlMinutes.rounded()))
        model.autoLockTTL = Int(clamped) * 60
    }
}
