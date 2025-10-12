
import SwiftUI

struct MainView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Label("All Files", systemImage: "folder")
                Label("Documents", systemImage: "doc.text")
                Label("Photos", systemImage: "photo")
                Label("IDs", systemImage: "person.text.rectangle")
                Label("Backups", systemImage: "archivebox")
                Label("Shredded", systemImage: "trash")
                Label("Settings", systemImage: "gearshape")
            }
        } detail: {
            VStack {
                HStack {
                    Button("Add Files") {}
                    Button("New Folder") {}
                    Spacer()
                    Button("Lock") {}
                }
                .padding()
                Spacer()
                Text("Vault locked").foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}
