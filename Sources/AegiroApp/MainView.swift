import SwiftUI
import AppKit
import AegiroCore
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject private var model: VaultModel

    @State private var showUnlockSheet = false
    @State private var unlockPass = ""
    @State private var showPreferences = false
    @State private var showCreateVaultSheet = false

    @State private var searchText = ""
    @State private var selection: Set<VaultIndexEntry.ID> = []
    @State private var viewMode: ContentViewMode = .list
    @State private var sortOption: SortOption = .modified
    @State private var sortAscending = false
    @State private var activeFilter: VaultFilter = .all

    @State private var toastMessage: String?
    @State private var toastDismissWork: DispatchWorkItem?

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
                    topBar
                    Divider()
                    contentArea
                    Divider()
                    statusBar
                }
                if let toastMessage {
                    Text(toastMessage)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .foregroundStyle(.white)
                        .background(AegiroPalette.deepNavy, in: Capsule())
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .background(AegiroPalette.iceBlue.opacity(0.08))
        }
        .frame(minWidth: 980, minHeight: 600)
        .sheet(isPresented: $showUnlockSheet) { unlockSheet }
        .sheet(isPresented: $showPreferences) {
            PreferencesView()
                .environmentObject(model)
        }
        .sheet(isPresented: $showCreateVaultSheet) {
            CreateVaultSheet {
                showCreateVaultSheet = false
            }
            .environmentObject(model)
        }
        .onAppear {
            model.refreshStatus()
            model.startAutoLockTimer()
        }
        .onReceive(model.$entries) { _ in
            selection = selection.intersection(Set(model.entries.map(\.id)))
        }
        .onReceive(model.$status) { updateToast(with: $0) }
        .onDisappear {
            toastDismissWork?.cancel()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            brandCard
            workflowCard

            VStack(spacing: 10) {
                actionButton(title: "Open Vault", icon: "folder") {
                    model.openVaultWithPanel()
                    activeFilter = .all
                }

                actionButton(title: "Create Vault", icon: "plus.circle") {
                    showCreateVaultSheet = true
                }

                actionButton(title: model.locked ? "Unlock Vault" : "Add to Sidecar", icon: model.locked ? "lock.open" : "tray.and.arrow.down") {
                    if model.locked {
                        showUnlockSheet = true
                    } else {
                        model.importFiles()
                    }
                }
                .disabled(model.vaultURL == nil)

                actionButton(title: "Lock and Import", icon: "lock") {
                    model.lockNow()
                    selection.removeAll()
                }
                .disabled(model.vaultURL == nil || model.locked || model.sidecarPending == 0)

                actionButton(title: "Export Selected", icon: "square.and.arrow.up") {
                    exportSelection()
                }
                .disabled(model.locked || selection.isEmpty)
            }

            Spacer()

            Button {
                showPreferences = true
            } label: {
                Label("Preferences", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(width: 300, alignment: .top)
        .background(
            LinearGradient(
                colors: [AegiroPalette.iceBlue.opacity(0.35), Color.white],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var brandCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(AegiroPalette.primaryBlue, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aegiro")
                        .font(.title3.weight(.bold))
                    Text("Secure vault workflow")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(model.vaultURL?.lastPathComponent ?? "No vault selected")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            HStack(spacing: 8) {
                statusChip(text: model.locked ? "Locked" : "Unlocked", color: model.locked ? AegiroPalette.orange : AegiroPalette.tealBlue, icon: model.locked ? "lock.fill" : "lock.open.fill")
                if !model.manifestOK {
                    statusChip(text: "Check", color: AegiroPalette.sunYellow, icon: "exclamationmark.triangle.fill")
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AegiroPalette.iceBlue.opacity(0.8), lineWidth: 1)
        )
    }

    private var workflowCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Simple flow")
                .font(.headline)
            workflowRow(number: 1, icon: "tray.and.arrow.down", text: "Add files to sidecar", done: model.sidecarPending > 0)
            workflowRow(number: 2, icon: "arrow.down.doc", text: "Import happens when you lock", done: !model.locked && model.sidecarPending == 0)
            workflowRow(number: 3, icon: "lock", text: "Lock vault to finalize", done: model.locked)

            Divider()

            HStack {
                Label("Pending", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(model.sidecarPending)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(model.sidecarPending > 0 ? AegiroPalette.orange : .secondary)
            }

            Text(workflowHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AegiroPalette.iceBlue.opacity(0.8), lineWidth: 1)
        )
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Label("", systemImage: "magnifyingglass")
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
            TextField("Search files", text: $searchText)
                .textFieldStyle(.plain)

            Divider()
                .frame(height: 18)

            Picker("Filter", selection: $activeFilter) {
                Text("All").tag(VaultFilter.all)
                Text("Recent").tag(VaultFilter.recentlyModified)
                Text("Added").tag(VaultFilter.recentlyAdded)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            Picker("View", selection: $viewMode) {
                Label("List", systemImage: "list.bullet").tag(ContentViewMode.list)
                Label("Grid", systemImage: "square.grid.2x2").tag(ContentViewMode.grid)
            }
            .pickerStyle(.segmented)
            .frame(width: 140)

            Spacer()

            Menu {
                Picker("Sort", selection: $sortOption) {
                    ForEach(SortOption.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                Button(sortAscending ? "Sort Descending" : "Sort Ascending") {
                    sortAscending.toggle()
                }
                Divider()
                Button("Quick Look Selection") { quickLookSelection() }
                    .disabled(model.locked || selection.isEmpty)
                Button("Export Selection") { exportSelection() }
                    .disabled(model.locked || selection.isEmpty)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private var contentArea: some View {
        if model.vaultURL == nil {
            emptyVaultState
        } else if model.locked {
            lockedState
        } else if filteredEntries.isEmpty {
            emptyFilesState
        } else {
            if viewMode == .list {
                listView
            } else {
                gridView
            }
        }
    }

    private var emptyVaultState: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 42))
                .foregroundStyle(AegiroPalette.primaryBlue)
            Text("Open or create a vault")
                .font(.title3.weight(.semibold))
            Text("Like leading file and notes apps, everything starts from one clear home screen.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 10) {
                Button {
                    model.openVaultWithPanel()
                } label: {
                    Label("Open Vault", systemImage: "folder")
                }
                .buttonStyle(.bordered)

                Button {
                    showCreateVaultSheet = true
                } label: {
                    Label("Create Vault", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(AegiroPalette.primaryBlue)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var lockedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 40))
                .foregroundStyle(AegiroPalette.deepNavy)
            Text("Vault is locked")
                .font(.title3.weight(.semibold))
            Text("Unlock to add files to sidecar or browse contents.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                showUnlockSheet = true
            } label: {
                Label("Unlock Vault", systemImage: "lock.open")
            }
            .buttonStyle(.borderedProminent)
            .tint(AegiroPalette.tealBlue)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyFilesState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(AegiroPalette.tealBlue)
            Text("No files yet")
                .font(.title3.weight(.semibold))
            Text("Add files to sidecar, then lock to import.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                model.importFiles()
            } label: {
                Label("Add Files to Sidecar", systemImage: "tray.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .tint(AegiroPalette.primaryBlue)
            .disabled(model.locked)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listView: some View {
        Table(filteredEntries, selection: $selection) {
            TableColumn("Name") { entry in
                HStack(spacing: 10) {
                    Image(systemName: entry.systemIcon)
                        .foregroundStyle(AegiroPalette.deepNavy)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.displayName)
                            .lineLimit(1)
                        Text(entry.folderPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .contextMenu { rowMenu(entry: entry) }
            }
            .width(min: 280, ideal: 360)

            TableColumn("Kind") { entry in
                Text(entry.kindDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            TableColumn("Size") { entry in
                Text(entry.formattedSize)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
            TableColumn("Modified") { entry in
                Text(entry.modified.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                ForEach(filteredEntries) { entry in
                    Button {
                        toggleSelection(entry)
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: entry.systemIcon)
                                    .font(.title3)
                                    .foregroundStyle(AegiroPalette.primaryBlue)
                                Spacer()
                                if selection.contains(entry.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(AegiroPalette.tealBlue)
                                }
                            }
                            Text(entry.displayName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(entry.formattedSize)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(selection.contains(entry.id) ? AegiroPalette.iceBlue.opacity(0.35) : Color.white)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(AegiroPalette.iceBlue.opacity(0.7), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu { rowMenu(entry: entry) }
                }
            }
            .padding(14)
        }
    }

    private func rowMenu(entry: VaultIndexEntry) -> some View {
        Group {
            Button("Quick Look") { model.quickLook(logicalPath: entry.logicalPath) }
                .disabled(model.locked)
            Button("Export") { model.exportSelectedWithPanel(filter: entry.logicalPath) }
                .disabled(model.locked)
            Divider()
            Button("Reveal in Finder") { model.revealExport(logicalPath: entry.logicalPath) }
                .disabled(model.locked)
            Button("Copy Name") { model.copyPathToClipboard(entry.displayName) }
            Button("Copy Path") { model.copyPathToClipboard(entry.logicalPath) }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Label("\(filteredEntries.count) files", systemImage: "doc.on.doc")
            if !selection.isEmpty {
                Text("• \(selection.count) selected")
                Text("• \(ByteCountFormatter.fileFormatter.string(fromByteCount: selectedSize))")
            }
            if !model.locked && model.autoLockRemaining > 0 {
                Text("• Auto-lock in \(formattedRemaining(model.autoLockRemaining))")
                    .foregroundStyle(AegiroPalette.deepNavy)
            }
            Spacer()
            Text(model.vaultURL?.path ?? "No active vault")
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var unlockSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Unlock Vault", systemImage: "lock.open")
                .font(.title3.weight(.bold))
            SecureField("Passphrase", text: $unlockPass)
                .textFieldStyle(.roundedBorder)
                .onSubmit(unlockIfPossible)

            if model.allowTouchID && model.supportsBiometricUnlock {
                Button {
                    model.unlockWithBiometrics()
                    showUnlockSheet = false
                } label: {
                    Label("Use Touch ID", systemImage: "touchid")
                }
                .buttonStyle(.bordered)
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
                .tint(AegiroPalette.primaryBlue)
                .disabled(unlockPass.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 360)
    }

    private func actionButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AegiroPalette.iceBlue.opacity(0.8), lineWidth: 1)
        )
    }

    private func statusChip(text: String, color: Color, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule())
    }

    private func workflowRow(number: Int, icon: String, text: String, done: Bool) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(done ? AegiroPalette.tealBlue.opacity(0.2) : Color.secondary.opacity(0.15))
                    .frame(width: 22, height: 22)
                Image(systemName: done ? "checkmark" : icon)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(done ? AegiroPalette.tealBlue : .secondary)
            }
            Text("\(number). \(text)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var workflowHint: String {
        if model.locked {
            return "Unlock, add files to sidecar, then lock to import."
        }
        if model.sidecarPending > 0 {
            return "Lock now to import staged files into encrypted storage."
        }
        return "Add files to sidecar to start your next import batch."
    }

    private func toggleSelection(_ entry: VaultIndexEntry) {
        if selection.contains(entry.id) {
            selection.remove(entry.id)
        } else {
            selection.insert(entry.id)
        }
    }

    private func unlockIfPossible() {
        let pass = unlockPass.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pass.isEmpty else { return }
        model.unlock(with: pass)
        unlockPass = ""
        showUnlockSheet = false
    }

    private func quickLookSelection() {
        guard !model.locked else {
            model.status = "Unlock to preview files"
            return
        }
        guard !selection.isEmpty else { return }
        model.quickLookSelection(filters: Array(selection))
    }

    private func exportSelection() {
        guard !model.locked else {
            model.status = "Unlock to export files"
            return
        }
        if selection.isEmpty {
            model.exportSelectedWithPanel()
        } else {
            model.exportSelectedWithPanel(filters: Array(selection))
        }
    }

    private func applyFilter(to entries: [VaultIndexEntry]) -> [VaultIndexEntry] {
        switch activeFilter {
        case .all:
            return entries
        case .recentlyAdded:
            let threshold = Date().addingTimeInterval(-(60 * 60 * 24 * 7))
            return entries.filter { $0.created >= threshold }
        case .recentlyModified:
            let threshold = Date().addingTimeInterval(-(60 * 60 * 24 * 7))
            return entries.filter { $0.modified >= threshold }
        }
    }

    private func applySearch(to entries: [VaultIndexEntry]) -> [VaultIndexEntry] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.displayName.localizedCaseInsensitiveContains(q)
            || $0.logicalPath.localizedCaseInsensitiveContains(q)
            || $0.mime.localizedCaseInsensitiveContains(q)
            || $0.tags.contains(where: { $0.localizedCaseInsensitiveContains(q) })
        }
    }

    private func applySort(to entries: [VaultIndexEntry]) -> [VaultIndexEntry] {
        entries.sorted { lhs, rhs in
            let result = sortOption.compare(lhs, rhs)
            return sortAscending ? result : !result
        }
    }

    private func formattedRemaining(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let remainder = total % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }

    private func updateToast(with text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        toastDismissWork?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            toastMessage = trimmed
        }
        let work = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.2)) {
                toastMessage = nil
            }
        }
        toastDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }
}

private struct CreateVaultSheet: View {
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) private var dismiss

    @State private var path: String = defaultVaultURL().path
    @State private var passphrase = ""
    @State private var allowTouchID = true

    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Create New Vault", systemImage: "plus.circle.fill")
                .font(.title3.weight(.bold))

            VStack(alignment: .leading, spacing: 8) {
                Text("Vault location")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("/path/to/vault.aegirovault", text: $path)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { choosePath() }
                        .buttonStyle(.bordered)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Passphrase")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                SecureField("At least 8 characters", text: $passphrase)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle(isOn: $allowTouchID) {
                Label("Enable Touch ID", systemImage: "touchid")
            }
            .disabled(!model.supportsBiometricUnlock)

            if !model.supportsBiometricUnlock {
                Text("Touch ID is unavailable for this vault configuration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Open Existing Vault") {
                    model.openVaultWithPanel()
                    if model.vaultURL != nil {
                        onDone()
                        dismiss()
                    }
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Cancel") { dismiss() }
                Button("Create") {
                    createVault()
                }
                .buttonStyle(.borderedProminent)
                .tint(AegiroPalette.primaryBlue)
                .disabled(passphrase.count < 8)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(
            LinearGradient(
                colors: [Color.white, AegiroPalette.iceBlue.opacity(0.2)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .onAppear {
            allowTouchID = model.supportsBiometricUnlock && model.allowTouchID
        }
    }

    private func choosePath() {
        let panel = NSSavePanel()
        panel.title = "Create Aegiro Vault"
        panel.nameFieldStringValue = (path as NSString).lastPathComponent
        panel.allowedContentTypes = [UTType(filenameExtension: "aegirovault") ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            path = ensuredVaultPath(from: url.path)
        }
    }

    private func createVault() {
        let safePath = ensuredVaultPath(from: path)
        model.createVault(at: URL(fileURLWithPath: safePath), passphrase: passphrase, touchID: allowTouchID && model.supportsBiometricUnlock)
        if model.vaultURL != nil {
            onDone()
            dismiss()
        }
    }

    private func ensuredVaultPath(from source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.lowercased().hasSuffix(".aegirovault") else { return trimmed }
        return trimmed + ".aegirovault"
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
    case modified

    var title: String {
        switch self {
        case .name: return "Name"
        case .size: return "Size"
        case .modified: return "Modified"
        }
    }

    func compare(_ lhs: VaultIndexEntry, _ rhs: VaultIndexEntry) -> Bool {
        switch self {
        case .name:
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        case .size:
            return lhs.size < rhs.size
        case .modified:
            return lhs.modified < rhs.modified
        }
    }
}

private enum AegiroPalette {
    static let iceBlue = Color(hex: "#8ECAE6")
    static let tealBlue = Color(hex: "#219EBC")
    static let deepNavy = Color(hex: "#023047")
    static let sunYellow = Color(hex: "#FFB703")
    static let orange = Color(hex: "#FB8500")
    static let primaryBlue = Color(hex: "#219EBC")
}

private extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let r, g, b: UInt64
        switch cleaned.count {
        case 6:
            (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (255, 255, 255)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: 1
        )
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

    var kindDescription: String {
        if let type = UTType(mimeType: mime) ?? UTType(filenameExtension: (logicalPath as NSString).pathExtension) {
            return type.localizedDescription ?? type.identifier
        }
        return mime.isEmpty ? "Unknown" : mime
    }

    var systemIcon: String {
        let ext = (logicalPath as NSString).pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "heic", "gif", "tiff", "webp"].contains(ext) { return "photo" }
        if ["mp4", "mov", "mkv", "avi", "m4v"].contains(ext) { return "film" }
        if ["mp3", "wav", "m4a", "aac", "flac"].contains(ext) { return "music.note" }
        if ["pdf"].contains(ext) { return "doc.richtext" }
        if ["zip", "tar", "gz", "7z"].contains(ext) { return "archivebox" }
        if ["txt", "md", "rtf", "log"].contains(ext) { return "doc.text" }
        return "doc"
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
