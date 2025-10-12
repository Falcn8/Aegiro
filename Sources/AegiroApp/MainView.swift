import SwiftUI
import AppKit
import AegiroCore
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject var model: VaultModel

    @State private var showUnlockSheet = false
    @State private var unlockPass = ""
    @State private var activeFilter: VaultFilter = .all
    @State private var viewMode: ContentViewMode = .list
    @State private var sortOption: SortOption = .name
    @State private var sortAscending = true
    @State private var searchText = ""
    @State private var searchQuery = ""
    @State private var searchDebounceTask: DispatchWorkItem?
    @State private var selection: Set<VaultIndexEntry.ID> = []
    @State private var showPreferences = false
    @State private var showInfoDrawer = false
    @State private var toastMessage: String?
    @State private var toastDismissWork: DispatchWorkItem?
    @State private var lastGridAnchor: VaultIndexEntry.ID?

    private let recentInterval: TimeInterval = 60 * 60 * 24 * 7

    private var filteredEntries: [VaultIndexEntry] {
        let filtered = applyFilter(to: model.entries)
        let searched = applySearch(to: filtered)
        return applySort(to: searched)
    }

    private var selectedEntries: [VaultIndexEntry] {
        filteredEntries.filter { selection.contains($0.id) }
    }

    private var selectedSize: Int64 {
        selectedEntries.reduce(0) { $0 + Int64($1.size) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    contentArea
                    Divider()
                    statusBar
                }
                if let toastMessage {
                    ToastBanner(message: toastMessage)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 840, minHeight: 520)
        .sheet(isPresented: $showUnlockSheet) { unlockSheet }
        .sheet(isPresented: $showPreferences) {
            PreferencesView()
                .environmentObject(model)
        }
        .onAppear {
            model.refreshStatus()
            model.startAutoLockTimer()
        }
        .onChange(of: searchText) { _ in scheduleSearchDebounce() }
        .onChange(of: activeFilter) { _ in trimSelection() }
        .onChange(of: searchQuery) { _ in trimSelection() }
        .onReceive(model.$entries) { _ in trimSelection() }
        .onReceive(model.$status) { updateToast(with: $0) }
        .onDisappear {
            searchDebounceTask?.cancel()
            toastDismissWork?.cancel()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            vaultHeader
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                sidebarButton(title: "Open Vault…", systemImage: "folder") {
                    activeFilter = .all
                    model.openVaultWithPanel()
                }
                sidebarButton(title: "Add Files…", systemImage: "square.and.arrow.down") {
                    model.importFiles()
                }
                sidebarButton(title: "Export…", systemImage: "square.and.arrow.up") {
                    exportSelection()
                }
                sidebarButton(title: model.locked ? "Unlock…" : "Lock", systemImage: model.locked ? "lock.open" : "lock") {
                    if model.locked {
                        showUnlockSheet = true
                    } else {
                        model.lockNow()
                        selection.removeAll()
                    }
                }
                sidebarButton(title: "Preferences…", systemImage: "gearshape") {
                    showPreferences = true
                }
            }
            Spacer()
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
        .frame(width: 288, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func sidebarButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                Text(title)
                Spacer()
            }
            .font(.headline)
            .foregroundStyle(.primary)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var vaultHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.vaultURL?.lastPathComponent ?? "No Vault Selected")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
            }
            HStack(spacing: 8) {
                StatusChip(
                    text: model.locked ? "Locked" : "Unlocked",
                    symbol: model.locked ? "lock.fill" : "lock.open.fill",
                    color: model.locked ? .red : .green
                )
                StatusChip(
                    text: model.manifestOK ? "Manifest OK" : "Manifest Alert",
                    symbol: model.manifestOK ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                    color: model.manifestOK ? .green : .yellow
                )
            }
            HStack {
                Label("Pending Imports", systemImage: "tray.and.arrow.down")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(model.sidecarPending)")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(model.sidecarPending > 0 ? 0.25 : 0.15), in: Capsule())
                    .foregroundStyle(model.sidecarPending > 0 ? Color.accentColor : .secondary)
                    .accessibilityLabel("\(model.sidecarPending) pending imports")
            }
            if !model.status.isEmpty {
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                if model.locked {
                    showUnlockSheet = true
                } else {
                    model.lockNow()
                    selection.removeAll()
                }
            } label: {
                Label(model.locked ? "Unlock" : "Lock", systemImage: model.locked ? "lock.open" : "lock")
                    .labelStyle(.titleAndIcon)
                    .frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent)
            .help(model.locked ? "Unlock the current vault" : "Lock and seal the current vault")

            Button {
                model.importFiles()
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .help("Import files into the sidecar")

            Button {
                exportSelection()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .disabled(selection.isEmpty)
            .help(selection.isEmpty ? "Select files to export" : "Export selected files")

            Button {
                quickLookSelection()
            } label: {
                Label("Quick Look", systemImage: "eye")
            }
            .buttonStyle(.bordered)
            .disabled(selection.isEmpty)
            .help(selection.isEmpty ? "Select files to preview" : "Preview selection with Quick Look")

            Divider()

            searchField

            Picker("View Mode", selection: $viewMode) {
                Label("List", systemImage: "list.bullet.rectangle").tag(ContentViewMode.list)
                Label("Grid", systemImage: "square.grid.2x2").tag(ContentViewMode.grid)
            }
            .pickerStyle(.segmented)
            .frame(width: 130)
            .help("Toggle between list and grid layouts")

            Menu {
                Picker("Sort by", selection: $sortOption) {
                    ForEach(SortOption.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                Divider()
                Button {
                    sortAscending.toggle()
                } label: {
                    Label(sortAscending ? "Ascending" : "Descending", systemImage: sortAscending ? "arrow.up" : "arrow.down")
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .help("Change sort order")

            Menu {
                filterMenuButton(.all, title: "All Files", symbol: "tray.full")
                filterMenuButton(.recentlyAdded, title: "Recently Added", symbol: "clock.badge.plus")
                filterMenuButton(.recentlyModified, title: "Recently Modified", symbol: "clock.arrow.circlepath")
            } label: {
                Label(filterMenuTitle, systemImage: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .help("Filter file list")

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showInfoDrawer.toggle()
                }
            } label: {
                Label(showInfoDrawer ? "Hide Info" : "Show Info", systemImage: "sidebar.right")
            }
            .buttonStyle(.bordered)
            .help("Toggle the info drawer")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $searchText, prompt: Text("Search files"))
                .textFieldStyle(.plain)
                .accessibilityLabel("Search files")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .frame(minWidth: 200, maxWidth: 260)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var contentArea: some View {
        HStack(spacing: 0) {
            Group {
                if viewMode == .list {
                    tableView
                } else {
                    gridView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showInfoDrawer {
                Divider()
                InfoDrawer(
                    entry: selectedEntries.first,
                    selectionCount: selection.count,
                    selectedSize: selectedSize,
                    onQuickLook: quickLookSelection,
                    onExport: exportSelection,
                    onReveal: { entry in model.revealExport(logicalPath: entry.logicalPath) },
                    onRevealOriginal: { entry in model.revealOriginal(logicalPath: entry.logicalPath) },
                    onCopyName: { entry in model.copyPathToClipboard(entry.displayName) },
                    onCopyLogicalPath: { entry in model.copyPathToClipboard(entry.logicalPath) }
                )
                .frame(width: 280)
            }
        }
    }

    private var tableView: some View {
        Table(filteredEntries, selection: $selection) {
            TableColumn("Name") { entry in
                FileRow(entry: entry, isSelected: selection.contains(entry.id))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { open(entry) }
                    .contextMenu { contextMenu(for: entry) }
            }
            TableColumn("Size") { entry in
                Text(entry.formattedSize)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            TableColumn("MIME") { entry in
                Text(entry.mime)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            TableColumn("Modified") { entry in
                Text(entry.modified.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                ForEach(filteredEntries) { entry in
                    GridTile(entry: entry, isSelected: selection.contains(entry.id))
                        .onTapGesture {
                            handleGridSelection(for: entry)
                        }
                        .onTapGesture(count: 2) { open(entry) }
                        .contextMenu { contextMenu(for: entry) }
                }
            }
            .padding(16)
        }
    }

    private func contextMenu(for entry: VaultIndexEntry) -> some View {
        Group {
            Button("Quick Look") { model.quickLook(logicalPath: entry.logicalPath) }
            if selection.count > 1 {
                Button("Quick Look Selection") { quickLookSelection() }
            }
            Divider()
            Button("Export…") { model.exportSelectedWithPanel(filters: [entry.logicalPath]) }
            Button("Reveal in Finder") { model.revealExport(logicalPath: entry.logicalPath) }
            Button("Reveal Original") { model.revealOriginal(logicalPath: entry.logicalPath) }
            Divider()
            Button("Copy Name") { model.copyPathToClipboard(entry.displayName) }
            Button("Copy Path") { model.copyPathToClipboard(entry.logicalPath) }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text("\(filteredEntries.count) items")
            if !selection.isEmpty {
                Text("• \(selection.count) selected")
                Text("• \(ByteCountFormatter.fileFormatter.string(fromByteCount: selectedSize))")
            }
            Spacer()
            if let url = model.vaultURL {
                Text(url.path)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var unlockSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Unlock Vault")
                .font(.title3)
                .bold()
            SecureField("Passphrase", text: $unlockPass)
                .textFieldStyle(.roundedBorder)
                .onSubmit(unlockIfPossible)
            if model.allowTouchID {
                Label("Touch ID is enabled in Preferences. Rest your finger on the sensor after submitting.", systemImage: "touchid")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    unlockPass = ""
                    showUnlockSheet = false
                }
                Button("Unlock") {
                    unlockIfPossible()
                }
                .buttonStyle(.borderedProminent)
                .disabled(unlockPass.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func unlockIfPossible() {
        let pass = unlockPass.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pass.isEmpty else { return }
        model.unlock(with: pass)
        unlockPass = ""
        showUnlockSheet = false
    }

    private func quickLookSelection() {
        let targets = selection
        guard !targets.isEmpty else { return }
        model.quickLookSelection(filters: Array(targets))
    }

    private func exportSelection() {
        let targets = selection
        guard !targets.isEmpty else {
            model.exportSelectedWithPanel()
            return
        }
        model.exportSelectedWithPanel(filters: Array(targets))
    }

    private func open(_ entry: VaultIndexEntry) {
        model.quickLook(logicalPath: entry.logicalPath)
    }

    private func applyFilter(to entries: [VaultIndexEntry]) -> [VaultIndexEntry] {
        let now = Date()
        switch activeFilter {
        case .all:
            return entries
        case .recentlyAdded:
            let cutoff = now.addingTimeInterval(-recentInterval)
            return entries.filter { $0.created >= cutoff }
        case .recentlyModified:
            let cutoff = now.addingTimeInterval(-recentInterval)
            return entries.filter { $0.modified >= cutoff }
        }
    }

    private func applySearch(to entries: [VaultIndexEntry]) -> [VaultIndexEntry] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.logicalPath.localizedCaseInsensitiveContains(query) ||
            $0.mime.localizedCaseInsensitiveContains(query)
        }
    }

    private func applySort(to entries: [VaultIndexEntry]) -> [VaultIndexEntry] {
        let sorted = entries.sorted { lhs, rhs in
            sortOption.compare(lhs, rhs)
        }
        return sortAscending ? sorted : sorted.reversed()
    }

    private func scheduleSearchDebounce() {
        searchDebounceTask?.cancel()
        let text = searchText
        let task = DispatchWorkItem { searchQuery = text }
        searchDebounceTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: task)
    }

    private func trimSelection() {
        let visible = Set(filteredEntries.map(\.id))
        selection = selection.filter { visible.contains($0) }
        if let anchor = selection.first {
            lastGridAnchor = anchor
        } else {
            lastGridAnchor = nil
        }
    }

    private func updateToast(with message: String) {
        guard !message.isEmpty else {
            withAnimation(.easeOut(duration: 0.15)) { toastMessage = nil }
            toastDismissWork?.cancel()
            return
        }
        toastDismissWork?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            toastMessage = message
        }
        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.2)) {
                toastMessage = nil
            }
        }
        toastDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func handleGridSelection(for entry: VaultIndexEntry) {
        guard let event = NSApp.currentEvent else {
            selection = [entry.id]
            lastGridAnchor = entry.id
            return
        }
        let flags = event.modifierFlags
        if flags.contains(.shift), let anchor = lastGridAnchor,
           let start = filteredEntries.firstIndex(where: { $0.id == anchor }),
           let end = filteredEntries.firstIndex(where: { $0.id == entry.id }) {
            let lower = min(start, end)
            let upper = max(start, end)
            let rangeIDs = filteredEntries[lower...upper].map(\.id)
            selection.formUnion(rangeIDs)
        } else if flags.contains(.command) {
            if selection.contains(entry.id) {
                selection.remove(entry.id)
            } else {
                selection.insert(entry.id)
            }
            lastGridAnchor = entry.id
        } else {
            selection = [entry.id]
            lastGridAnchor = entry.id
        }
    }

    private var filterMenuTitle: String {
        switch activeFilter {
        case .all: return "All Files"
        case .recentlyAdded: return "Recently Added"
        case .recentlyModified: return "Recently Modified"
        }
    }

    @ViewBuilder
    private func filterMenuButton(_ filter: VaultFilter, title: String, symbol: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                activeFilter = filter
            }
        } label: {
            HStack {
                Image(systemName: symbol)
                Text(title)
                Spacer()
                if activeFilter == filter {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

}

private struct FileRow: View {
    let entry: VaultIndexEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: FileIconProvider.shared.icon(for: entry))
                .resizable()
                .frame(width: 20, height: 20)
                .cornerRadius(4)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(entry.folderPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
    }
}

private struct GridTile: View {
    let entry: VaultIndexEntry
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(nsImage: FileIconProvider.shared.largeIcon(for: entry))
                .resizable()
                .frame(width: 48, height: 48)
                .cornerRadius(8)
            Text(entry.displayName)
                .font(.headline)
                .lineLimit(2)
            Text(entry.formattedSize)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 140)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
    }
}

private struct InfoDrawer: View {
    let entry: VaultIndexEntry?
    let selectionCount: Int
    let selectedSize: Int64
    let onQuickLook: () -> Void
    let onExport: () -> Void
    let onReveal: (VaultIndexEntry) -> Void
    let onRevealOriginal: (VaultIndexEntry) -> Void
    let onCopyName: (VaultIndexEntry) -> Void
    let onCopyLogicalPath: (VaultIndexEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let entry {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(nsImage: FileIconProvider.shared.largeIcon(for: entry))
                            .resizable()
                            .frame(width: 48, height: 48)
                            .cornerRadius(8)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.displayName)
                                .font(.headline)
                                .lineLimit(2)
                            Text(entry.folderPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledValueView(title: "Size", value: entry.formattedSize)
                        LabeledValueView(title: "MIME", value: entry.mime)
                        LabeledValueView(title: "Modified", value: entry.modified.formatted(date: .abbreviated, time: .shortened))
                        LabeledValueView(title: "Created", value: entry.created.formatted(date: .abbreviated, time: .shortened))
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            onQuickLook()
                        } label: {
                            Label("Quick Look Selection", systemImage: "eye")
                        }
                        Button {
                            onExport()
                        } label: {
                            Label("Export Selection…", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            onReveal(entry)
                        } label: {
                            Label("Reveal in Finder", systemImage: "folder")
                        }
                        Button {
                            onRevealOriginal(entry)
                        } label: {
                            Label("Reveal Original", systemImage: "doc.text.magnifyingglass")
                        }
                        Divider()
                        Button {
                            onCopyName(entry)
                        } label: {
                            Label("Copy Name", systemImage: "doc.on.doc")
                        }
                        Button {
                            onCopyLogicalPath(entry)
                        } label: {
                            Label("Copy Logical Path", systemImage: "doc.on.clipboard")
                        }
                    }
                }
            } else if selectionCount > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(selectionCount) items selected")
                        .font(.headline)
                    Text(ByteCountFormatter.fileFormatter.string(fromByteCount: selectedSize))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button {
                        onQuickLook()
                    } label: {
                        Label("Quick Look Selection", systemImage: "eye")
                    }
                    Button {
                        onExport()
                    } label: {
                        Label("Export Selection…", systemImage: "square.and.arrow.up")
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Nothing selected")
                        .font(.headline)
                    Text("Choose a file to see details and quick actions.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(16)
    }
}

private struct LabeledValueView: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .lineLimit(2)
        }
    }
}

private struct StatusChip: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(text)
                .foregroundStyle(.primary)
        }
        .font(.caption.weight(.medium))
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .background(
            Capsule()
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            Capsule()
                .stroke(color.opacity(0.35), lineWidth: 1)
        )
    }
}

