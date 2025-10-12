import SwiftUI
import AppKit

struct PreferencesView: View {
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) private var dismiss
    @State private var ttlMinutes: Double = 5
    private let presets: [Int] = [1, 5, 10, 15, 30, 60]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Preferences")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 12) {
                Text("Vaults Folder")
                    .font(.headline)
                HStack(spacing: 12) {
                    Text(model.defaultVaultDir.path)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseDir() }
                        .buttonStyle(.bordered)
                }
                Text("Aegiro uses this folder when creating or discovering vaults.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Auto-lock Timeout")
                        .font(.headline)
                    Spacer()
                    Text("\(Int(ttlMinutes)) minute\(Int(ttlMinutes) == 1 ? "" : "s")")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $ttlMinutes, in: 1...60, step: 1) { editing in
                    if !editing { applyTTL() }
                }
                .accessibilityLabel("Auto-lock timeout in minutes")
                HStack {
                    ForEach(presets, id: \.self) { minute in
                        Button("\(minute)") {
                            ttlMinutes = Double(minute)
                            applyTTL()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ttlMinutes == Double(minute) ? .accentColor : .secondary)
                        .font(.caption.monospacedDigit())
                    }
                }
                Text("Choose how long Aegiro stays unlocked after activity.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Toggle(isOn: $model.allowTouchID) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Allow Touch ID")
                    Text("Biometric unlock stays on this device and never leaves the Secure Enclave.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

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
            }
        }
        .padding(32)
        .frame(width: 560, height: 420)
        .onAppear {
            ttlMinutes = max(1, min(60, Double(model.autoLockTTL) / 60.0))
        }
        .onChange(of: ttlMinutes) { _ in applyTTL() }
    }

    private func chooseDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose the default folder for new vaults"
        if panel.runModal() == .OK, let url = panel.url {
            model.defaultVaultDir = url
        }
    }

    private func applyTTL() {
        let clamped = max(1, min(60, ttlMinutes.rounded()))
        model.autoLockTTL = Int(clamped) * 60
    }
}
