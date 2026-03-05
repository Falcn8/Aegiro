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
    @State private var startMode: FirstRunMode = .openExisting

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [AegiroPalette.iceBlue.opacity(0.35), Color.white],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 22) {
                        heroHeader
                        contentCard
                        footer
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 28)
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
                }
            }
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
                Text("Set Up Your Vault")
                    .font(.system(size: 30, weight: .bold))
            }
            Text("Create a new vault or open one you already use.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var contentCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Start with", selection: $startMode) {
                Label("Open Existing", systemImage: "folder").tag(FirstRunMode.openExisting)
                Label("Create New", systemImage: "plus.circle").tag(FirstRunMode.createNew)
            }
            .pickerStyle(.segmented)

            if startMode == .openExisting {
                openExistingContent
            } else {
                createVaultContent
            }
        }
        .padding(24)
        .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AegiroPalette.iceBlue.opacity(0.8), lineWidth: 1)
        )
    }

    private var openExistingContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open Existing Vault")
                .font(.title3.weight(.semibold))

            Text("Start from a vault you already use, then continue with import and export workflows.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            valueProp(icon: "lock.open", title: "Unlock with your passphrase")
            valueProp(icon: "tray.and.arrow.down", title: "Import files directly into encrypted storage")
            valueProp(icon: "touchid", title: "Touch ID works when a passphrase is saved on this Mac")

            if let errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(AegiroPalette.orange)
            }

            HStack(spacing: 10) {
                Button {
                    openExisting()
                } label: {
                    Label("Open Vault", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
                .tint(AegiroPalette.primaryBlue)

                Button("Create New Vault") {
                    startMode = .createNew
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var createVaultContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create New Vault")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("Vault location")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("/path/to/vault.agvt", text: $path)
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
                Button("Open Existing Vault") {
                    startMode = .openExisting
                }
                .buttonStyle(.bordered)

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
        panel.title = "Create Vault (AegiroVault)"
        panel.nameFieldStringValue = (path as NSString).lastPathComponent
        panel.allowedContentTypes = [
            UTType(filenameExtension: "agvt") ?? .data,
            UTType(filenameExtension: "aegirovault") ?? .data
        ]
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
        let lowered = trimmed.lowercased()
        return !trimmed.isEmpty && (lowered.hasSuffix(".agvt") || lowered.hasSuffix(".aegirovault"))
    }

    private func ensuredVaultPath(from source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        guard !lowered.hasSuffix(".agvt") && !lowered.hasSuffix(".aegirovault") else { return trimmed }
        return trimmed + ".agvt"
    }

    private func valueProp(icon: String, title: String) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.semibold))
    }
}

private enum FirstRunMode: Hashable {
    case openExisting
    case createNew
}
