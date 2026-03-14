import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct FirstRunView: View {
    @EnvironmentObject var model: VaultModel
    var onDone: () -> Void

    @State private var showCreateForm = false
    @State private var vaultName = "MyVault"
    @State private var parentPath: String = defaultVaultURL().deletingLastPathComponent().path
    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    @State private var touchIDEnabled = true
    @State private var errorText: String?
    @State private var showDiskEncryptSheet = false

    private var canCreate: Bool {
        passphraseStrength.isRequired && passphrase == confirmPassphrase
    }

    private var passphraseStrength: PassphraseStrengthReport {
        PassphraseStrengthReport.evaluate(passphrase)
    }

    private var effectivePath: String {
        let trimmedParent = parentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = vaultName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = trimmedName.isEmpty ? "MyVault" : trimmedName
        return URL(fileURLWithPath: trimmedParent, isDirectory: true)
            .appendingPathComponent("\(safeName).agvt")
            .path
    }

    var body: some View {
        ZStack {
            backgroundLayer

            VStack(spacing: 20) {
                heroShowcase
                Spacer(minLength: 12)
                actionCard
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
        }
        .frame(minWidth: 1080, minHeight: 720)
        .onAppear {
            touchIDEnabled = model.supportsBiometricUnlock && model.biometricKeychainAvailable && model.allowTouchID
        }
        .sheet(isPresented: $showDiskEncryptSheet) {
            DiskEncryptSheet {
                showDiskEncryptSheet = false
            }
            .environmentObject(model)
        }
    }

    private var backgroundLayer: some View {
        LinearGradient(
            colors: [
                AegiroPalette.backgroundMain,
                AegiroPalette.backgroundPanel
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var heroShowcase: some View {
        Group {
            if let image = AegiroResourceLocator.image(named: "LandingHero") {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Rectangle()
                    .fill(AegiroPalette.backgroundPanel)
            }
        }
        .frame(maxWidth: 1080, maxHeight: 470)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var actionCard: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Text("Encrypted Local Vault")
                    .font(AegiroTypography.display(20, weight: .medium))
                    .foregroundStyle(AegiroPalette.textSecondary)

                Text("Your files never leave your device.")
                    .font(AegiroTypography.body(14, weight: .regular))
                    .foregroundStyle(AegiroPalette.textSecondary)
            }

            HStack(spacing: 12) {
                Button("Create Vault") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showCreateForm = true
                        errorText = nil
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AegiroPalette.accentIndigo)

                Button("Open Existing") {
                    openExisting()
                }
                .buttonStyle(.bordered)

                Button("Encrypt Disk") {
                    showDiskEncryptSheet = true
                }
                .buttonStyle(.bordered)
            }

            if showCreateForm {
                createForm
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let errorText {
                Text(errorText)
                    .font(AegiroTypography.body(12, weight: .regular))
                    .foregroundStyle(AegiroPalette.dangerRed)
            }

            Text("Uses Argon2id, AES-256-GCM, and Post-Quantum Cryptography.")
                .font(AegiroTypography.body(12, weight: .regular))
                .foregroundStyle(AegiroPalette.textMuted)
        }
        .padding(28)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(AegiroPalette.backgroundCard.opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AegiroPalette.borderSubtle, lineWidth: 1)
        )
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            formLabel("Vault Name")
            TextField("MyVault", text: $vaultName)
                .textFieldStyle(.roundedBorder)

            formLabel("Location")
            HStack(spacing: 8) {
                TextField("/Users/...", text: $parentPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose...") {
                    chooseParentFolder()
                }
                .buttonStyle(.bordered)
            }

            formLabel("Passphrase")
            SecureField("8+ chars with upper/lower letters and numbers", text: $passphrase)
                .textFieldStyle(.roundedBorder)
            PassphraseStrengthMeter(passphrase: passphrase)

            formLabel("Confirm Passphrase")
            SecureField("Repeat passphrase", text: $confirmPassphrase)
                .textFieldStyle(.roundedBorder)

            Toggle("Enable Touch ID", isOn: $touchIDEnabled)
                .disabled(!model.supportsBiometricUnlock || !model.biometricKeychainAvailable)

            if let issue = model.biometricKeychainIssue {
                Text(issue)
                    .font(AegiroTypography.body(12, weight: .regular))
                    .foregroundStyle(AegiroPalette.warningAmber)
            }

            if !passphrase.isEmpty && !passphraseStrength.isRequired {
                Text("Passphrase must be 8+ chars and include uppercase, lowercase, and a number.")
                    .font(AegiroTypography.body(12, weight: .regular))
                    .foregroundStyle(AegiroPalette.warningAmber)
            }

            HStack {
                Button("Back") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showCreateForm = false
                    }
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Create Vault") {
                    createVault()
                }
                .buttonStyle(.borderedProminent)
                .tint(AegiroPalette.accentIndigo)
                .disabled(!canCreate)
            }
        }
    }

    private func formLabel(_ text: String) -> some View {
        Text(text)
            .font(AegiroTypography.body(12, weight: .semibold))
            .foregroundStyle(AegiroPalette.textSecondary)
    }

    private func openExisting() {
        model.openVaultWithPanel()
        if model.vaultURL != nil {
            onDone()
        } else if !model.status.isEmpty {
            errorText = model.status
        }
    }

    private func chooseParentFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            parentPath = url.path
        }
    }

    private func createVault() {
        guard passphraseStrength.isRequired else {
            errorText = "Passphrase is too weak. Use 8+ chars with uppercase, lowercase, and a number."
            return
        }
        model.allowTouchID = touchIDEnabled && model.supportsBiometricUnlock && model.biometricKeychainAvailable
        model.saveSettings()
        model.createVault(
            at: URL(fileURLWithPath: effectivePath),
            passphrase: passphrase,
            touchID: touchIDEnabled && model.supportsBiometricUnlock && model.biometricKeychainAvailable
        )
        if model.vaultURL != nil {
            onDone()
        } else {
            errorText = model.status
        }
    }
}