private struct ToastBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
            Text(message)
        }
        .font(.footnote)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(radius: 4, y: 2)
    }
}

private enum ContentViewMode: Hashable {
    case list
    case grid
}

private enum VaultFilter: Hashable {
    case all
    case recentlyAdded
    case recentlyModified
}

private enum SortOption: CaseIterable {
    case name
    case size
    case mime
    case modified

    var title: String {
        switch self {
        case .name: return "Name"
        case .size: return "Size"
        case .mime: return "MIME"
        case .modified: return "Modified"
        }
    }

    func compare(_ lhs: VaultIndexEntry, _ rhs: VaultIndexEntry) -> Bool {
        switch self {
        case .name:
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        case .size:
            return lhs.size < rhs.size
        case .mime:
            return lhs.mime.localizedCaseInsensitiveCompare(rhs.mime) == .orderedAscending
        case .modified:
            return lhs.modified < rhs.modified
        }
    }
}

private final class FileIconProvider {
    static let shared = FileIconProvider()

    private var smallCache: [String: NSImage] = [:]
    private var largeCache: [String: NSImage] = [:]

    private init() {}

    func icon(for entry: VaultIndexEntry) -> NSImage {
        icon(for: entry, cache: &smallCache, size: 24)
    }

    func largeIcon(for entry: VaultIndexEntry) -> NSImage {
        icon(for: entry, cache: &largeCache, size: 48)
    }

