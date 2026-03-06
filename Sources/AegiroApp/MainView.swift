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
    @State private var showDiskEncryptSheet = false
    @State private var showDiskUnlockSheet = false

    @State private var selectionMode = false
    @State private var searchText = ""
    @State private var selection: Set<VaultIndexEntry.ID> = []
    @State private var viewMode: ContentViewMode = .list
    @State private var sortOption: SortOption = .modified
    @State private var sortAscending = false

    @State private var toastMessage: String?
    @State private var toastDismissWork: DispatchWorkItem?
    @State private var isDropTargeted = false
    @State private var isProcessingDrop = false

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
        VStack(spacing: 0) {
            topBar
            divider
            HStack(spacing: 0) {
                sidebar
                divider
                contentArea
            }
            divider
            statusBar
        }
        .frame(minWidth: 1080, minHeight: 720)
        .background(AegiroPalette.backgroundMain.ignoresSafeArea())
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
        .sheet(isPresented: $showDiskEncryptSheet) {
            DiskEncryptSheet {
                showDiskEncryptSheet = false
            }
            .environmentObject(model)
        }
        .sheet(isPresented: $showDiskUnlockSheet) {
            DiskUnlockSheet {
                showDiskUnlockSheet = false
            }
            .environmentObject(model)
        }
        .onAppear {
            model.refreshStatus()
            model.startAutoLockTimer()
        }
        .onReceive(model.$entries) { _ in
            selection = selection.intersection(Set(model.entries.map(\.id)))
            if model.entries.isEmpty {
                selectionMode = false
            }
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

    private var divider: some View {
        Rectangle()
            .fill(AegiroPalette.borderSubtle)
            .frame(maxWidth: .infinity)
            .frame(height: 1)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: model.locked ? "lock.fill" : "checkmark.shield.fill")
                    .foregroundStyle(model.locked ? AegiroPalette.warningAmber : AegiroPalette.securityGreen)
                Text(model.vaultURL?.lastPathComponent ?? "No Vault Selected")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AegiroPalette.textPrimary)
                    .lineLimit(1)
            }
            .frame(minWidth: 250, maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AegiroPalette.textSecondary)
                TextField("Search files", text: $searchText)
                    .textFieldStyle(.plain)
                    .foregroundStyle(AegiroPalette.textPrimary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(AegiroPalette.backgroundCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AegiroPalette.borderSubtle, lineWidth: 1)
            )
            .frame(maxWidth: 430)

            HStack(spacing: 8) {
                Picker("View", selection: $viewMode) {
                    Image(systemName: "list.bullet").tag(ContentViewMode.list)
                    Image(systemName: "square.grid.2x2").tag(ContentViewMode.grid)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 104)

                Menu {
                    Picker("Sort", selection: $sortOption) {
                        ForEach(SortOption.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    Toggle("Ascending", isOn: $sortAscending)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }

                Button {
                    toggleSelectionMode()
                } label: {
                    Image(systemName: selectionMode ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .buttonStyle(.borderless)
                .help(selectionMode ? "Exit selection mode" : "Enter selection mode")
                .disabled(model.locked || model.entries.isEmpty)

                Button {
                    showPreferences = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
            }
            .foregroundStyle(AegiroPalette.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AegiroPalette.backgroundPanel)
    }

    private var sidebar: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {
                sidebarHeaderCard
                vaultInfoCard
                actionsCard
                securityCard
                externalDiskCard
                if !selection.isEmpty {
                    selectedSummaryCard
                }
            }
            .padding(12)
        }
        .frame(width: 260)
        .background(AegiroPalette.backgroundPanel)
    }

    private var sidebarHeaderCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Aegiro Vault")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AegiroPalette.textPrimary)

                statusPill(
                    text: model.locked ? "Locked" : "Unlocked",
                    icon: model.locked ? "lock.fill" : "checkmark.circle.fill",
                    color: model.locked ? AegiroPalette.warningAmber : AegiroPalette.securityGreen
                )

                if !model.manifestOK {
                    statusPill(
                        text: "Integrity Warning",
                        icon: "exclamationmark.triangle.fill",
                        color: AegiroPalette.warningAmber
                    )
                }
            }
        }
    }

    private var vaultInfoCard: some View {
        card {
            VStack(alignment: .leading, spacing: 9) {
                sectionTitle("Vault Info")
                infoRow(label: "Files", value: model.vaultFileCount.map(String.init) ?? "Unknown")
                infoRow(label: "Size", value: formatVaultSize(model.vaultSizeBytes))
                infoRow(label: "Last Edited", value: formatLastEdited(model.vaultLastEdited))
            }
        }
    }

    private var actionsCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Actions")

                actionButton(
                    title: model.locked ? "Unlock Vault" : "Add Files",
                    icon: model.locked ? "lock.open.fill" : "plus.circle.fill"
                ) {
                    if model.locked {
                        showUnlockSheet = true
                    } else {
                        model.importFiles()
                    }
                }
                .disabled(model.vaultURL == nil)

                actionButton(title: "Export Selected", icon: "square.and.arrow.up") {
                    exportSelection()
                }
                .disabled(model.locked || selection.isEmpty)

                actionButton(title: "Lock Vault", icon: "lock.fill") {
                    model.lockNow()
                }
                .disabled(model.vaultURL == nil || model.locked)

                HStack(spacing: 8) {
                    Button("Open") {
                        model.openVaultWithPanel()
                    }
                    .buttonStyle(.borderless)

                    Text("/")
                        .foregroundStyle(AegiroPalette.textMuted)

                    Button("Create") {
                        showCreateVaultSheet = true
                    }
                    .buttonStyle(.borderless)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AegiroPalette.textSecondary)
            }
        }
    }

    private var securityCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Security")

                actionButton(title: "Add Touch ID", icon: "touchid") {
                    model.addTouchIDForUnlockedVault()
                }
                .disabled(model.vaultURL == nil || model.locked || model.allowTouchID)

                actionButton(title: "Verify Vault", icon: "checkmark.shield") {
                    verifyVaultState()
                }
                .disabled(model.vaultURL == nil)

                actionButton(title: "Run Doctor", icon: "stethoscope") {
                    let path = model.vaultURL?.path ?? "<vault-path>"
                    model.status = "Use CLI doctor: aegiro-cli doctor --vault \(path)"
                }
                .disabled(model.vaultURL == nil)
            }
        }
    }

    private var externalDiskCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("External Disk")

                actionButton(title: "Encrypt Disk", icon: "externaldrive.badge.plus") {
                    showDiskEncryptSheet = true
                }

                actionButton(title: "Unlock Disk", icon: "lock.open") {
                    showDiskUnlockSheet = true
                }
            }
        }
    }

    private var selectedSummaryCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Selection")
                infoRow(label: "Selected", value: "\(selection.count)")
                infoRow(label: "Total", value: ByteCountFormatter.fileFormatter.string(fromByteCount: selectedSize))
                if let focusedEntry {
                    Text(focusedEntry.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AegiroPalette.textSecondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var contentArea: some View {
        ZStack(alignment: .bottom) {
            Group {
                if model.vaultURL == nil {
                    noVaultState
                } else if model.locked {
                    lockedState
                } else if filteredEntries.isEmpty {
                    emptyVaultState
                } else {
                    fileBrowser
                }
            }

            if isDropTargeted && !model.locked {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AegiroPalette.accentIndigo.opacity(0.16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AegiroPalette.accentIndigo, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    )
                    .padding(24)
                    .overlay {
                        Text("Drop files to encrypt")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(AegiroPalette.textPrimary)
                    }
                    .allowsHitTesting(false)
            }

            if isProcessingDrop {
                VStack(spacing: 10) {
                    Text("Encrypting files...")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AegiroPalette.textPrimary)
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(AegiroPalette.securityGreen)
                }
                .padding(14)
                .frame(width: 260)
                .background(AegiroPalette.backgroundCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AegiroPalette.borderSubtle, lineWidth: 1)
                )
                .padding(.bottom, 54)
            }

            if let toastMessage {
                Text(toastMessage)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AegiroPalette.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(AegiroPalette.backgroundCard, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(AegiroPalette.borderSubtle, lineWidth: 1)
                    )
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(AegiroPalette.backgroundMain)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
    }

    private var noVaultState: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(AegiroPalette.accentIndigo)
            Text("Encrypted Local Vault")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(AegiroPalette.textPrimary)
            Text("Open an existing vault or create a new one to begin.")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(AegiroPalette.textSecondary)
            HStack(spacing: 10) {
                Button("Open Existing") {
                    model.openVaultWithPanel()
                }
                .buttonStyle(.bordered)

                Button("Create Vault") {
                    showCreateVaultSheet = true
                }
                .buttonStyle(.borderedProminent)
                .tint(AegiroPalette.accentIndigo)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var lockedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(AegiroPalette.warningAmber)
            Text("Vault Locked")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(AegiroPalette.textPrimary)
            Text("Unlock to view encrypted files.")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(AegiroPalette.textSecondary)
            Button("Unlock Vault") {
                showUnlockSheet = true
            }
            .buttonStyle(.borderedProminent)
            .tint(AegiroPalette.accentIndigo)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyVaultState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(AegiroPalette.securityGreen)
            Text("No files in vault")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(AegiroPalette.textPrimary)
            Text("Drag files here or add files to encrypt.")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(AegiroPalette.textSecondary)
            Button("Add Files") {
                model.importFiles()
            }
            .buttonStyle(.borderedProminent)
            .tint(AegiroPalette.accentIndigo)
            .disabled(model.locked)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var fileBrowser: some View {
        if viewMode == .list {
            listView
        } else {
            gridView
        }
    }

    private var listView: some View {
        Table(filteredEntries, selection: $selection) {
            TableColumn("") { entry in
                Button {
                    toggleSelection(entry)
                } label: {
                    Image(systemName: selection.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selection.contains(entry.id) ? AegiroPalette.securityGreen : AegiroPalette.textMuted)
                        .opacity(selectionMode ? 1 : 0)
                }
                .buttonStyle(.plain)
                .disabled(!selectionMode)
            }
            .width(28)

            TableColumn("Name") { entry in
                HStack(spacing: 10) {
                    Image(systemName: entry.systemIcon)
                        .foregroundStyle(AegiroPalette.accentIndigo)
                    Text(entry.displayName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AegiroPalette.textPrimary)
                        .lineLimit(1)
                }
                .contextMenu { rowMenu(entry: entry) }
            }
            .width(min: 260, ideal: 360)

            TableColumn("Size") { entry in
                Text(entry.formattedSize)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(AegiroPalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            TableColumn("Type") { entry in
                Text(entry.kindDescription)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(AegiroPalette.textSecondary)
                    .lineLimit(1)
            }

            TableColumn("Modified") { entry in
                Text(entry.modified.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(AegiroPalette.textSecondary)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .scrollContentBackground(.hidden)
        .background(AegiroPalette.backgroundMain)
        .padding(12)
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                ForEach(filteredEntries) { entry in
                    Button {
                        if selectionMode {
                            toggleSelection(entry)
                        } else {
                            selection = [entry.id]
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: entry.systemIcon)
                                    .foregroundStyle(AegiroPalette.accentIndigo)
                                Spacer()
                                if selectionMode {
                                    Image(systemName: selection.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selection.contains(entry.id) ? AegiroPalette.securityGreen : AegiroPalette.textMuted)
                                }
                            }

                            Text(entry.displayName)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(AegiroPalette.textPrimary)
                                .lineLimit(1)

                            Text(entry.formattedSize)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(AegiroPalette.textSecondary)

                            Text("Modified \(entry.modified.formatted(date: .abbreviated, time: .omitted))")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(AegiroPalette.textMuted)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(selection.contains(entry.id) ? AegiroPalette.selection : AegiroPalette.backgroundCard)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(AegiroPalette.borderSubtle, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu { rowMenu(entry: entry) }
                }
            }
            .padding(12)
        }
    }

    private func rowMenu(entry: VaultIndexEntry) -> some View {
        Group {
            Button("Preview") {
                model.quickLook(logicalPath: entry.logicalPath)
            }
            .disabled(model.locked)

            Button("Export") {
                model.exportSelectedWithPanel(filter: entry.logicalPath)
            }
            .disabled(model.locked)

            Button("Copy Path") {
                model.copyPathToClipboard(entry.logicalPath)
            }

            Button("Reveal Export") {
                model.revealExport(logicalPath: entry.logicalPath)
            }
            .disabled(model.locked)

            Divider()

            Button("Delete") {
                model.status = "Delete is not available yet in the macOS app."
            }
            .disabled(true)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            statusPill(
                text: model.locked ? "Vault Locked" : "Vault Unlocked",
                icon: model.locked ? "lock.fill" : "circle.fill",
                color: model.locked ? AegiroPalette.warningAmber : AegiroPalette.securityGreen
            )

            Text("Files: \(filteredEntries.count)")
            Text("Selected: \(selection.count)")

            if !model.locked && model.autoLockRemaining > 0 {
                Text("Auto-lock in: \(formattedRemaining(model.autoLockRemaining))")
            }

            Spacer()

            Text(model.vaultURL?.path ?? "No active vault")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(AegiroPalette.textSecondary)
        }
        .font(.system(size: 11, weight: .regular, design: .monospaced))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .foregroundStyle(AegiroPalette.textSecondary)
        .background(AegiroPalette.backgroundPanel)
    }

    private var unlockSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Unlock Vault")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(AegiroPalette.textPrimary)

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
                .tint(AegiroPalette.accentIndigo)
                .disabled(unlockPass.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(AegiroPalette.backgroundPanel)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AegiroPalette.backgroundCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AegiroPalette.borderSubtle, lineWidth: 1)
            )
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(AegiroPalette.textPrimary)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(AegiroPalette.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AegiroPalette.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func actionButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AegiroPalette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(AegiroPalette.backgroundPanel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(AegiroPalette.borderSubtle, lineWidth: 1)
        )
    }

    private func statusPill(text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(
            Capsule()
                .stroke(color.opacity(0.36), lineWidth: 1)
        )
    }

    private func verifyVaultState() {
        model.refreshStatus()
        if model.locked {
            model.status = "Vault status refreshed. Unlock to fully verify entries."
            return
        }
        model.status = model.manifestOK ? "Vault integrity verified." : "Integrity warning: manifest verification failed."
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
        if !selectionMode {
            selection.removeAll()
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !model.locked else {
            model.status = "Unlock to import dropped files"
            return false
        }

        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        isProcessingDrop = true

        for provider in fileProviders {
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                defer { group.leave() }
                guard let data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      url.isFileURL else {
                    return
                }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            isProcessingDrop = false
            let uniquePaths = Array(Set(urls.map(\.path)))
            let droppedURLs = uniquePaths.map { URL(fileURLWithPath: $0) }
            guard !droppedURLs.isEmpty else {
                model.status = "Dropped files were not readable."
                return
            }
            model.importFiles(urls: droppedURLs)
        }

        return true
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: work)
    }
}

private struct CreateVaultSheet: View {
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) private var dismiss

    @State private var vaultName = "MyVault"
    @State private var parentPath: String = defaultVaultURL().deletingLastPathComponent().path
    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    @State private var allowTouchID = true

    var onDone: () -> Void

    private var effectivePath: String {
        let trimmedParent = parentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = vaultName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = trimmedName.isEmpty ? "MyVault" : trimmedName
        return URL(fileURLWithPath: trimmedParent, isDirectory: true)
            .appendingPathComponent("\(safeName).agvt")
            .path
    }

    private var canCreate: Bool {
        passphrase.count >= 8 && passphrase == confirmPassphrase
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Vault")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(AegiroPalette.textPrimary)

            formLabel("Vault Name")
            TextField("MyVault", text: $vaultName)
                .textFieldStyle(.roundedBorder)

            formLabel("Location")
            HStack(spacing: 8) {
                TextField("/Users/...", text: $parentPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose...") {
                    chooseParentFolder()
                }
                .buttonStyle(.bordered)
            }

            formLabel("Passphrase")
            SecureField("At least 8 characters", text: $passphrase)
                .textFieldStyle(.roundedBorder)

            formLabel("Confirm Passphrase")
            SecureField("Repeat passphrase", text: $confirmPassphrase)
                .textFieldStyle(.roundedBorder)

            Toggle("Enable Touch ID", isOn: $allowTouchID)
                .disabled(!model.supportsBiometricUnlock)

            if passphrase != confirmPassphrase && !confirmPassphrase.isEmpty {
                Text("Passphrases do not match.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(AegiroPalette.dangerRed)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Create Vault") {
                    createVault()
                }
                .buttonStyle(.borderedProminent)
                .tint(AegiroPalette.accentIndigo)
                .disabled(!canCreate)
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(AegiroPalette.backgroundPanel)
    }

    private func formLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AegiroPalette.textSecondary)
    }

    private func chooseParentFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            parentPath = url.path
        }
    }

    private func createVault() {
        model.createVault(
            at: URL(fileURLWithPath: effectivePath),
            passphrase: passphrase,
            touchID: allowTouchID && model.supportsBiometricUnlock
        )
        if model.vaultURL != nil {
            onDone()
            dismiss()
        }
    }
}

private struct DiskEncryptSheet: View {
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) private var dismiss

    @State private var diskIdentifier = ""
    @State private var recoveryPassphrase = ""
    @State private var recoveryPath = ""
    @State private var dryRun = false
    @State private var overwrite = false

    var onDone: () -> Void

    private var canSubmit: Bool {
        !diskIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !recoveryPassphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !recoveryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Encrypt External Disk")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(AegiroPalette.textPrimary)

            Text("Encrypt APFS external volumes and generate a PQC recovery bundle.")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(AegiroPalette.textSecondary)

            formLabel("APFS Volume Identifier")
            TextField("disk9s1", text: $diskIdentifier)
                .textFieldStyle(.roundedBorder)

            formLabel("Recovery Passphrase")
            SecureField("Required to decrypt recovery bundle", text: $recoveryPassphrase)
                .textFieldStyle(.roundedBorder)

            formLabel("Recovery Bundle File")
            HStack(spacing: 8) {
                TextField("/path/to/disk.aegiro-diskkey.json", text: $recoveryPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose...") { chooseRecoveryPath() }
                    .buttonStyle(.bordered)
            }

            Toggle("Dry run only", isOn: $dryRun)
            Toggle("Overwrite existing recovery bundle", isOn: $overwrite)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(dryRun ? "Generate Bundle" : "Encrypt Disk") {
                    startEncrypt()
                }
                .buttonStyle(.borderedProminent)
                .tint(AegiroPalette.accentIndigo)
                .disabled(!canSubmit)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(AegiroPalette.backgroundPanel)
        .onAppear {
            if recoveryPath.isEmpty {
                recoveryPath = defaultRecoveryPath(for: diskIdentifier)
            }
        }
        .onChange(of: diskIdentifier) { newValue in
            if recoveryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recoveryPath = defaultRecoveryPath(for: newValue)
            }
        }
    }

    private func formLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AegiroPalette.textSecondary)
    }

    private func chooseRecoveryPath() {
        let panel = NSSavePanel()
        panel.title = "Save PQC Recovery Bundle"
        panel.nameFieldStringValue = (defaultRecoveryPath(for: diskIdentifier) as NSString).lastPathComponent
        panel.allowedContentTypes = [UTType.json]
        if panel.runModal() == .OK, let url = panel.url {
            recoveryPath = url.path
        }
    }

    private func defaultRecoveryPath(for diskID: String) -> String {
        let trimmed = diskID.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = trimmed.isEmpty ? "external-disk" : trimmed.replacingOccurrences(of: "/", with: "_")
        let baseDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AegiroVaults", isDirectory: true)
        return baseDir.appendingPathComponent("\(safe).aegiro-diskkey.json").path
    }

    private func startEncrypt() {
        let disk = diskIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = recoveryPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = recoveryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !disk.isEmpty, !pass.isEmpty, !path.isEmpty else { return }
        model.encryptExternalDisk(
            diskIdentifier: disk,
            recoveryPassphrase: pass,
            recoveryURL: URL(fileURLWithPath: NSString(string: path).expandingTildeInPath),
            dryRun: dryRun,
            overwrite: overwrite
        )
        onDone()
        dismiss()
    }
}

