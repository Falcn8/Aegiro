
import SwiftUI
import AppKit
import AegiroCore

struct MainView: View {
    @EnvironmentObject var model: VaultModel
    @State private var showUnlockSheet = false
    @State private var unlockPass = ""
    @State private var filterText = ""
    @State private var selection: Set<String> = []
    @State private var showPrefs = false
    @State private var sortKey: String = "Name"
    @State private var sortAscending: Bool = true

    var filteredEntries: [VaultIndexEntry] {
        if filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sorted(model.entries)
        }
        return sorted(model.entries.filter { $0.logicalPath.localizedCaseInsensitiveContains(filterText) })
    }

    func sorted(_ arr: [VaultIndexEntry]) -> [VaultIndexEntry] {
        let sorted: [VaultIndexEntry]
        switch sortKey {
        case "Size":
            sorted = arr.sorted { $0.size < $1.size }
        case "MIME":
            sorted = arr.sorted { $0.mime.localizedCaseInsensitiveCompare($1.mime) == .orderedAscending }
        case "Modified":
            sorted = arr.sorted { $0.modified < $1.modified }
        default:
            sorted = arr.sorted { ($0.logicalPath as NSString).lastPathComponent.localizedCaseInsensitiveCompare(($1.logicalPath as NSString).lastPathComponent) == .orderedAscending }
        }
        return sortAscending ? sorted : sorted.reversed()
    }

    var body: some View {
        NavigationSplitView {
            List {
                Section("Vault") {
                    Label(model.vaultURL?.lastPathComponent ?? "No vault", systemImage: "lock.shield")
                    HStack {
                        Circle().frame(width: 8, height: 8).foregroundStyle(model.locked ? .red : .green)
                        Text(model.locked ? "Locked" : "Unlocked")
                    }
                    Label("Manifest: \(model.manifestOK ? "OK" : "INVALID")", systemImage: model.manifestOK ? "checkmark.seal" : "exclamationmark.triangle")
                    Label("Pending: \(model.sidecarPending)", systemImage: "tray.and.arrow.down")
                }
                Section("Actions") {
                    Button { model.openVaultWithPanel() } label: { Label("Open Vault…", systemImage: "folder") }
                    Button { model.importFiles() } label: { Label("Add Files", systemImage: "plus") }
                    Button { model.exportSelectedWithPanel() } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                    Button { if model.locked { showUnlockSheet = true } else { model.lockNow() } } label: {
                        Label(model.locked ? "Unlock…" : "Lock", systemImage: model.locked ? "lock.open" : "lock")
                    }
                    Button { showPrefs = true } label: { Label("Preferences…", systemImage: "gearshape") }
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 240)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass")
                    TextField("Filter", text: $filterText)
                    Divider()
                    Picker("Sort", selection: $sortKey) {
                        Text("Name").tag("Name")
                        Text("Size").tag("Size")
                        Text("MIME").tag("MIME")
                        Text("Modified").tag("Modified")
                    }.pickerStyle(.segmented).frame(width: 360)
                    Button(action: { sortAscending.toggle() }) {
                        Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                    }.help(sortAscending ? "Ascending" : "Descending")
                    Spacer()
                    Text(model.status).foregroundStyle(.secondary)
                }.padding(8).background(.thinMaterial)

                if model.locked {
                    VStack(spacing: 12) {
                        Text("Vault is locked").font(.title3)
                        Button("Unlock…") { showUnlockSheet = true }
                            .buttonStyle(.borderedProminent)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Size").frame(width: 100, alignment: .trailing)
                            Text("MIME").frame(width: 160, alignment: .leading)
                            Text("Modified").frame(width: 160, alignment: .leading)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Divider()
                        List(filteredEntries, id: \.logicalPath, selection: $selection) { e in
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFileType: ((e.logicalPath as NSString).pathExtension)))
                                    .resizable()
                                    .frame(width: 16, height: 16)
                                Text((e.logicalPath as NSString).lastPathComponent).frame(maxWidth: .infinity, alignment: .leading)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(e.size), countStyle: .file))
                                    .frame(width: 120, alignment: .trailing)
                                Text(e.mime).frame(width: 160, alignment: .leading)
                                Text(e.modified, style: .date).frame(width: 160, alignment: .leading)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { model.preview(logicalPath: e.logicalPath) }
                        }
                        .listStyle(.plain)
                        HStack {
                            let total = filteredEntries.count
                            let selected = selection.count
                            let selectedSize = filteredEntries.filter{ selection.contains($0.logicalPath) }.reduce(0) { $0 + Int($1.size) }
                            Text("\(total) items • \(selected) selected • \(ByteCountFormatter.string(fromByteCount: Int64(selectedSize), countStyle: .file))")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Export Selected…") { model.exportSelectedWithPanel(filters: Array(selection)) }
                                .disabled(selection.isEmpty)
                        }
                        .padding(8)
                    }
                }
            }
        }
        .sheet(isPresented: $showUnlockSheet) {
            VStack(spacing: 12) {
                Text("Unlock Vault").font(.title3).bold()
                SecureField("Passphrase", text: $unlockPass)
                HStack {
                    Spacer()
                    Button("Cancel") { showUnlockSheet = false }
                    Button("Unlock") { model.unlock(with: unlockPass); showUnlockSheet = false }
                        .buttonStyle(.borderedProminent)
                        .disabled(unlockPass.isEmpty)
                }
            }.padding(20).frame(width: 360)
        }
        .onAppear { model.refreshStatus(); model.startAutoLockTimer() }
        .sheet(isPresented: $showPrefs) { PreferencesView().environmentObject(model) }
    }
}
