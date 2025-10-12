
import SwiftUI

struct FirstRunView: View {
    var onDone: () -> Void
    @State private var pass = ""
    @State private var hint = ""
    @State private var touch = true
    var body: some View {
        VStack(spacing: 16) {
            Text("Local. Quantum-safe. No cloud.").font(.title2).bold()
            SecureField("Passphrase (min 12 chars)", text: $pass)
            Toggle("Enable Touch ID (device-only)", isOn: $touch)
            TextField("Passphrase hint (stored locally)", text: $hint)
            Button("Create Vault") { onDone() }.disabled(pass.count < 12)
        }.padding(24).frame(width: 460)
    }
}