private struct DiskUnlockSheet: View {
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) private var dismiss

    @State private var diskIdentifier = ""
    @State private var recoveryPassphrase = ""
    @State private var recoveryPath = ""
    @State private var dryRun = false

    var onDone: () -> Void

    private var canSubmit: Bool {
        !diskIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !recoveryPassphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !recoveryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Unlock External Disk")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(AegiroPalette.textPrimary)

            Text("Use a PQC recovery bundle + passphrase to unlock APFS external volumes.")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(AegiroPalette.textSecondary)

            formLabel("APFS Volume Identifier")
            TextField("disk9s1", text: $diskIdentifier)
                .textFieldStyle(.roundedBorder)

            formLabel("Recovery Bundle File")
            HStack(spacing: 8) {
                TextField("/path/to/disk.aegiro-diskkey.json", text: $recoveryPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose...") { chooseRecoveryPath() }
                    .buttonStyle(.bordered)
            }

            formLabel("Recovery Passphrase")
            SecureField("Must match bundle passphrase", text: $recoveryPassphrase)
                .textFieldStyle(.roundedBorder)

            Toggle("Dry run only", isOn: $dryRun)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(dryRun ? "Validate Bundle" : "Unlock Disk") {
                    startUnlock()
                }
                .buttonStyle(.borderedProminent)
                .tint(AegiroPalette.accentIndigo)
                .disabled(!canSubmit)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(AegiroPalette.backgroundPanel)
    }

    private func formLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AegiroPalette.textSecondary)
    }

    private func chooseRecoveryPath() {
        let panel = NSOpenPanel()
        panel.title = "Choose PQC Recovery Bundle"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType.json]
        if panel.runModal() == .OK, let url = panel.url {
            recoveryPath = url.path
        }
    }

    private func startUnlock() {
        let disk = diskIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = recoveryPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = recoveryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !disk.isEmpty, !pass.isEmpty, !path.isEmpty else { return }
        model.unlockExternalDisk(
            diskIdentifier: disk,
            recoveryPassphrase: pass,
            recoveryURL: URL(fileURLWithPath: NSString(string: path).expandingTildeInPath),
            dryRun: dryRun
        )
        onDone()
        dismiss()
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
