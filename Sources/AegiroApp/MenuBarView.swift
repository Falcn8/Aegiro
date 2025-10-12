
import SwiftUI

struct MenuBarView: View {
    @State private var locked = true
    @State private var ttl = 300
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().frame(width: 8, height: 8).foregroundStyle(locked ? .red : .green)
                Text(locked ? "Locked" : "Unlocked")
                Spacer()
                Text("Auto-lock: \(ttl)s")
            }
            Divider()
            Button(locked ? "Unlock…" : "Lock Now") {}
            Button("Drop to encrypt…") {}
        }.padding(8).frame(width: 240)
    }
}
