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
    @State private var showUSBUserDataEncryptSheet = false
    @State private var preferredUSBUserDataMountPoint: String?
    @State private var showDoctorSheet = false
    @State private var showFileInfoPopover = false

    @State private var searchText = ""
    @State private var selection: Set<VaultIndexEntry.ID> = []
    @State private var selectionAnchor: VaultIndexEntry.ID?
    @State private var selectionCursor: VaultIndexEntry.ID?
    @State private var viewMode: ContentViewMode = .list
    @State private var sortOption: SortOption = .modified
    @State private var sortAscending = false

    @State private var toastMessage: String?
    @State private var toastDismissWork: DispatchWorkItem?
    @State private var isDropTargeted = false
    @State private var isProcessingDrop = false
    @State private var gridItemFrames: [VaultIndexEntry.ID: CGRect] = [:]
    @State private var gridDragStart: CGPoint?
    @State private var gridSelectionRect: CGRect?
    @State private var gridSelectionBase: Set<VaultIndexEntry.ID> = []
    @State private var listItemFrames: [VaultIndexEntry.ID: CGRect] = [:]
    @State private var listDragStart: CGPoint?
    @State private var listSelectionRect: CGRect?
    @State private var listSelectionBase: Set<VaultIndexEntry.ID> = []
    @State private var showDeleteConfirmation = false
    @State private var pendingDeleteIDs: [VaultIndexEntry.ID] = []

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
            horizontalDivider
            HStack(spacing: 0) {
                sidebar
                verticalDivider
                contentArea
            }
            horizontalDivider
            statusBar
            quickLookKeyboardShortcut
            selectionNavigationShortcuts
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
            } onOpenUSBDataEncrypt: { mountPoint in
                preferredUSBUserDataMountPoint = mountPoint
                showUSBUserDataEncryptSheet = true
            }
            .environmentObject(model)
        }
        .sheet(isPresented: $showUSBUserDataEncryptSheet) {
            USBUserDataEncryptSheet(preferredMountPoint: preferredUSBUserDataMountPoint) {
                showUSBUserDataEncryptSheet = false
            }
            .environmentObject(model)
        }
        .sheet(isPresented: $showDoctorSheet) {
            DoctorSheet()
                .environmentObject(model)
        }
        .alert(deleteConfirmationTitle, isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingDeleteIDs = []
            }
            Button("Delete", role: .destructive) {
                confirmDelete()
            }
        } message: {
            Text(deleteConfirmationMessage)
        }
        .onAppear {
            model.refreshStatus()
            model.startAutoLockTimer()
        }
        .onReceive(model.$entries) { _ in
            let validIDs = Set(model.entries.map(\.id))
            selection = selection.intersection(validIDs)
            if let selectionAnchor, !validIDs.contains(selectionAnchor) {
                self.selectionAnchor = nil
            }
            if let selectionCursor, !validIDs.contains(selectionCursor) {
                self.selectionCursor = nil
            }
        }
        .onReceive(model.$locked) { isLocked in
            if isLocked {
                selection.removeAll()
                selectionAnchor = nil
                selectionCursor = nil
                return
            }
            guard showUnlockSheet else { return }
            unlockPass = ""
            showUnlockSheet = false
        }
        .onReceive(model.$status) { updateToast(with: $0) }
        .onChange(of: showUSBUserDataEncryptSheet) { isPresented in
            if !isPresented {
                preferredUSBUserDataMountPoint = nil
            }
        }
        .onChange(of: selection) { newSelection in
            if newSelection.isEmpty {
                selectionAnchor = nil
                selectionCursor = nil
                showFileInfoPopover = false
                return
            }
            let visibleIDs = filteredEntries.map(\.id)
            if selectionAnchor == nil || !(selectionAnchor.map(newSelection.contains) ?? false) {
                selectionAnchor = visibleIDs.first(where: { newSelection.contains($0) })
            }
            if selectionCursor == nil || !(selectionCursor.map(newSelection.contains) ?? false) {
                selectionCursor = visibleIDs.last(where: { newSelection.contains($0) })
            }
            if focusedEntry == nil {
                showFileInfoPopover = false
            }
        }
        .onDisappear {
            toastDismissWork?.cancel()
        }
    }

    private var horizontalDivider: some View {
        Rectangle()
            .fill(AegiroPalette.borderSubtle)
            .frame(maxWidth: .infinity)
            .frame(height: 1)
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(AegiroPalette.borderSubtle)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
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
                    showFileInfoPopover = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .disabled(focusedEntry == nil)
                .popover(isPresented: $showFileInfoPopover, arrowEdge: .bottom) {
                    fileInfoPopover
                }

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
                .disabled(model.vaultURL == nil || model.locked || model.allowTouchID || !model.biometricKeychainAvailable)

                if let issue = model.biometricKeychainIssue {
                    Text(issue)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(AegiroPalette.warningAmber)
                }

                actionButton(title: "Check Integrity", icon: "checkmark.shield") {
                    showDoctorSheet = true
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

                actionButton(title: "Decrypt Disk", icon: "lock.open") {
                    showDiskUnlockSheet = true
                }
            }
        }
    }

    private var fileInfoPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("File Info")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AegiroPalette.textPrimary)

            if let focusedEntry {
                infoRow(label: "Name", value: focusedEntry.displayName)
                infoRow(label: "Size", value: focusedEntry.formattedSize)
                infoRow(label: "Type", value: focusedEntry.kindDescription)
                infoRow(label: "Modified", value: focusedEntry.modified.formatted(date: .abbreviated, time: .shortened))
                infoRow(label: "Path", value: focusedEntry.logicalPath)
            } else if selection.count > 1 {
                infoRow(label: "Selected", value: "\(selection.count) files")
                infoRow(label: "Total Size", value: ByteCountFormatter.fileFormatter.string(fromByteCount: selectedSize))
                Text("Select one file to view full metadata.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(AegiroPalette.textSecondary)
            } else {
                Text("Select a file to view details.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(AegiroPalette.textSecondary)
            }
        }
        .padding(14)
        .frame(width: 360)
        .background(AegiroPalette.backgroundPanel)
    }

    private var quickLookKeyboardShortcut: some View {
        Button(action: quickLookCurrentSelection) {
            EmptyView()
        }
        .keyboardShortcut(KeyEquivalent(" "), modifiers: [])
        .disabled(model.locked || selection.isEmpty)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private var selectionNavigationShortcuts: some View {
        Group {
            Button(action: { navigateSelection(direction: .up, extending: false) }) { EmptyView() }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(model.locked || filteredEntries.isEmpty)
            Button(action: { navigateSelection(direction: .down, extending: false) }) { EmptyView() }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(model.locked || filteredEntries.isEmpty)
            Button(action: { navigateSelection(direction: .up, extending: true) }) { EmptyView() }
                .keyboardShortcut(.upArrow, modifiers: [.shift])
                .disabled(model.locked || filteredEntries.isEmpty)
            Button(action: { navigateSelection(direction: .down, extending: true) }) { EmptyView() }
                .keyboardShortcut(.downArrow, modifiers: [.shift])
                .disabled(model.locked || filteredEntries.isEmpty)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
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
        ZStack(alignment: .topLeading) {
            ScrollView {
                VStack(spacing: 0) {
                    listHeader
                    LazyVStack(spacing: 0) {
                        ForEach(filteredEntries) { entry in
                            listRow(entry)
                                .background(
                                    GeometryReader { proxy in
                                        Color.clear.preference(
                                            key: ListItemFramePreferenceKey.self,
                                            value: [entry.id: proxy.frame(in: .named("list-selection-space"))]
                                        )
                                    }
                                )
                        }
                    }
                }
                .padding(12)
            }

            if let listSelectionRect {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(AegiroPalette.accentIndigo.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(AegiroPalette.accentIndigo.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [5]))
                    )
                    .frame(width: listSelectionRect.width, height: listSelectionRect.height)
                    .offset(x: listSelectionRect.minX, y: listSelectionRect.minY)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "list-selection-space")
        .onPreferenceChange(ListItemFramePreferenceKey.self) { value in
            listItemFrames = value
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named("list-selection-space"))
                .onChanged(handleListDragChanged)
                .onEnded { _ in
                    listDragStart = nil
                    listSelectionRect = nil
                    listSelectionBase = []
                }
        )
    }

    private var gridView: some View {
        ZStack(alignment: .topLeading) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                    ForEach(filteredEntries) { entry in
                        Button {
                            handleGridClick(on: entry)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: entry.systemIcon)
                                        .foregroundStyle(AegiroPalette.accentIndigo)
                                    Spacer()
                                    if selection.contains(entry.id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(AegiroPalette.securityGreen)
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
                                    .stroke(selection.contains(entry.id) ? AegiroPalette.accentIndigo : AegiroPalette.borderSubtle, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu { rowMenu(entry: entry) }
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: GridItemFramePreferenceKey.self,
                                    value: [entry.id: proxy.frame(in: .named("grid-selection-space"))]
                                )
                            }
                        )
                    }
                }
                .padding(12)
            }

            if let gridSelectionRect {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AegiroPalette.accentIndigo.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(AegiroPalette.accentIndigo.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [5]))
                    )
                    .frame(width: gridSelectionRect.width, height: gridSelectionRect.height)
                    .offset(x: gridSelectionRect.minX, y: gridSelectionRect.minY)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "grid-selection-space")
        .onPreferenceChange(GridItemFramePreferenceKey.self) { value in
            gridItemFrames = value
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named("grid-selection-space"))
                .onChanged(handleGridDragChanged)
                .onEnded { _ in
                    gridDragStart = nil
                    gridSelectionRect = nil
                    gridSelectionBase = []
                }
        )
    }

    private var listHeader: some View {
        HStack(spacing: 10) {
            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Size")
                .frame(width: 90, alignment: .trailing)
            Text("Type")
                .frame(width: 140, alignment: .leading)
            Text("Modified")
                .frame(width: 120, alignment: .leading)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(AegiroPalette.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AegiroPalette.backgroundCard)
        .overlay(
            Rectangle()
                .fill(AegiroPalette.borderSubtle)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private func listRow(_ entry: VaultIndexEntry) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: entry.systemIcon)
                    .foregroundStyle(AegiroPalette.accentIndigo)
                Text(entry.displayName)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.formattedSize)
                .frame(width: 90, alignment: .trailing)
                .foregroundStyle(AegiroPalette.textSecondary)

            Text(entry.kindDescription)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)
                .foregroundStyle(AegiroPalette.textSecondary)

            Text(entry.modified.formatted(date: .abbreviated, time: .omitted))
                .frame(width: 120, alignment: .leading)
                .foregroundStyle(AegiroPalette.textSecondary)
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selection.contains(entry.id) ? AegiroPalette.selection : AegiroPalette.backgroundMain
        )
        .overlay(
            Rectangle()
                .fill(AegiroPalette.borderSubtle.opacity(0.35))
                .frame(height: 1),
            alignment: .bottom
        )
        .contentShape(Rectangle())
        .contextMenu { rowMenu(entry: entry) }
        .onTapGesture {
            handleListClick(on: entry)
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

            Button("Delete", role: .destructive) {
                requestDelete(fromContextEntry: entry)
            }
            .disabled(model.locked)
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

            if model.allowTouchID && model.supportsBiometricUnlock && model.biometricKeychainAvailable {
                Button {
                    model.unlockWithBiometrics()
                } label: {
                    Label("Use Touch ID", systemImage: "touchid")
                }
                .buttonStyle(.bordered)
            }

            if let issue = model.biometricKeychainIssue {
                Text(issue)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(AegiroPalette.warningAmber)
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

    private var deleteConfirmationTitle: String {
        pendingDeleteIDs.count == 1 ? "Delete File?" : "Delete \(pendingDeleteIDs.count) Files?"
    }

    private var deleteConfirmationMessage: String {
        if pendingDeleteIDs.count == 1, let only = pendingDeleteIDs.first {
            let name = (only as NSString).lastPathComponent
            return "\"\(name)\" will be permanently removed from this vault."
        }
        return "These files will be permanently removed from this vault."
    }

    private func requestDelete(fromContextEntry entry: VaultIndexEntry) {
        guard !model.locked else {
            model.status = "Unlock to delete files"
            return
        }
        let targets: [VaultIndexEntry.ID]
        if selection.contains(entry.id) && selection.count > 1 {
            targets = Array(selection)
        } else {
            targets = [entry.id]
        }
        pendingDeleteIDs = targets
        showDeleteConfirmation = !targets.isEmpty
    }

    private func confirmDelete() {
        let targets = pendingDeleteIDs
        pendingDeleteIDs = []
        guard !targets.isEmpty else { return }
        model.deleteEntries(logicalPaths: targets)
        selection.subtract(targets)
    }

    private func handleGridClick(on entry: VaultIndexEntry) {
        let modifiers = NSEvent.modifierFlags.intersection([.command, .shift])
        updateSelectionForClick(on: entry.id, modifiers: modifiers)
    }

    private func handleListClick(on entry: VaultIndexEntry) {
        let modifiers = NSEvent.modifierFlags.intersection([.command, .shift])
        updateSelectionForClick(on: entry.id, modifiers: modifiers)
    }

    private func updateSelectionForClick(on entryID: VaultIndexEntry.ID, modifiers: NSEvent.ModifierFlags) {
        let visibleIDs = filteredEntries.map(\.id)
        let hasCommand = modifiers.contains(.command)
        let hasShift = modifiers.contains(.shift)

        if hasShift {
            let anchor = selectionAnchor ?? selectionCursor ?? visibleIDs.first(where: { selection.contains($0) }) ?? entryID
            let range = selectionRange(from: anchor, to: entryID, orderedIDs: visibleIDs)
            if hasCommand {
                selection.formUnion(range)
            } else {
                selection = range
            }
            selectionAnchor = anchor
            selectionCursor = entryID
            return
        }

        if hasCommand {
            if selection.contains(entryID) {
                selection.remove(entryID)
            } else {
                selection.insert(entryID)
            }
            if selection.isEmpty {
                selectionAnchor = nil
                selectionCursor = nil
            } else {
                selectionAnchor = entryID
                selectionCursor = entryID
            }
            return
        }

        if selection.count == 1 && selection.contains(entryID) {
            selection.removeAll()
            selectionAnchor = nil
            selectionCursor = nil
        } else {
            selection = [entryID]
            selectionAnchor = entryID
            selectionCursor = entryID
        }
    }

    private func selectionRange(from startID: VaultIndexEntry.ID, to endID: VaultIndexEntry.ID, orderedIDs: [VaultIndexEntry.ID]) -> Set<VaultIndexEntry.ID> {
        guard let startIndex = orderedIDs.firstIndex(of: startID),
              let endIndex = orderedIDs.firstIndex(of: endID) else {
            return [endID]
        }
        let lower = min(startIndex, endIndex)
        let upper = max(startIndex, endIndex)
        return Set(orderedIDs[lower...upper])
    }

    private func handleGridDragChanged(_ value: DragGesture.Value) {
        if gridDragStart == nil {
            gridDragStart = value.startLocation
            gridSelectionBase = selection
        }
        guard let gridDragStart else { return }

        let rect = normalizedRect(from: gridDragStart, to: value.location)
        gridSelectionRect = rect

        let intersectingIDs = Set(gridItemFrames.compactMap { id, frame in
            frame.intersects(rect) ? id : nil
        })

        let modifiers = NSEvent.modifierFlags.intersection([.command, .shift])
        if modifiers.contains(.command) || modifiers.contains(.shift) {
            selection = gridSelectionBase.union(intersectingIDs)
        } else {
            selection = intersectingIDs
            selectionAnchor = filteredEntries.map(\.id).first(where: { intersectingIDs.contains($0) })
        }

        if let lastVisibleSelected = filteredEntries.map(\.id).last(where: { selection.contains($0) }) {
            selectionCursor = lastVisibleSelected
            if selectionAnchor == nil {
                selectionAnchor = lastVisibleSelected
            }
        } else if selection.isEmpty {
            selectionCursor = nil
            if !modifiers.contains(.command) && !modifiers.contains(.shift) {
                selectionAnchor = nil
            }
        }
    }

    private func handleListDragChanged(_ value: DragGesture.Value) {
        if listDragStart == nil {
            listDragStart = value.startLocation
            listSelectionBase = selection
        }
        guard let listDragStart else { return }

        let rect = normalizedRect(from: listDragStart, to: value.location)
        listSelectionRect = rect

        let intersectingIDs = Set(listItemFrames.compactMap { id, frame in
            frame.intersects(rect) ? id : nil
        })

        let modifiers = NSEvent.modifierFlags.intersection([.command, .shift])
        if modifiers.contains(.command) || modifiers.contains(.shift) {
            selection = listSelectionBase.union(intersectingIDs)
        } else {
            selection = intersectingIDs
            selectionAnchor = filteredEntries.map(\.id).first(where: { intersectingIDs.contains($0) })
        }

        if let lastVisibleSelected = filteredEntries.map(\.id).last(where: { selection.contains($0) }) {
            selectionCursor = lastVisibleSelected
            if selectionAnchor == nil {
                selectionAnchor = lastVisibleSelected
            }
        } else if selection.isEmpty {
            selectionCursor = nil
            if !modifiers.contains(.command) && !modifiers.contains(.shift) {
                selectionAnchor = nil
            }
        }
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func quickLookCurrentSelection() {
        guard !model.locked else {
            model.status = "Unlock to preview files"
            return
        }
        guard !selection.isEmpty else { return }
        model.quickLookSelection(filters: Array(selection))
    }

    private func navigateSelection(direction: SelectionDirection, extending: Bool) {
        guard !model.locked else { return }
        let orderedIDs = filteredEntries.map(\.id)
        guard !orderedIDs.isEmpty else { return }

        let fallbackStart = (direction == .up) ? orderedIDs.last : orderedIDs.first
        let currentID = selectionCursor
            ?? selectionAnchor
            ?? orderedIDs.last(where: { selection.contains($0) })
            ?? fallbackStart

        guard let currentID else { return }

        let targetID: VaultIndexEntry.ID
        if viewMode == .grid {
            targetID = nextGridNavigationID(from: currentID, direction: direction, orderedIDs: orderedIDs)
                ?? nextListNavigationID(from: currentID, direction: direction, orderedIDs: orderedIDs)
                ?? currentID
        } else {
            targetID = nextListNavigationID(from: currentID, direction: direction, orderedIDs: orderedIDs) ?? currentID
        }

        if extending {
            let anchor = selectionAnchor ?? currentID
            selectionAnchor = anchor
            selection = selectionRange(from: anchor, to: targetID, orderedIDs: orderedIDs)
        } else {
            selection = [targetID]
            selectionAnchor = targetID
        }
        selectionCursor = targetID
    }

    private func nextListNavigationID(from currentID: VaultIndexEntry.ID, direction: SelectionDirection, orderedIDs: [VaultIndexEntry.ID]) -> VaultIndexEntry.ID? {
        guard let currentIndex = orderedIDs.firstIndex(of: currentID) else {
            return direction == .up ? orderedIDs.last : orderedIDs.first
        }

        switch direction {
        case .up:
            return orderedIDs[max(0, currentIndex - 1)]
        case .down:
            return orderedIDs[min(orderedIDs.count - 1, currentIndex + 1)]
        }
    }

    private func nextGridNavigationID(from currentID: VaultIndexEntry.ID, direction: SelectionDirection, orderedIDs: [VaultIndexEntry.ID]) -> VaultIndexEntry.ID? {
        guard let currentFrame = gridItemFrames[currentID] else { return nil }
        let currentCenter = CGPoint(x: currentFrame.midX, y: currentFrame.midY)

        let candidates = orderedIDs.compactMap { id -> (id: VaultIndexEntry.ID, frame: CGRect)? in
            guard id != currentID, let frame = gridItemFrames[id] else { return nil }
            return (id, frame)
        }

        let directionalCandidates: [(id: VaultIndexEntry.ID, frame: CGRect)]
        switch direction {
        case .up:
            directionalCandidates = candidates.filter { $0.frame.midY < currentCenter.y - 1 }
        case .down:
            directionalCandidates = candidates.filter { $0.frame.midY > currentCenter.y + 1 }
        }
        guard !directionalCandidates.isEmpty else { return nil }

        let sorted = directionalCandidates.sorted { lhs, rhs in
            let lhsVertical = abs(lhs.frame.midY - currentCenter.y)
            let rhsVertical = abs(rhs.frame.midY - currentCenter.y)
            if lhsVertical != rhsVertical { return lhsVertical < rhsVertical }
            let lhsHorizontal = abs(lhs.frame.midX - currentCenter.x)
            let rhsHorizontal = abs(rhs.frame.midX - currentCenter.x)
            if lhsHorizontal != rhsHorizontal { return lhsHorizontal < rhsHorizontal }
            return lhs.id < rhs.id
        }
        return sorted.first?.id
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

private struct GridItemFramePreferenceKey: PreferenceKey {
    static var defaultValue: [VaultIndexEntry.ID: CGRect] = [:]

    static func reduce(value: inout [VaultIndexEntry.ID: CGRect], nextValue: () -> [VaultIndexEntry.ID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct ListItemFramePreferenceKey: PreferenceKey {
    static var defaultValue: [VaultIndexEntry.ID: CGRect] = [:]

    static func reduce(value: inout [VaultIndexEntry.ID: CGRect], nextValue: () -> [VaultIndexEntry.ID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private enum SelectionDirection {
    case up
    case down
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
        passphraseStrength.isRequired && passphrase == confirmPassphrase
    }

    private var passphraseStrength: PassphraseStrengthReport {
        PassphraseStrengthReport.evaluate(passphrase)
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
            SecureField("8+ chars with upper/lower letters and numbers", text: $passphrase)
                .textFieldStyle(.roundedBorder)
            PassphraseStrengthMeter(passphrase: passphrase)

            formLabel("Confirm Passphrase")
            SecureField("Repeat passphrase", text: $confirmPassphrase)
                .textFieldStyle(.roundedBorder)

            Toggle("Enable Touch ID", isOn: $allowTouchID)
                .disabled(!model.supportsBiometricUnlock || !model.biometricKeychainAvailable)

            if let issue = model.biometricKeychainIssue {
                Text(issue)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(AegiroPalette.warningAmber)
            }

            if passphrase != confirmPassphrase && !confirmPassphrase.isEmpty {
                Text("Passphrases do not match.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(AegiroPalette.dangerRed)
            }

            if !passphrase.isEmpty && !passphraseStrength.isRequired {
                Text("Passphrase must be 8+ chars and include uppercase, lowercase, and a number.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(AegiroPalette.warningAmber)
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
        guard passphraseStrength.isRequired else {
            model.status = "Passphrase is too weak. Use 8+ chars with uppercase, lowercase, and a number."
            return
        }
        model.createVault(
            at: URL(fileURLWithPath: effectivePath),
            passphrase: passphrase,
            touchID: allowTouchID && model.supportsBiometricUnlock && model.biometricKeychainAvailable
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
    @State private var lastSuggestedRecoveryPath = ""
    @State private var sourcePath = ""
    @State private var vaultPath = ""
    @State private var vaultPassphrase = ""
    @State private var confirmVaultPassphrase = ""
    @State private var lastSuggestedSourcePath = ""
    @State private var lastSuggestedVaultPath = ""
    @State private var dryRun = false
    @State private var overwrite = false
    @State private var deleteOriginals = false
    @State private var formPhase: FormPhase = .selectVolume

    var onDone: () -> Void

    private enum FormPhase {
        case selectVolume
        case details
    }

    private enum SelectionKind {
        case none
        case apfs
        case nonAPFS
        case invalid
    }

    private var selectedDiskTrimmed: String {
        diskIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var externalAPFSOptions: [APFSVolumeOption] {
        externalAPFSVolumes(from: model.apfsVolumeOptions)
    }

    private var selectedAPFSVolume: APFSVolumeOption? {
        externalAPFSOptions.first { $0.identifier == selectedDiskTrimmed }
    }

    private var selectedNonAPFSVolume: MountedNonAPFSVolume? {
        model.mountedNonAPFSVolumes.first { $0.mountPoint == selectedDiskTrimmed }
    }

    private var selectionKind: SelectionKind {
        if selectedDiskTrimmed.isEmpty {
            return .none
        }
        if selectedAPFSVolume != nil {
            return .apfs
        }
        if selectedNonAPFSVolume != nil {
            return .nonAPFS
        }
        return .invalid
    }

    private var usbPassphraseStrength: PassphraseStrengthReport {
        PassphraseStrengthReport.evaluate(vaultPassphrase)
    }

    private var canContinueFromSelection: Bool {
        switch selectionKind {
        case .apfs, .nonAPFS:
            return true
        case .none, .invalid:
            return false
        }
    }

    private var canSubmit: Bool {
        switch selectionKind {
        case .apfs:
            return !recoveryPassphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !recoveryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .nonAPFS:
            let pathsReady = !sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !vaultPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if dryRun {
                return pathsReady
            }
            return pathsReady && usbPassphraseStrength.isRequired && vaultPassphrase == confirmVaultPassphrase
        case .none, .invalid:
            return false
        }
    }

    private var isEncryptingSelectedDisk: Bool {
        model.diskEncryptionMonitoringActive && model.diskEncryptionMonitoringDiskIdentifier == selectedDiskTrimmed
    }

    private var shouldShowEncryptionProgress: Bool {
        guard selectionKind == .apfs else { return false }
        guard !selectedDiskTrimmed.isEmpty else { return false }
        guard model.diskEncryptionMonitoringDiskIdentifier == selectedDiskTrimmed else { return false }
        return model.diskEncryptionMonitoringActive || !model.diskEncryptionProgressMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedNonAPFSMountPoint: String {
        selectedNonAPFSVolume?.mountPoint ?? selectedDiskTrimmed
    }

    private var isEncryptingSelectedUSBUserData: Bool {
        guard selectionKind == .nonAPFS else { return false }
        let mount = selectedNonAPFSMountPoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = model.usbDataEncryptionTargetMountPoint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !mount.isEmpty, mount == target else { return false }
        return model.usbDataEncryptionActive
    }

    private var shouldShowUSBDataEncryptionProgress: Bool {
        guard selectionKind == .nonAPFS else { return false }
        let mount = selectedNonAPFSMountPoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = model.usbDataEncryptionTargetMountPoint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !mount.isEmpty, mount == target else { return false }
        return model.usbDataEncryptionActive
            || model.usbDataEncryptionTotalFiles > 0
            || !model.usbDataEncryptionProgressMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var submitButtonTitle: String {
        switch selectionKind {
        case .apfs:
            if dryRun {
                return "Generate Bundle"
            }
            return isEncryptingSelectedDisk ? "Encrypting..." : "Encrypt Disk"
        case .nonAPFS:
            if isEncryptingSelectedUSBUserData {
                return dryRun ? "Scanning..." : "Encrypting..."
            }
            return dryRun ? "Scan User Data" : "Encrypt User Data"
        case .none, .invalid:
            return "Encrypt Disk"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Encrypt External Disk")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(AegiroPalette.textPrimary)

            Text("Use one flow for APFS disk encryption and non-APFS USB user-data encryption.")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(AegiroPalette.textSecondary)

            if formPhase == .selectVolume {
                selectionPhaseContent
            } else {
                detailsPhaseContent
            }
        }
        .padding(24)
        .frame(width: 640)
        .background(AegiroPalette.backgroundPanel)
        .onAppear {
            formPhase = .selectVolume
            model.refreshAPFSVolumeOptions()
            model.clearUSBDataEncryptionProgressIfIdle()
            applyAutoDiskSelectionIfNeeded()
            syncFormFieldsForSelectionChange(force: true)
        }
        .onChange(of: model.apfsVolumeOptions) { _ in
            applyAutoDiskSelectionIfNeeded()
            syncFormFieldsForSelectionChange(force: false)
            if formPhase == .details, !canContinueFromSelection {
                formPhase = .selectVolume
            }
        }
        .onChange(of: model.mountedNonAPFSVolumes) { _ in
            syncFormFieldsForSelectionChange(force: false)
            if formPhase == .details, !canContinueFromSelection {
                formPhase = .selectVolume
            }
        }
        .onChange(of: diskIdentifier) { newValue in
            syncFormFieldsForSelectionChange(force: false)
            if selectedAPFSVolume != nil {
                syncRecoveryPathWithDisk(newValue)
            }
            if formPhase == .details, !canContinueFromSelection {
                formPhase = .selectVolume
            }
        }
    }

    private var selectionPhaseContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            APFSVolumeOptionsPanel(
                selectedDiskIdentifier: $diskIdentifier,
                options: model.apfsVolumeOptions,
                nonAPFSVolumes: model.mountedNonAPFSVolumes,
                isLoading: model.apfsVolumeOptionsLoading,
                errorMessage: model.apfsVolumeOptionsError,
                onSelectNonAPFSVolume: { volume in
                    diskIdentifier = volume.mountPoint
                    syncSuggestedUSBPaths(for: volume.mountPoint, force: true)
                }
            ) {
                model.refreshAPFSVolumeOptions()
            }

            formLabel("Selected APFS Volume Identifier")
            TextField("disk9s1 or /Volumes/MyUSB", text: $diskIdentifier)
                .textFieldStyle(.roundedBorder)
            Text("Choose from External Volumes above, or type a listed APFS identifier / non-APFS mount point.")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(AegiroPalette.textMuted)

            switch selectionKind {
            case .apfs:
                Text("APFS volume selected. Continue to configure recovery bundle + encryption options.")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(AegiroPalette.textSecondary)
            case .nonAPFS:
                Text("Non-APFS volume selected. Continue to configure source/vault/passphrase options.")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(AegiroPalette.textSecondary)
            case .none:
                Text("Select an external volume to continue.")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(AegiroPalette.textMuted)
            case .invalid:
                Text("The selected value is not a valid external APFS volume identifier or mounted non-APFS external volume.")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(AegiroPalette.warningAmber)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Continue") {
                    continueToDetails()
                }
                .buttonStyle(.borderedProminent)
                .tint(AegiroPalette.accentIndigo)
                .disabled(!canContinueFromSelection)
            }
        }
    }

    private var detailsPhaseContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                formLabel("Selected External Volume")
                switch selectionKind {
                case .apfs:
                    Text("\(selectedAPFSVolume?.name ?? "APFS Volume") • \(selectedDiskTrimmed)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AegiroPalette.textPrimary)
                case .nonAPFS:
                    let fs = selectedNonAPFSVolume?.filesystemType.uppercased() ?? "NON-APFS"
                    Text("\(selectedDiskTrimmed) • \(fs)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AegiroPalette.textPrimary)
                case .none, .invalid:
                    Text("No valid external volume selected.")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(AegiroPalette.warningAmber)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AegiroPalette.backgroundCard.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AegiroPalette.borderSubtle.opacity(0.8), lineWidth: 1)
            )

            switch selectionKind {
            case .apfs:
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

                if shouldShowEncryptionProgress {
                    encryptionProgressCard
                }
                Text("APFS reports block/volume encryption progress only. Per-file counts are not available from `diskutil`.")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(AegiroPalette.textMuted)
            case .nonAPFS:
                formLabel("Source Folder to Encrypt")
                HStack(spacing: 8) {
                    TextField("/Volumes/MyUSB", text: $sourcePath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose...") { chooseSourceFolder() }
                        .buttonStyle(.bordered)
                }

                formLabel("Vault File on USB")
                HStack(spacing: 8) {
                    TextField("/Volumes/MyUSB/data.agvt", text: $vaultPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose...") { chooseVaultPath() }
                        .buttonStyle(.bordered)
                }

                formLabel("Vault Passphrase")
                SecureField(dryRun ? "Optional for scan-only" : "8+ chars with upper/lower letters and numbers", text: $vaultPassphrase)
                    .textFieldStyle(.roundedBorder)
                if !dryRun || !vaultPassphrase.isEmpty {
                    PassphraseStrengthMeter(passphrase: vaultPassphrase)
                }

                formLabel("Confirm Passphrase")
                SecureField(dryRun ? "Optional for scan-only" : "Repeat passphrase", text: $confirmVaultPassphrase)
                    .textFieldStyle(.roundedBorder)

                Toggle("Dry run only (scan user files without encrypting)", isOn: $dryRun)
                Toggle("Delete original files after successful encryption", isOn: $deleteOriginals)
                    .disabled(dryRun)

                Text("System USB metadata is skipped automatically (.Spotlight-V100, .fseventsd, .Trashes, .DS_Store, System Volume Information).")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(AegiroPalette.textMuted)

                if !dryRun && vaultPassphrase != confirmVaultPassphrase && !confirmVaultPassphrase.isEmpty {
                    Text("Passphrases do not match.")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(AegiroPalette.dangerRed)
                }

                if !dryRun && !vaultPassphrase.isEmpty && !usbPassphraseStrength.isRequired {
                    Text("Passphrase must be 8+ chars and include uppercase, lowercase, and a number.")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(AegiroPalette.warningAmber)
                }

                if shouldShowUSBDataEncryptionProgress {
                    usbDataEncryptionProgressCard
                }
            case .none, .invalid:
                Text("Selection is no longer valid. Go back and select an external volume again.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(AegiroPalette.warningAmber)
            }

            HStack {
                Button("Back") {
                    formPhase = .selectVolume
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Cancel") { dismiss() }
                Button(submitButtonTitle) {
                    startEncrypt()
                }
                .buttonStyle(.borderedProminent)
                .tint(AegiroPalette.accentIndigo)
                .disabled(
                    !canSubmit
                    || (selectionKind == .apfs && !dryRun && isEncryptingSelectedDisk)
                    || (selectionKind == .nonAPFS && isEncryptingSelectedUSBUserData)
                )
            }
        }
    }

    private var encryptionProgressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            formLabel("Encryption Progress")
            if let fraction = model.diskEncryptionProgressFraction {
                ProgressView(value: max(0, min(1, fraction)))
                    .tint(AegiroPalette.securityGreen)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(model.diskEncryptionProgressMessage)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(AegiroPalette.textSecondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AegiroPalette.backgroundCard.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AegiroPalette.borderSubtle.opacity(0.8), lineWidth: 1)
        )
    }

    private var usbDataEncryptionProgressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            formLabel("USB User-Data Encryption Progress")
            if let fraction = model.usbDataEncryptionProgressFraction {
                ProgressView(value: max(0, min(1, fraction)))
                    .tint(AegiroPalette.securityGreen)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            if model.usbDataEncryptionTotalFiles > 0 {
                Text("\(model.usbDataEncryptionProcessedFiles) / \(model.usbDataEncryptionTotalFiles) files")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AegiroPalette.textPrimary)
            } else {
                Text("Preparing file list...")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(AegiroPalette.textSecondary)
            }
            Text(model.usbDataEncryptionProgressMessage)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(AegiroPalette.textSecondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AegiroPalette.backgroundCard.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AegiroPalette.borderSubtle.opacity(0.8), lineWidth: 1)
        )
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

    private func syncRecoveryPathWithDisk(_ diskID: String) {
        let suggested = defaultRecoveryPath(for: diskID)
        let trimmedCurrent = recoveryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCurrent.isEmpty || recoveryPath == lastSuggestedRecoveryPath {
            recoveryPath = suggested
        }
        lastSuggestedRecoveryPath = suggested
    }

    private func applyAutoDiskSelectionIfNeeded() {
        let trimmed = diskIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return }
        guard let preferred = preferredAPFSVolumeIdentifier(from: model.apfsVolumeOptions) else { return }
        diskIdentifier = preferred
    }

    private func syncFormFieldsForSelectionChange(force: Bool) {
        switch selectionKind {
        case .apfs:
            if recoveryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || force {
                syncRecoveryPathWithDisk(diskIdentifier)
            }
        case .nonAPFS:
            if let mount = selectedNonAPFSVolume?.mountPoint {
                syncSuggestedUSBPaths(for: mount, force: force)
            }
        case .none:
            applyAutoDiskSelectionIfNeeded()
        case .invalid:
            break
        }
    }

    private func continueToDetails() {
        guard canContinueFromSelection else { return }
        syncFormFieldsForSelectionChange(force: true)
        formPhase = .details
    }

    private func syncSuggestedUSBPaths(for mountPoint: String, force: Bool) {
        let mount = mountPoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mount.isEmpty else { return }

        let suggestedSource = mount
        if force || sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sourcePath == lastSuggestedSourcePath {
            sourcePath = suggestedSource
        }
        lastSuggestedSourcePath = suggestedSource

        let suggestedVault = defaultVaultPath(for: mount)
        if force || vaultPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vaultPath == lastSuggestedVaultPath {
            vaultPath = suggestedVault
        }
        lastSuggestedVaultPath = suggestedVault
    }

    private func defaultVaultPath(for mountPoint: String) -> String {
        URL(fileURLWithPath: mountPoint, isDirectory: true)
            .appendingPathComponent("data.agvt")
            .path
    }

    private func chooseSourceFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Source Folder to Encrypt"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        if !sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            panel.directoryURL = URL(fileURLWithPath: NSString(string: sourcePath).expandingTildeInPath, isDirectory: true)
        } else if let mount = selectedNonAPFSVolume?.mountPoint {
            panel.directoryURL = URL(fileURLWithPath: mount, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            sourcePath = url.path
        }
    }

    private func chooseVaultPath() {
        let panel = NSSavePanel()
        panel.title = "Choose Vault File"
        let mount = selectedNonAPFSVolume?.mountPoint ?? selectedDiskTrimmed
        panel.nameFieldStringValue = (defaultVaultPath(for: mount) as NSString).lastPathComponent
        panel.allowedContentTypes = [UTType(filenameExtension: "agvt") ?? .data]
        if !mount.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: mount, isDirectory: true)
        }
        if panel.runModal() == .OK, var url = panel.url {
            if url.pathExtension.lowercased() != "agvt" {
                url.appendPathExtension("agvt")
            }
            vaultPath = url.path
        }
    }

    private func startEncrypt() {
        switch selectionKind {
        case .apfs:
            let disk = selectedDiskTrimmed
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
            if dryRun {
                onDone()
                dismiss()
            }
        case .nonAPFS:
            let mount = selectedNonAPFSMountPoint
            let source = URL(fileURLWithPath: NSString(string: sourcePath).expandingTildeInPath, isDirectory: true).standardizedFileURL
            let vault = URL(fileURLWithPath: NSString(string: vaultPath).expandingTildeInPath).standardizedFileURL
            let mountRoot = URL(fileURLWithPath: mount, isDirectory: true).standardizedFileURL.path
            let mountPrefix = mountRoot.hasSuffix("/") ? mountRoot : mountRoot + "/"
            guard source.path == mountRoot || source.path.hasPrefix(mountPrefix) else {
                model.status = "Source folder must be inside \(mountRoot)"
                return
            }
            guard vault.path == mountRoot || vault.path.hasPrefix(mountPrefix) else {
                model.status = "Vault file must be inside \(mountRoot)"
                return
            }
            if !dryRun {
                guard usbPassphraseStrength.isRequired else {
                    model.status = "Passphrase is too weak. Use 8+ chars with uppercase, lowercase, and a number."
                    return
                }
                guard vaultPassphrase == confirmVaultPassphrase else {
                    model.status = "Passphrases do not match"
                    return
                }
            }

            model.encryptNonAPFSUSBUserData(sourceRootURL: source,
                                            vaultURL: vault,
                                            vaultPassphrase: vaultPassphrase,
                                            deleteOriginals: deleteOriginals && !dryRun,
                                            dryRun: dryRun,
                                            targetMountPoint: mount) { success in
                guard success else { return }
                onDone()
                dismiss()
            }
        case .none, .invalid:
            return
        }
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
    var onOpenUSBDataEncrypt: (String?) -> Void

    private var canSubmit: Bool {
        !diskIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !recoveryPassphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !recoveryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Decrypt External Disk")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(AegiroPalette.textPrimary)

            Text("Use a PQC recovery bundle + passphrase to decrypt (unlock) APFS external volumes.")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(AegiroPalette.textSecondary)

            APFSVolumeOptionsPanel(
                selectedDiskIdentifier: $diskIdentifier,
                options: model.apfsVolumeOptions,
                nonAPFSVolumes: model.mountedNonAPFSVolumes,
                isLoading: model.apfsVolumeOptionsLoading,
                errorMessage: model.apfsVolumeOptionsError,
                onSelectNonAPFSVolume: { volume in
                    openUSBDataEncryptFlow(mountPoint: volume.mountPoint)
                }
            ) {
                model.refreshAPFSVolumeOptions()
            }

            formLabel("Selected APFS Volume Identifier")
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
                Button(dryRun ? "Validate Bundle" : "Decrypt Disk") {
                    startUnlock()
                }
                .buttonStyle(.borderedProminent)
                .tint(AegiroPalette.accentIndigo)
                .disabled(!canSubmit)
            }
        }
        .padding(24)
        .frame(width: 640)
        .background(AegiroPalette.backgroundPanel)
        .onAppear {
            model.refreshAPFSVolumeOptions()
            applyAutoDiskSelectionIfNeeded()
        }
        .onChange(of: model.apfsVolumeOptions) { _ in
            applyAutoDiskSelectionIfNeeded()
        }
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

    private func applyAutoDiskSelectionIfNeeded() {
        let trimmed = diskIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return }
        guard let preferred = preferredAPFSVolumeIdentifier(from: model.apfsVolumeOptions) else { return }
        diskIdentifier = preferred
    }

    private func openUSBDataEncryptFlow(mountPoint: String?) {
        dismiss()
        DispatchQueue.main.async {
            onOpenUSBDataEncrypt(mountPoint)
        }
    }
}

private struct USBUserDataEncryptSheet: View {
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedMountPoint = ""
    @State private var sourcePath = ""
    @State private var vaultPath = ""
    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    @State private var lastSuggestedSourcePath = ""
    @State private var lastSuggestedVaultPath = ""
    @State private var deleteOriginals = false
    @State private var dryRun = false

    let preferredMountPoint: String?
    var onDone: () -> Void

    private var volumes: [MountedNonAPFSVolume] {
        model.mountedNonAPFSVolumes
    }

    private var passphraseStrength: PassphraseStrengthReport {
        PassphraseStrengthReport.evaluate(passphrase)
    }

    private var isEncryptingSelectedMount: Bool {
        let mount = selectedMountPoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = model.usbDataEncryptionTargetMountPoint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !mount.isEmpty, mount == target else { return false }
        return model.usbDataEncryptionActive
    }

    private var shouldShowUSBProgressCard: Bool {
        let mount = selectedMountPoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = model.usbDataEncryptionTargetMountPoint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !mount.isEmpty, mount == target else { return false }
        return model.usbDataEncryptionActive
            || model.usbDataEncryptionTotalFiles > 0
            || !model.usbDataEncryptionProgressMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSubmit: Bool {
        let pathsReady = !selectedMountPoint.isEmpty
        && !sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !vaultPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if dryRun {
            return pathsReady
        }
        return pathsReady
        && passphraseStrength.isRequired
        && passphrase == confirmPassphrase
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Encrypt USB User Data")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(AegiroPalette.textPrimary)

            Text("For non-APFS USB drives: encrypt user files into an Aegiro vault file without changing the USB format.")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(AegiroPalette.textSecondary)

            formLabel("Mounted Non-APFS Volume")
            if volumes.isEmpty {
                Text("No mounted non-APFS USB volumes found.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(AegiroPalette.warningAmber)
            } else {
                Picker("Mounted Non-APFS Volume", selection: $selectedMountPoint) {
                    Text("Select mounted volume").tag("")
                    ForEach(volumes, id: \.mountPoint) { volume in
                        Text("\(volume.mountPoint) (\(volume.filesystemType.uppercased()))").tag(volume.mountPoint)
                    }
                }
                .pickerStyle(.menu)
            }

            formLabel("Source Folder to Encrypt")
            HStack(spacing: 8) {
                TextField("/Volumes/MyUSB", text: $sourcePath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose...") { chooseSourceFolder() }
                    .buttonStyle(.bordered)
            }

            formLabel("Vault File on USB")
            HStack(spacing: 8) {
                TextField("/Volumes/MyUSB/data.agvt", text: $vaultPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose...") { chooseVaultPath() }
                    .buttonStyle(.bordered)
            }

            formLabel("Vault Passphrase")
            SecureField(dryRun ? "Optional for scan-only" : "8+ chars with upper/lower letters and numbers", text: $passphrase)
                .textFieldStyle(.roundedBorder)
            if !dryRun || !passphrase.isEmpty {
                PassphraseStrengthMeter(passphrase: passphrase)
            }

            formLabel("Confirm Passphrase")
            SecureField(dryRun ? "Optional for scan-only" : "Repeat passphrase", text: $confirmPassphrase)
                .textFieldStyle(.roundedBorder)

            Toggle("Dry run only (scan user files without encrypting)", isOn: $dryRun)
            Toggle("Delete original files after successful encryption", isOn: $deleteOriginals)
                .disabled(dryRun)

            Text("System USB metadata is skipped automatically (.Spotlight-V100, .fseventsd, .Trashes, .DS_Store, System Volume Information).")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(AegiroPalette.textMuted)

            if !dryRun && passphrase != confirmPassphrase && !confirmPassphrase.isEmpty {
                Text("Passphrases do not match.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(AegiroPalette.dangerRed)
            }

            if !dryRun && !passphrase.isEmpty && !passphraseStrength.isRequired {
                Text("Passphrase must be 8+ chars and include uppercase, lowercase, and a number.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(AegiroPalette.warningAmber)
            }

            if shouldShowUSBProgressCard {
                usbProgressCard
            }

            HStack {
                Spacer()
                Button("Refresh Volumes") {
                    model.refreshAPFSVolumeOptions()
                }
                .buttonStyle(.bordered)
                .disabled(isEncryptingSelectedMount)

                Button("Cancel") {
                    dismiss()
                }
                .disabled(isEncryptingSelectedMount)

                Button(isEncryptingSelectedMount ? (dryRun ? "Scanning..." : "Encrypting...") : (dryRun ? "Scan User Data" : "Encrypt User Data")) {
                    startEncrypt()
                }
                .buttonStyle(.borderedProminent)
                .tint(AegiroPalette.accentIndigo)
                .disabled(!canSubmit || isEncryptingSelectedMount)
            }
        }
        .padding(24)
        .frame(width: 700)
        .background(AegiroPalette.backgroundPanel)
        .onAppear {
            model.refreshAPFSVolumeOptions()
            model.clearUSBDataEncryptionProgressIfIdle()
            applyAutoSelectionIfNeeded(force: true)
        }
        .onChange(of: model.mountedNonAPFSVolumes) { _ in
            applyAutoSelectionIfNeeded(force: false)
        }
        .onChange(of: selectedMountPoint) { _ in
            syncSuggestedPaths(force: false)
        }
    }

    private func formLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AegiroPalette.textSecondary)
    }

    private var usbProgressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            formLabel("USB User-Data Encryption Progress")
            if let fraction = model.usbDataEncryptionProgressFraction {
                ProgressView(value: max(0, min(1, fraction)))
                    .tint(AegiroPalette.securityGreen)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            if model.usbDataEncryptionTotalFiles > 0 {
                Text("\(model.usbDataEncryptionProcessedFiles) / \(model.usbDataEncryptionTotalFiles) files")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AegiroPalette.textPrimary)
            } else {
                Text("Preparing file list...")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(AegiroPalette.textSecondary)
            }
            Text(model.usbDataEncryptionProgressMessage)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(AegiroPalette.textSecondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AegiroPalette.backgroundCard.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AegiroPalette.borderSubtle.opacity(0.8), lineWidth: 1)
        )
    }

    private func applyAutoSelectionIfNeeded(force: Bool) {
        let preferredTrimmed = preferredMountPoint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currentTrimmed = selectedMountPoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentIsValid = !currentTrimmed.isEmpty && volumes.contains(where: { $0.mountPoint == currentTrimmed })

        if !preferredTrimmed.isEmpty, volumes.contains(where: { $0.mountPoint == preferredTrimmed }), (force || !currentIsValid) {
            selectedMountPoint = preferredTrimmed
            syncSuggestedPaths(force: true)
            return
        }

        if force || !currentIsValid {
            selectedMountPoint = volumes.first?.mountPoint ?? ""
        }
        syncSuggestedPaths(force: force)
    }

    private func syncSuggestedPaths(force: Bool) {
        let mount = selectedMountPoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mount.isEmpty else { return }

        let suggestedSource = mount
        if force || sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sourcePath == lastSuggestedSourcePath {
            sourcePath = suggestedSource
        }
        lastSuggestedSourcePath = suggestedSource

        let suggestedVault = defaultVaultPath(for: mount)
        if force || vaultPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vaultPath == lastSuggestedVaultPath {
            vaultPath = suggestedVault
        }
        lastSuggestedVaultPath = suggestedVault
    }

    private func defaultVaultPath(for mountPoint: String) -> String {
        return URL(fileURLWithPath: mountPoint, isDirectory: true)
            .appendingPathComponent("data.agvt")
            .path
    }

    private func chooseSourceFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Source Folder to Encrypt"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        if !sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            panel.directoryURL = URL(fileURLWithPath: NSString(string: sourcePath).expandingTildeInPath, isDirectory: true)
        } else if !selectedMountPoint.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: selectedMountPoint, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            sourcePath = url.path
        }
    }

    private func chooseVaultPath() {
        let panel = NSSavePanel()
        panel.title = "Choose Vault File"
        panel.nameFieldStringValue = (defaultVaultPath(for: selectedMountPoint) as NSString).lastPathComponent
        panel.allowedContentTypes = [UTType(filenameExtension: "agvt") ?? .data]
        if !selectedMountPoint.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: selectedMountPoint, isDirectory: true)
        }
        if panel.runModal() == .OK, var url = panel.url {
            if url.pathExtension.lowercased() != "agvt" {
                url.appendPathExtension("agvt")
            }
            vaultPath = url.path
        }
    }

    private func startEncrypt() {
        let source = URL(fileURLWithPath: NSString(string: sourcePath).expandingTildeInPath, isDirectory: true).standardizedFileURL
        let vault = URL(fileURLWithPath: NSString(string: vaultPath).expandingTildeInPath).standardizedFileURL
        let mount = selectedMountPoint.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !mount.isEmpty else {
            model.status = "Select a mounted non-APFS volume"
            return
        }

        let mountRoot = URL(fileURLWithPath: mount, isDirectory: true).standardizedFileURL.path
        let mountPrefix = mountRoot.hasSuffix("/") ? mountRoot : mountRoot + "/"
        guard source.path == mountRoot || source.path.hasPrefix(mountPrefix) else {
            model.status = "Source folder must be inside \(mountRoot)"
            return
        }
        guard vault.path == mountRoot || vault.path.hasPrefix(mountPrefix) else {
            model.status = "Vault file must be inside \(mountRoot)"
            return
        }

        if !dryRun {
            guard passphraseStrength.isRequired else {
                model.status = "Passphrase is too weak. Use 8+ chars with uppercase, lowercase, and a number."
                return
            }
            guard passphrase == confirmPassphrase else {
                model.status = "Passphrases do not match"
                return
            }
        }

        model.encryptNonAPFSUSBUserData(sourceRootURL: source,
                                        vaultURL: vault,
                                        vaultPassphrase: passphrase,
                                        deleteOriginals: deleteOriginals && !dryRun,
                                        dryRun: dryRun,
                                        targetMountPoint: mount) { success in
            guard success else { return }
            onDone()
            dismiss()
        }
    }
}

private struct APFSVolumeOptionsPanel: View {
    private enum DisplayVolumeRow: Identifiable {
        case apfs(APFSVolumeOption)
        case nonAPFS(MountedNonAPFSVolume)

        var id: String {
            switch self {
            case .apfs(let option):
                return "apfs:\(option.identifier)"
            case .nonAPFS(let volume):
                return "nonapfs:\(volume.mountPoint)"
            }
        }
    }

    @Binding var selectedDiskIdentifier: String
    let options: [APFSVolumeOption]
    let nonAPFSVolumes: [MountedNonAPFSVolume]
    let isLoading: Bool
    let errorMessage: String?
    var onSelectNonAPFSVolume: ((MountedNonAPFSVolume) -> Void)?
    var refresh: () -> Void
    @State private var showAllVolumes = false

    private var selectedTrimmed: String {
        selectedDiskIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var mountedExternalOptions: [APFSVolumeOption] {
        mountedExternalAPFSVolumes(from: externalOptions)
    }

    private var externalOptions: [APFSVolumeOption] {
        externalAPFSVolumes(from: options)
    }

    private var visibleOptions: [APFSVolumeOption] {
        if showAllVolumes || mountedExternalOptions.isEmpty {
            return externalOptions
        }
        return mountedExternalOptions
    }

    private var displayRows: [DisplayVolumeRow] {
        var rows = visibleOptions.map(DisplayVolumeRow.apfs)
        rows.append(contentsOf: nonAPFSVolumes.map(DisplayVolumeRow.nonAPFS))
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(showAllVolumes || mountedExternalOptions.isEmpty ? "External Volumes" : "Mounted External Volumes")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AegiroPalette.textSecondary)
                Spacer()
                if !mountedExternalOptions.isEmpty && mountedExternalOptions.count != externalOptions.count {
                    Button(showAllVolumes ? "Show Mounted Only" : "Show All External") {
                        showAllVolumes.toggle()
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 11, weight: .semibold))
                }
                Button {
                    refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .disabled(isLoading)
            }

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning volumes...")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AegiroPalette.textSecondary)
                }
            }

            if let errorMessage, !errorMessage.isEmpty {
                Text("Could not load APFS options: \(errorMessage)")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(AegiroPalette.warningAmber)
            }

            if displayRows.isEmpty {
                Text(noAPFSMessage)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(AegiroPalette.textMuted)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(displayRows) { row in
                            switch row {
                            case .apfs(let option):
                                let isSelected = option.identifier == selectedTrimmed
                                Button {
                                    selectedDiskIdentifier = option.identifier
                                } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack(spacing: 6) {
                                                Text(option.name)
                                                    .font(.system(size: 13, weight: .semibold))
                                                    .foregroundStyle(AegiroPalette.textPrimary)
                                                if let locationBadge = locationBadgeLabel(for: option) {
                                                    badge(text: locationBadge, color: option.isInternalStore == false ? AegiroPalette.securityGreen : AegiroPalette.warningAmber)
                                                }
                                                if option.encrypted || option.fileVault {
                                                    badge(text: "Encrypted", color: AegiroPalette.accentIndigo)
                                                }
                                                if option.locked {
                                                    badge(text: "Locked", color: AegiroPalette.warningAmber)
                                                }
                                            }
                                            Text(option.identifier)
                                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                                .foregroundStyle(AegiroPalette.textSecondary)
                                            Text(optionMetaLine(for: option))
                                                .font(.system(size: 11, weight: .regular))
                                                .foregroundStyle(AegiroPalette.textMuted)
                                        }
                                        Spacer(minLength: 8)
                                        if isSelected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(AegiroPalette.securityGreen)
                                                .font(.system(size: 15, weight: .semibold))
                                        }
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(isSelected ? AegiroPalette.accentIndigo.opacity(0.18) : AegiroPalette.backgroundCard)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(isSelected ? AegiroPalette.accentIndigo : AegiroPalette.borderSubtle, lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            case .nonAPFS(let volume):
                                if let onSelectNonAPFSVolume {
                                    Button {
                                        onSelectNonAPFSVolume(volume)
                                    } label: {
                                        HStack(alignment: .top, spacing: 10) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                HStack(spacing: 6) {
                                                    Text(volume.mountPoint)
                                                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                                        .foregroundStyle(AegiroPalette.textPrimary)
                                                    badge(text: "Not APFS", color: AegiroPalette.warningAmber)
                                                }
                                            Text("\(volume.filesystemType.uppercased()) • \(volume.deviceIdentifier)")
                                                .font(.system(size: 11, weight: .regular))
                                                .foregroundStyle(AegiroPalette.textSecondary)
                                        }
                                        Spacer(minLength: 8)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(AegiroPalette.backgroundCard)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .stroke(AegiroPalette.borderSubtle, lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    HStack(alignment: .top, spacing: 10) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack(spacing: 6) {
                                                Text(volume.mountPoint)
                                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                                    .foregroundStyle(AegiroPalette.textMuted)
                                                badge(text: "Not APFS", color: AegiroPalette.textMuted)
                                            }
                                            Text("\(volume.filesystemType.uppercased()) • \(volume.deviceIdentifier)")
                                                .font(.system(size: 11, weight: .regular))
                                                .foregroundStyle(AegiroPalette.textMuted)
                                        }
                                        Spacer(minLength: 8)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(AegiroPalette.backgroundCard.opacity(0.65))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(AegiroPalette.borderSubtle.opacity(0.8), lineWidth: 1)
                                    )
                                    .opacity(0.72)
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 180)
            }
            if !nonAPFSVolumes.isEmpty {
                Text(nonAPFSHintMessage)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(AegiroPalette.textMuted)
            }
        }
        .padding(12)
        .background(AegiroPalette.backgroundCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AegiroPalette.borderSubtle, lineWidth: 1)
        )
    }

    private var noAPFSMessage: String {
        if nonAPFSVolumes.isEmpty {
            return "No external APFS volumes found. You can still type a disk identifier manually or use Show All External."
        }
        if onSelectNonAPFSVolume != nil {
            return "Mounted volumes were found, but none are APFS. Click a non-APFS row to start USB data encryption."
        }
        return "Mounted volumes were found, but none are APFS. Non-APFS rows are shown in gray and are not selectable here."
    }

    private var nonAPFSHintMessage: String {
        if onSelectNonAPFSVolume != nil {
            return "Non-APFS rows are clickable and will switch this flow to USB user-data encryption fields."
        }
        return "Gray rows are mounted but not APFS. Use Aegiro vault-file encryption on those drives, or reformat to APFS for disk-level APFS encryption."
    }

    private func optionMetaLine(for option: APFSVolumeOption) -> String {
        var parts: [String] = []
        if let mountPoint = option.mountPoint, !mountPoint.isEmpty {
            parts.append("Mounted at \(mountPoint)")
        } else {
            parts.append("Not mounted")
        }
        parts.append("Container \(option.containerIdentifier)")
        if !option.roles.isEmpty {
            parts.append("Role \(option.roles.joined(separator: ", "))")
        }
        if let physicalStore = option.physicalStoreIdentifier, !physicalStore.isEmpty {
            parts.append("Store \(physicalStore)")
        }
        return parts.joined(separator: " • ")
    }

    private func locationBadgeLabel(for option: APFSVolumeOption) -> String? {
        switch option.isInternalStore {
        case .some(true):
            return "Internal"
        case .some(false):
            return "External"
        case .none:
            return nil
        }
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }
}

private func preferredAPFSVolumeIdentifier(from options: [APFSVolumeOption]) -> String? {
    let external = externalAPFSVolumes(from: options)
    let mountedExternal = mountedExternalAPFSVolumes(from: external)
    let bestMountedExternal = mountedExternal.first {
        !$0.roles.contains(where: systemAPFSRoles.contains)
    }
    if let bestMountedExternal {
        return bestMountedExternal.identifier
    }
    if let fallbackMountedExternal = mountedExternal.first {
        return fallbackMountedExternal.identifier
    }

    let bestExternal = external.first {
        !$0.roles.contains(where: systemAPFSRoles.contains)
    }
    if let bestExternal {
        return bestExternal.identifier
    }
    let fallbackExternal = external.first
    if let fallbackExternal {
        return fallbackExternal.identifier
    }
    return nil
}

private func mountedExternalAPFSVolumes(from options: [APFSVolumeOption]) -> [APFSVolumeOption] {
    options.filter(isMountedExternalAPFSVolume)
}

private func externalAPFSVolumes(from options: [APFSVolumeOption]) -> [APFSVolumeOption] {
    options.filter(isExternalAPFSVolume)
}

private func isMountedExternalAPFSVolume(_ option: APFSVolumeOption) -> Bool {
    guard let mountPoint = option.mountPoint else {
        return false
    }
    if isExcludedSystemExternalMountPoint(mountPoint) {
        return false
    }
    return mountPoint == "/Volumes" || mountPoint.hasPrefix("/Volumes/")
}

private func isExternalAPFSVolume(_ option: APFSVolumeOption) -> Bool {
    if option.isInternalStore == true {
        return false
    }
    if let mountPoint = option.mountPoint {
        if isExcludedSystemExternalMountPoint(mountPoint) {
            return false
        }
        return mountPoint == "/Volumes" || mountPoint.hasPrefix("/Volumes/")
    }
    return option.isInternalStore == false
}

private func isExcludedSystemExternalMountPoint(_ mountPoint: String) -> Bool {
    let lowered = mountPoint.lowercased()
    return lowered.contains("/coresimulator/")
}

private let systemAPFSRoles: Set<String> = [
    "System",
    "Data",
    "Preboot",
    "Recovery",
    "VM",
    "Update",
    "Hardware",
    "xART"
]

private struct DoctorSheet: View {
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) private var dismiss

    @State private var report: DoctorReport?
    @State private var runMessage: String = ""
    @State private var isRunning = false

    private var canApplyFix: Bool {
        let trimmed = model.passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !model.locked
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Vault Doctor")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(AegiroPalette.textPrimary)

            Text("Run integrity checks directly in the app.")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(AegiroPalette.textSecondary)

            if let report {
                VStack(alignment: .leading, spacing: 8) {
                    doctorRow("Header", ok: report.headerOK)
                    doctorRow("Manifest", ok: report.manifestOK)
                    doctorRow("Chunk Area", ok: report.chunkAreaOK)
                    if let entries = report.entries {
                        HStack {
                            Text("Entries")
                                .foregroundStyle(AegiroPalette.textSecondary)
                            Spacer()
                            Text("\(entries)")
                                .foregroundStyle(AegiroPalette.textPrimary)
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                    if report.fixed {
                        Text("Fix applied: manifest was re-signed.")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AegiroPalette.securityGreen)
                    }
                }
                .padding(12)
                .background(AegiroPalette.backgroundCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AegiroPalette.borderSubtle, lineWidth: 1)
                )
            }

            if let report, !report.issues.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Issues")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AegiroPalette.textPrimary)
                    ForEach(report.issues, id: \.self) { issue in
                        Text("- \(issue)")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(AegiroPalette.textSecondary)
                    }
                }
                .padding(12)
                .background(AegiroPalette.backgroundCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AegiroPalette.borderSubtle, lineWidth: 1)
                )
            }

            if !canApplyFix {
                Text("Unlock the vault with your passphrase to enable Apply Fix.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(AegiroPalette.warningAmber)
            }

            if !runMessage.isEmpty {
                Text(runMessage)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(AegiroPalette.textSecondary)
            }

            HStack {
                Button("Run Check") {
                    runDoctor(fix: false)
                }
                .buttonStyle(.borderedProminent)
                .tint(AegiroPalette.accentIndigo)
                .disabled(isRunning)

                Button("Apply Fix") {
                    runDoctor(fix: true)
                }
                .buttonStyle(.bordered)
                .disabled(isRunning || !canApplyFix)

                Spacer()

                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AegiroPalette.securityGreen)
                }

                Button("Close") {
                    dismiss()
                }
            }
        }
        .padding(24)
        .frame(width: 580)
        .background(AegiroPalette.backgroundPanel)
        .onAppear {
            if report == nil {
                runDoctor(fix: false)
            }
        }
    }

    private func doctorRow(_ label: String, ok: Bool) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(AegiroPalette.textSecondary)
            Spacer()
            Text(ok ? "OK" : "BAD")
                .foregroundStyle(ok ? AegiroPalette.securityGreen : AegiroPalette.dangerRed)
        }
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
    }

    private func runDoctor(fix: Bool) {
        guard let vaultURL = model.vaultURL else {
            runMessage = "Open a vault first."
            return
        }

        let trimmedPass = model.passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let passphrase = trimmedPass.isEmpty ? nil : trimmedPass

        isRunning = true
        runMessage = fix ? "Running doctor and applying fix..." : "Running doctor..."

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try Doctor.run(vaultURL: vaultURL, passphrase: passphrase, fix: fix)
                DispatchQueue.main.async {
                    report = result
                    if fix {
                        let flagsChanged = model.normalizeUnlockFlagsIfNeeded()
                        switch (result.fixed, flagsChanged) {
                        case (true, true):
                            runMessage = "Doctor completed. Applied manifest fix and normalized unlock flags."
                        case (true, false):
                            runMessage = "Doctor completed. Applied manifest fix."
                        case (false, true):
                            runMessage = "Doctor completed. Normalized unlock flags."
                        case (false, false):
                            runMessage = "Doctor completed. No fixes were needed."
                        }
                    } else {
                        runMessage = "Doctor completed."
                    }
                    isRunning = false
                    model.refreshStatus()
                }
            } catch {
                DispatchQueue.main.async {
                    runMessage = "Doctor failed: \(error)"
                    isRunning = false
                }
            }
        }
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
