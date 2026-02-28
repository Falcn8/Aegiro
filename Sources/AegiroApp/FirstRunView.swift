import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct FirstRunView: View {
    @EnvironmentObject var model: VaultModel
    var onDone: () -> Void

    @State private var path: String = defaultVaultURL().path
    @State private var passphrase = ""
    @State private var showPassphrase = false
    @State private var touchIDEnabled = true
    @State private var errorText: String?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [AegiroPalette.iceBlue.opacity(0.35), Color.white],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                heroHeader
                contentCard
                footer
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 34)
            .frame(maxWidth: 900)
        }
        .onAppear {
            touchIDEnabled = model.supportsBiometricUnlock && model.allowTouchID
        }
    }

    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(AegiroPalette.primaryBlue, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("Welcome to Aegiro")
                    .font(.system(size: 34, weight: .bold))
            }
            Text("Create or open a vault in seconds. Inspired by the clarity of familiar file and productivity apps used by billions of people.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var contentCard: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                valueProp(icon: "folder.badge.plus", title: "Create a new vault")
                valueProp(icon: "lock.open", title: "Unlock instantly with passphrase")
                valueProp(icon: "tray.and.arrow.down", title: "Stage to sidecar, then lock to import")
                valueProp(icon: "touchid", title: "Optional Touch ID support")

                Divider()

                Button {
                    openExisting()
                } label: {
                    Label("Open Existing Vault", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .frame(width: 250, alignment: .topLeading)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Text("Create New Vault")
                    .font(.title3.weight(.semibold))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Vault location")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("/path/to/vault.aegirovault", text: $path)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") { choosePath() }
                            .buttonStyle(.bordered)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Passphrase")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Group {
                            if showPassphrase {
                                TextField("At least 8 characters", text: $passphrase)
                            } else {
                                SecureField("At least 8 characters", text: $passphrase)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        Button {
                            showPassphrase.toggle()
                        } label: {
                            Image(systemName: showPassphrase ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Toggle(isOn: $touchIDEnabled) {
                    Label("Enable Touch ID", systemImage: "touchid")
                }
                .disabled(!model.supportsBiometricUnlock)

                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(AegiroPalette.orange)
                }

                HStack {
                    Spacer()
                    Button("Create Vault") {
                        create()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AegiroPalette.primaryBlue)
                    .disabled(!canCreate)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AegiroPalette.iceBlue.opacity(0.8), lineWidth: 1)
        )
    }

    private var footer: some View {
        HStack {
            Label("Data stays local on this Mac", systemImage: "checkmark.shield")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Link("Privacy & Security", destination: URL(string: "https://aegiro.app/privacy")!)
                .font(.footnote)
        }
        .frame(maxWidth: .infinity)
    }

    private func choosePath() {
        let panel = NSSavePanel()
        panel.title = "Create Aegiro Vault"
        panel.nameFieldStringValue = (path as NSString).lastPathComponent
        panel.allowedContentTypes = [UTType(filenameExtension: "aegirovault") ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            path = ensuredVaultPath(from: url.path)
        }
    }

    private func create() {
        path = ensuredVaultPath(from: path)
        model.allowTouchID = touchIDEnabled && model.supportsBiometricUnlock
        model.saveSettings()
        model.createVault(at: URL(fileURLWithPath: path), passphrase: passphrase, touchID: touchIDEnabled && model.supportsBiometricUnlock)
        if model.vaultURL != nil {
            onDone()
        } else {
            errorText = model.status
        }
    }

    private func openExisting() {
        model.openVaultWithPanel()
        if model.vaultURL != nil {
            onDone()
        } else if !model.status.isEmpty {
            errorText = model.status
        }
    }

    private var canCreate: Bool {
        isLocationValid && passphrase.count >= 8
    }

    private var isLocationValid: Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.lowercased().hasSuffix(".aegirovault")
    }

    private func ensuredVaultPath(from source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.lowercased().hasSuffix(".aegirovault") else { return trimmed }
        return trimmed + ".aegirovault"
    }

    private func valueProp(icon: String, title: String) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.semibold))
    }
}
