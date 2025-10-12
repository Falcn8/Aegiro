
import SwiftUI
import UniformTypeIdentifiers

struct FirstRunView: View {
    @EnvironmentObject var model: VaultModel
    var onDone: () -> Void
    @State private var pass = ""
    @State private var hint = ""
    @State private var touch = true
    @State private var path: String = defaultVaultURL().path
    @State private var errorText: String?
    var body: some View {
        VStack(spacing: 16) {
            Text("Local. Quantum-safe. No cloud.").font(.title2).bold()
            HStack {
                TextField("Vault path", text: $path).textFieldStyle(.roundedBorder)
                Button { choosePath() } label: { Image(systemName: "folder").padding(6) }
            }
            SecureField("Passphrase (min 12 chars)", text: $pass)
            Toggle("Enable Touch ID (device-only)", isOn: $touch)
            TextField("Passphrase hint (stored locally)", text: $hint)
            if let e = errorText { Text(e).foregroundStyle(.red).font(.footnote) }
            HStack {
                Spacer()
                Button("Create Vault") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(pass.count < 12 || path.isEmpty)
            }
        }.padding(24).frame(width: 560)
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
        model.createVault(at: url, passphrase: pass, touchID: touch)
        if model.vaultURL != nil {
            onDone()
        } else {
            errorText = model.status
        }
    }
}
