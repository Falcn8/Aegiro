import SwiftUI
import AppKit

struct PreferencesView: View {
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) private var dismiss

    @State private var ttlMinutes: Double = 5
    private let presets: [Int] = [1, 5, 10, 15, 30, 60]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            settingsCard

            Spacer()

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                Button("Save") {
                    applyTTL()
                    model.saveSettings()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(AegiroPalette.primaryBlue)
            }
        }
        .padding(28)
        .frame(width: 620, height: 460)
        .background(
            LinearGradient(
                colors: [Color.white, AegiroPalette.iceBlue.opacity(0.2)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .onAppear {
            ttlMinutes = max(1, min(60, Double(model.autoLockTTL) / 60.0))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(AegiroPalette.deepNavy, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Preferences")
                    .font(.title2.weight(.bold))
                Text("Simple controls for vault behavior")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Default vault folder", systemImage: "folder")
                    .font(.headline)
                HStack(spacing: 10) {
                    Text(model.defaultVaultDir.path)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseDir() }
                        .buttonStyle(.bordered)
                }
                Text("Used when creating new vaults.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Auto-lock timeout", systemImage: "timer")
                        .font(.headline)
                    Spacer()
                    Text("\(Int(ttlMinutes)) min")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack {
                    ForEach(presets, id: \.self) { minute in
                        Button("\(minute)") {
                            ttlMinutes = Double(minute)
                            applyTTL()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ttlMinutes == Double(minute) ? AegiroPalette.tealBlue : AegiroPalette.iceBlue)
                    }
                }

                Slider(value: $ttlMinutes, in: 1...60, step: 1) { _ in
                    applyTTL()
                }
            }

            Divider()

            Toggle(isOn: $model.allowTouchID) {
                Label("Enable Touch ID", systemImage: "touchid")
            }
            .disabled(!model.supportsBiometricUnlock)

            if !model.supportsBiometricUnlock {
                Text("Touch ID must be configured at vault creation time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AegiroPalette.iceBlue.opacity(0.8), lineWidth: 1)
        )
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