    private func icon(for entry: VaultIndexEntry, cache: inout [String: NSImage], size: CGFloat) -> NSImage {
        let ext = (entry.logicalPath as NSString).pathExtension.lowercased()
        let key = ext.isEmpty ? "__default__" : ext
        if let cached = cache[key] {
            return cached
        }
        let type: UTType
        if ext.isEmpty {
            type = .data
        } else if let resolved = UTType(filenameExtension: ext) {
            type = resolved
        } else {
            type = .data
        }
        let image = NSWorkspace.shared.icon(for: type)
        image.size = NSSize(width: size, height: size)
        cache[key] = image
        return image
    }
}

extension VaultIndexEntry: Identifiable {
    public var id: String { logicalPath }
}

extension VaultIndexEntry: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(logicalPath)
    }

    public static func == (lhs: VaultIndexEntry, rhs: VaultIndexEntry) -> Bool {
        lhs.logicalPath == rhs.logicalPath
    }
}

private extension VaultIndexEntry {
    var displayName: String {
        (logicalPath as NSString).lastPathComponent
    }

    var folderPath: String {
        let parent = (logicalPath as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    var formattedSize: String {
        ByteCountFormatter.fileFormatter.string(fromByteCount: Int64(size))
    }
}

private extension ByteCountFormatter {
    static let fileFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()
}
