
import SwiftUI
import UniformTypeIdentifiers

struct FirstRunView: View {
    @EnvironmentObject var model: VaultModel
    var onDone: () -> Void
    @State private var passphrase = ""
    @State private var hint = ""
    @State private var touchIDEnabled = true
    @State private var path: String = defaultVaultURL().path
    @State private var errorText: String?
    var body: some View {
        ZStack {
            LinearGradient(colors: [
                Color.accentColor.opacity(0.12),
                Color(nsColor: .windowBackgroundColor)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()

            VStack(spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Welcome to Aegiro")
                        .font(.largeTitle.weight(.bold))
                    Text("Create a vault to keep your files encrypted, local, and quantum-safe.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 32) {
                    leftColumn
                    Divider()
                        .frame(maxHeight: .infinity)
                    formColumn
                }
                .frame(maxHeight: .infinity)
                .padding(32)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                footer
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 48)
            .frame(maxWidth: 900, maxHeight: 560)
        }
        .onAppear {
            touchIDEnabled = model.allowTouchID
        }
    }

    func choosePath() {
        let panel = NSSavePanel()
        panel.title = "Create Aegiro Vault"
        panel.nameFieldStringValue = (path as NSString).lastPathComponent
        let vt = UTType(filenameExtension: "aegirovault") ?? .data
        panel.allowedContentTypes = [vt]
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }

    func create() {
        let url = URL(fileURLWithPath: path)
        model.allowTouchID = touchIDEnabled
        model.saveSettings()
        model.createVault(at: url, passphrase: passphrase, touchID: touchIDEnabled)
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

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 16) {
                valueProp(title: "Zero trust surface", detail: "Vault lives on disk with PQ-safe signatures.")
                valueProp(title: "Bring your own files", detail: "Drag & drop imports; no outbound traffic.")
                valueProp(title: "Auto-lock timers", detail: "Set device-local timeouts to keep sessions short.")
            }
            VStack(alignment: .leading, spacing: 12) {
                Button("Open Existing Vault…") {
                    openExisting()
                }
                .buttonStyle(.plain)
                .font(.headline)
                .underline()
                .foregroundStyle(Color.accentColor)
                Text("Already have a vault? Open it to unlock and continue.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 260, alignment: .leading)
    }

    private var formColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Create a new vault")
                    .font(.title2.weight(.semibold))
                Text("Choose where the encrypted bundle lives and set a strong passphrase.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 14) {
                LabeledContent("Vault Location") {
                    HStack(spacing: 10) {
                        TextField("/path/to/vault.aegirovault", text: $path)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 260)
                        Button {
                            choosePath()
                        } label: {
                            Label("Choose…", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                SecureField("Passphrase (min 12 characters)", text: $passphrase)
                    .textFieldStyle(.roundedBorder)
                PassphraseStrengthView(passphrase: passphrase)
                TextField("Hint (stored locally, optional)", text: $hint)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle(isOn: $touchIDEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Allow Touch ID on this Mac")
                    Text("Biometric unlock is stored in the Secure Enclave and never leaves the device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Create Vault") {
                    create()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.square.stack.fill")
                .foregroundStyle(.secondary)
            Text("Aegiro stores everything locally. Nothing is uploaded or shared unless you export it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Link("Privacy & Security", destination: URL(string: "https://aegiro.app/privacy")!)
                .font(.footnote)
        }
        .frame(maxWidth: .infinity)
    }

    private var canCreate: Bool {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPath.hasSuffix(".aegirovault") && passphrase.count >= 12
    }

    private func valueProp(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PassphraseStrengthView: View {
    let passphrase: String

    private var strength: Strength {
        Strength.evaluate(passphrase: passphrase)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(strength.label)
                    .font(.caption)
                    .foregroundStyle(strength.color)
                Spacer()
                Text("\(passphrase.count) characters")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: strength.progress)
                .accentColor(strength.color)
        }
        .accessibilityLabel("Passphrase strength \(strength.label)")
    }

    private enum Strength {
        case empty
        case weak
        case medium
        case strong

        var label: String {
            switch self {
            case .empty: return "Enter a passphrase"
            case .weak: return "Weak"
            case .medium: return "Getting stronger"
            case .strong: return "Looks strong"
            }
        }

        var color: Color {
            switch self {
            case .empty: return .secondary
            case .weak: return .red
            case .medium: return .yellow
            case .strong: return .green
            }
        }

        var progress: Double {
            switch self {
            case .empty: return 0
            case .weak: return 0.33
            case .medium: return 0.66
            case .strong: return 1
            }
        }

        static func evaluate(passphrase: String) -> Strength {
            let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .empty }
            var score = 0
            if trimmed.count >= 12 { score += 1 }
            if trimmed.rangeOfCharacter(from: .decimalDigits) != nil { score += 1 }
            if trimmed.rangeOfCharacter(from: .uppercaseLetters) != nil { score += 1 }
            if trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "!@#$%^&*()-_=+[]{}|;:'\",.<>/?`~\\")) != nil { score += 1 }
            if trimmed.count >= 18 { score += 1 }

            switch score {
            case 0...1: return .weak
            case 2...3: return .medium
            default: return .strong
            }
        }
    }
}
