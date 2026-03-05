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
    @State private var selectionMode = false

    @State private var searchText = ""
    @State private var selection: Set<VaultIndexEntry.ID> = []
    @State private var viewMode: ContentViewMode = .list
    @State private var sortOption: SortOption = .modified
    @State private var sortAscending = false
    @State private var toastMessage: String?
    @State private var toastDismissWork: DispatchWorkItem?

    private var filteredEntries: [VaultIndexEntry] {
        let searched = applySearch(to: model.entries)
        return applySort(to: searched)
    }

    private var selectedEntries: [VaultIndexEntry] {
        model.entries.filter { selection.contains($0.id) }
    }

    private var selectedSize: Int64 {
        selectedEntries.reduce(0) { $0 + Int64($1.size) }
    }

    private var focusedEntry: VaultIndexEntry? {
        selectedEntries.count == 1 ? selectedEntries.first : nil
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
        .frame(minWidth: 980, minHeight: 700)
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
        .onReceive(model.$locked) { isLocked in
            if isLocked {
                selectionMode = false
                selection.removeAll()
                return
            }
            guard showUnlockSheet else { return }
            unlockPass = ""
            showUnlockSheet = false
        }
        .onReceive(model.$status) { updateToast(with: $0) }
        .onDisappear {
            toastDismissWork?.cancel()
        }
    }

    private var sidebar: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                brandCard
                vaultInfoCard
                workflowCard
                if !model.locked && !selection.isEmpty {
                    selectedFileCard
                }

                VStack(spacing: 10) {
                    actionButton(title: "Open Vault", icon: "folder") {
                        model.openVaultWithPanel()
                    }

                    actionButton(title: "Create Vault", icon: "plus.circle") {
                        showCreateVaultSheet = true
                    }

                    actionButton(title: model.locked ? "Unlock Vault" : "Add Files", icon: model.locked ? "lock.open" : "tray.and.arrow.down") {
                        if model.locked {
                            showUnlockSheet = true
                        } else {
                            model.importFiles()
                        }
                    }
                    .disabled(model.vaultURL == nil)

                    actionButton(title: "Lock Vault", icon: "lock") {
                        model.lockNow()
                        selection.removeAll()
                    }
                    .disabled(model.vaultURL == nil || model.locked)

                    if !model.locked && !model.allowTouchID {
                        actionButton(title: "Add Touch ID", icon: "touchid") {
                            model.addTouchIDForUnlockedVault()
                        }
                        .disabled(model.vaultURL == nil)
                    }

                    actionButton(title: "Export Selected", icon: "square.and.arrow.up") {
                        exportSelection()
                    }
                    .disabled(model.locked || selection.isEmpty)
                }

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
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
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
                    Text("Aegiro Vaults")
                        .font(.title3.weight(.bold))
                    Text("Quantum-safe vault security")
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
            workflowRow(number: 1, icon: "tray.and.arrow.down", text: "Import writes directly into encrypted vault", done: !model.locked && !model.entries.isEmpty)
            workflowRow(number: 2, icon: "lock", text: "Lock vault when finished", done: model.locked)

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

    private var vaultInfoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Vault Info")
                .font(.headline)

            infoRow(label: "Files", value: model.vaultFileCount.map(String.init) ?? "Unknown (locked)")
            infoRow(label: "Vault size", value: formatVaultSize(model.vaultSizeBytes))
            infoRow(label: "Last edited", value: formatLastEdited(model.vaultLastEdited))
        }
        .padding(14)
        .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AegiroPalette.iceBlue.opacity(0.8), lineWidth: 1)
        )
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Label("", systemImage: "magnifyingglass")
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
            TextField("Search files", text: $searchText)
                .textFieldStyle(.plain)
                .frame(minWidth: 120)
                .layoutPriority(1)

            Picker("View", selection: $viewMode) {
                Label("List", systemImage: "list.bullet").tag(ContentViewMode.list)
                Label("Grid", systemImage: "square.grid.2x2").tag(ContentViewMode.grid)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 120)

            Spacer(minLength: 0)

            Divider()
                .frame(height: 18)

            Picker("Sort", selection: $sortOption) {
                ForEach(SortOption.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 112)

            Button {
                sortAscending.toggle()
            } label: {
                Label(sortAscending ? "Ascending" : "Descending", systemImage: sortAscending ? "arrow.up" : "arrow.down")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .help(sortAscending ? "Sorting ascending" : "Sorting descending")

            Divider()
                .frame(height: 18)

            Button {
                toggleSelectionMode()
            } label: {
                Label(selectionMode ? "Done Selecting" : "Select Files", systemImage: selectionMode ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.bordered)
            .help(selectionMode ? "Stop selecting files" : "Enable file selection mode")
            .disabled(model.locked || model.entries.isEmpty)

            Button {
                quickLookSelection()
            } label: {
                Label("Quick Look", systemImage: "eye")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .help("Quick Look selection")
            .disabled(model.locked || selection.isEmpty)

            Button {
                exportSelection()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderedProminent)
            .tint(AegiroPalette.primaryBlue)
            .help("Export selection")
            .disabled(model.locked || selection.isEmpty)
        }
        .controlSize(.small)
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
            Text("Unlock to import files or browse contents.")
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
            Text("Import files to add encrypted content directly to this vault.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                model.importFiles()
            } label: {
                Label("Import Files", systemImage: "tray.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .tint(AegiroPalette.primaryBlue)
            .disabled(model.locked)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listView: some View {
        Table(filteredEntries) {
            TableColumn("Name") { entry in
                HStack(spacing: 10) {
                    if selectionMode {
                        Button {
                            toggleSelection(entry)
                        } label: {
                            Image(systemName: selection.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selection.contains(entry.id) ? AegiroPalette.tealBlue : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
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
            .width(min: 235, ideal: 315)

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
                        if selectionMode {
                            toggleSelection(entry)
                        } else {
                            selection = [entry.id]
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: entry.systemIcon)
                                    .font(.title3)
                                    .foregroundStyle(AegiroPalette.primaryBlue)
                                Spacer()
                                if selectionMode {
                                    Image(systemName: selection.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selection.contains(entry.id) ? AegiroPalette.tealBlue : .secondary)
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
            Button("Show File Info") { selection = [entry.id] }
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

    private var selectedFileCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let entry = focusedEntry {
                Text("Selected File")
                    .font(.headline)
                infoRow(label: "Name", value: entry.displayName)
                infoRow(label: "Kind", value: entry.kindDescription)
                infoRow(label: "Size", value: entry.formattedSize)
                infoRow(label: "Modified", value: entry.modified.formatted(date: .abbreviated, time: .shortened))
                Text(entry.logicalPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Button {
                        model.quickLook(logicalPath: entry.logicalPath)
                    } label: {
                        Label("Quick Look", systemImage: "eye")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        model.exportSelectedWithPanel(filter: entry.logicalPath)
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AegiroPalette.primaryBlue)
                }
                .controlSize(.small)
            } else {
                Text("Selected Files")
                    .font(.headline)
                infoRow(label: "Count", value: "\(selection.count)")
                infoRow(label: "Total size", value: ByteCountFormatter.fileFormatter.string(fromByteCount: selectedSize))
                HStack(spacing: 8) {
                    Button {
                        quickLookSelection()
                    } label: {
                        Label("Quick Look", systemImage: "eye")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        exportSelection()
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AegiroPalette.primaryBlue)
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AegiroPalette.iceBlue.opacity(0.8), lineWidth: 1)
        )
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

    private func infoRow(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.trailing)
        }
    }

    private var workflowHint: String {
        if model.locked {
            return "Unlock to import files directly into encrypted storage."
        }
        if model.entries.isEmpty {
            return "Use Import to add files directly to the vault."
        }
        return "Imports are immediate; lock when you are done."
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

    private func toggleSelectionMode() {
        guard !model.locked else {
            model.status = "Unlock to select files"
            return
        }
        guard !model.entries.isEmpty else {
            model.status = "No files available to select"
            return
        }
        selectionMode.toggle()
    }

    private func applySearch(to entries: [VaultIndexEntry]) -> [VaultIndexEntry] {
        applySearch(query: searchText, entries: entries)
    }

    private func applySearch(query: String, entries: [VaultIndexEntry]) -> [VaultIndexEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func formatVaultSize(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func formatLastEdited(_ date: Date?) -> String {
        guard let date else { return "Unknown" }
        return date.formatted(date: .abbreviated, time: .shortened)
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
                    TextField("/path/to/vault.agvt", text: $path)
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
        panel.title = "Create Vault (Aegiro Vaults)"
        panel.nameFieldStringValue = (path as NSString).lastPathComponent
        panel.allowedContentTypes = [
            UTType(filenameExtension: "agvt") ?? .data,
            UTType(filenameExtension: "aegirovault") ?? .data
        ]
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
        let lowered = trimmed.lowercased()
        guard !lowered.hasSuffix(".agvt") && !lowered.hasSuffix(".aegirovault") else { return trimmed }
        return trimmed + ".agvt"
    }
}

private enum ContentViewMode: Hashable {
    case list
    case grid
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
