
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
        GeometryReader { proxy in
            let horizontalPadding: CGFloat = proxy.size.width > 900 ? 80 : 48
            let cardWidth = min(proxy.size.width - (horizontalPadding * 2), 740)
            let cardPadding: CGFloat = proxy.size.height > 600 ? 32 : 24

            ZStack {
                LinearGradient(colors: [
                    Color.accentColor.opacity(0.12),
                    Color(nsColor: .windowBackgroundColor)
                ], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Set up your vault")
                                .font(.system(size: 32, weight: .bold))
                            Text("Create an encrypted vault or open one you already use.")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(spacing: 0) {
                            HStack(spacing: 24) {
                                leftColumn
                                Divider()
                                    .frame(maxHeight: .infinity)
                                formColumn
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(cardPadding)
                        }
                        .frame(maxWidth: cardWidth)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                        footer
                    }
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, 36)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
            }
        }
        .onAppear { touchIDEnabled = model.allowTouchID }
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
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 12) {
                valueProp(icon: "internaldrive", title: "Local only")
                valueProp(icon: "shield.lefthalf.filled", title: "PQ-safe signing")
                valueProp(icon: "timer", title: "Auto-lock timers")
            }
            VStack(alignment: .leading, spacing: 12) {
                Button("Open Existing Vault…") { openExisting() }
                .buttonStyle(.plain)
                .font(.headline)
                .underline()
                .foregroundStyle(Color.accentColor)
                Text("Already have one? Keep working from it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 220, alignment: .leading)
    }

    private var formColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Create new vault")
                    .font(.title2.weight(.semibold))
                Text("Pick a location and a passphrase you can remember.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                FormField(label: "Vault location") {
                    HStack(spacing: 10) {
                        TextField("/path/to/vault.aegirovault", text: $path)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 240)
                        Button {
                            choosePath()
                        } label: {
                            Label("Choose…", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                FormField(label: "Passphrase") {
                    SecureField("Minimum 8 characters", text: $passphrase)
                        .textFieldStyle(.roundedBorder)
                }
                PassphraseStrengthView(passphrase: passphrase)
                FormField(label: "Hint (optional)") {
                    TextField("Only stored on this Mac", text: $hint)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Toggle(isOn: $touchIDEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Allow Touch ID on this Mac")
                    Text("Secure Enclave keeps the key on-device.")
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
            Text("Aegiro keeps data on disk until you choose to export.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Link("Privacy & Security", destination: URL(string: "https://aegiro.app/privacy")!)
                .font(.footnote)
        }
        .frame(maxWidth: .infinity)
    }

    private var canCreate: Bool {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPath.hasSuffix(".aegirovault") && passphrase.count >= 8
    }

private func valueProp(icon: String, title: String) -> some View {
    Label(title, systemImage: icon)
        .labelStyle(.titleAndIcon)
        .font(.callout.weight(.semibold))
    }
}

private struct PassphraseStrengthView: View {
    let passphrase: String

    private var strength: Strength {
        Strength.evaluate(passphrase: passphrase)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(strength.label)
                    .font(.footnote)
                    .foregroundStyle(strength.color)
                Spacer()
                Text("\(passphrase.count) characters")
                    .font(.footnote.monospacedDigit())
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
            if trimmed.count >= 8 { score += 1 }
            if trimmed.rangeOfCharacter(from: .decimalDigits) != nil { score += 1 }
            if trimmed.rangeOfCharacter(from: .uppercaseLetters) != nil { score += 1 }
            if trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "!@#$%^&*()-_=+[]{}|;:'\",.<>/?`~\\")) != nil { score += 1 }
            if trimmed.count >= 14 { score += 1 }

            switch score {
            case 0...1: return .weak
            case 2...3: return .medium
            default: return .strong
            }
        }
    }
}

private struct FormField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}
