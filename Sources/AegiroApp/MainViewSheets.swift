import SwiftUI
import AppKit
import AegiroCore
import UniformTypeIdentifiers

struct USBEncryptionWorkspacePage: View {
    private enum EncryptionOption: String, CaseIterable, Identifiable {
        case apfsDisk
        case vaultFile
        case usbContainer

        var id: String { rawValue }

        var title: String {
            switch self {
            case .apfsDisk:
                return "APFS Volume Encrypt / Decrypt"
            case .vaultFile:
                return "Vault Pack (usb-vault-pack)"
            case .usbContainer:
                return "USB Container (Create / Open / Close)"
            }
        }

        var summary: String {
            switch self {
            case .apfsDisk:
                return "apfs-volume-encrypt / apfs-volume-decrypt for APFS volumes with PQC recovery bundle."
            case .vaultFile:
                return "usb-vault-pack to encrypt user files into .agvt without reformatting."
            case .usbContainer:
                return "usb-container-create / usb-container-open / usb-container-close for encrypted sparsebundle workflow."
            }
        }
    }

    private enum APFSAction: String, CaseIterable, Identifiable {
        case encrypt
        case decrypt

        var id: String { rawValue }

        var title: String {
            switch self {
            case .encrypt:
                return "Encrypt"
            case .decrypt:
                return "Decrypt"
            }
        }
    }

    private enum WorkspaceStage {
        case selectOption
        case configureOption
        case progress
        case success
    }

    private struct VaultPackSuccessState {
        let result: USBUserDataEncryptResult
        let sourceRootPath: String
        let mountPoint: String
        let unlockPassphrase: String
        let completedAt: Date
        let elapsedDuration: TimeInterval?
    }

    @EnvironmentObject private var model: VaultModel

    @State private var selectedVolume = ""
    @State private var selectedOption: EncryptionOption?
    @State private var stage: WorkspaceStage = .selectOption

    @State private var recoveryPassphrase = ""
    @State private var recoveryPath = ""
    @State private var lastSuggestedRecoveryPath = ""
    @State private var apfsAction: APFSAction = .encrypt
    @State private var apfsDryRun = false
    @State private var apfsOverwrite = false

    @State private var sourcePath = ""
    @State private var vaultPath = ""
    @State private var vaultPassphrase = ""
    @State private var confirmVaultPassphrase = ""
    @State private var deleteOriginals = false
    @State private var vaultFileDryRun = false
    @State private var vaultPackExcludedPaths: [String] = []
    @State private var lastSuggestedSourcePath = ""
    @State private var lastSuggestedVaultPath = ""
    @State private var vaultPackSuccessState: VaultPackSuccessState?

    var onBackToVault: () -> Void
    var onOpenUSBContainer: () -> Void

    private var selectedTrimmed: String {
        selectedVolume.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var externalAPFSOptions: [APFSVolumeOption] {
        externalAPFSVolumes(from: model.apfsVolumeOptions)
    }

    private var selectedAPFSVolume: APFSVolumeOption? {
        externalAPFSOptions.first { $0.identifier == selectedTrimmed }
    }

    private var selectedNonAPFSVolume: MountedNonAPFSVolume? {
        model.mountedNonAPFSVolumes.first { $0.mountPoint == selectedTrimmed }
    }

    private var selectedMountPoint: String? {
        selectedNonAPFSVolume?.mountPoint ?? selectedAPFSVolume?.mountPoint
    }

    private var hasValidSelection: Bool {
        selectedAPFSVolume != nil || selectedNonAPFSVolume != nil
    }

    private var recommendedOption: EncryptionOption? {
        if selectedAPFSVolume != nil {
            return .apfsDisk
        }
        if selectedNonAPFSVolume != nil {
            return .vaultFile
        }
        return nil
    }

    private var vaultPassphraseStrength: PassphraseStrengthReport {
        PassphraseStrengthReport.evaluate(vaultPassphrase)
    }

    private var isAPFSEncryptingSelectedDisk: Bool {
        guard let selectedAPFSVolume else { return false }
        let target = model.diskEncryptionMonitoringDiskIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return model.diskEncryptionMonitoringActive && target == selectedAPFSVolume.identifier
    }

    private var isVaultFileEncryptingSelectedMount: Bool {
        let mount = normalizedMountPath(selectedMountPoint)
        guard !mount.isEmpty else {
            return false
        }
        let target = normalizedMountPath(model.usbDataEncryptionTargetMountPoint)
        return model.usbDataEncryptionActive && target == mount
    }

    private var vaultFileProgressDetail: String {
        switch model.usbDataEncryptionStage {
        case .scanning:
            if model.usbDataEncryptionProcessedFiles > 0 {
                return "Scanning... found \(model.usbDataEncryptionProcessedFiles) file(s)"
            }
            return "Scanning source files..."
        case .preparing:
            if model.usbDataEncryptionTotalFiles > 0 {
                return "Preparing \(model.usbDataEncryptionProcessedFiles) / \(model.usbDataEncryptionTotalFiles) files"
            }
            return "Preparing file list..."
        case .encrypting:
            if model.usbDataEncryptionTotalFiles > 0 {
                return "\(model.usbDataEncryptionProcessedFiles) / \(model.usbDataEncryptionTotalFiles) files"
            }
            return "Preparing file list..."
        case .deletingOriginals:
            if model.usbDataEncryptionTotalFiles > 0 {
                return "Deleting originals: \(model.usbDataEncryptionProcessedFiles) / \(model.usbDataEncryptionTotalFiles) files"
            }
            return "Deleting original files..."
        case .completed:
            if model.usbDataEncryptionTotalFiles > 0 {
                return "\(model.usbDataEncryptionProcessedFiles) / \(model.usbDataEncryptionTotalFiles) files"
            }
            return "Completed"
        }
    }

    private func vaultFileElapsedDuration(at now: Date) -> TimeInterval? {
        guard let startedAt = model.usbDataEncryptionLogs.first?.timestamp else { return nil }
        let finishedAt = model.usbDataEncryptionLogs.last?.timestamp
        let end = model.usbDataEncryptionActive ? now : (finishedAt ?? now)
        return max(0, end.timeIntervalSince(startedAt))
    }

    private func formattedElapsedDuration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    private var shouldShowVaultFileProgressSection: Bool {
        if model.usbDataEncryptionActive {
            return true
        }
        if let fraction = model.usbDataEncryptionProgressFraction {
            return fraction > 0
        }
        return false
    }

    private var existingVaultPathWarning: String? {
        let trimmedVault = vaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVault.isEmpty else { return nil }
        let normalizedVaultPath = URL(fileURLWithPath: NSString(string: trimmedVault).expandingTildeInPath).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: normalizedVaultPath) else { return nil }
        return "Warning: \(normalizedVaultPath) already exists. Vault Pack updates the existing vault and replaces entries that have matching source paths."
    }

    private var selectedOptionButtonTitle: String {
        guard let selectedOption else {
            return "Select Encryption Option"
        }
        switch selectedOption {
        case .apfsDisk:
            switch apfsAction {
            case .encrypt:
                if apfsDryRun {
                    return "Generate Recovery Bundle"
                }
                return isAPFSEncryptingSelectedDisk ? "Encrypting..." : "Encrypt APFS Volume"
            case .decrypt:
                if apfsDryRun {
                    return "Validate Recovery Bundle"
                }
                return "Decrypt APFS Volume"
            }
        case .vaultFile:
            if isVaultFileEncryptingSelectedMount {
                return vaultFileDryRun ? "Scanning..." : "Encrypting..."
            }
            return vaultFileDryRun ? "Scan User Files" : "Encrypt User Files"
        case .usbContainer:
            return "Open Container Create/Open/Close"
        }
    }

    private var canRunSelectedOption: Bool {
        guard let selectedOption else { return false }
        switch selectedOption {
        case .apfsDisk:
            return optionIsAvailable(.apfsDisk)
            && !recoveryPassphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !recoveryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(apfsAction == .encrypt && isAPFSEncryptingSelectedDisk && !apfsDryRun)
        case .vaultFile:
            guard optionIsAvailable(.vaultFile) else { return false }
            let hasPaths = !sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !vaultPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if vaultFileDryRun {
                return hasPaths && !isVaultFileEncryptingSelectedMount
            }
            return hasPaths
                && vaultPassphraseStrength.isRequired
                && vaultPassphrase == confirmVaultPassphrase
                && !isVaultFileEncryptingSelectedMount
        case .usbContainer:
            return true
        }
    }

    private var canOpenSelectedOptionConfiguration: Bool {
        guard let selectedOption else { return false }
        return optionIsAvailable(selectedOption)
    }

    private var configureButtonTitle: String {
        guard let selectedOption else {
            return "Select Encryption Option"
        }
        return "Configure \(selectedOption.title)"
    }

    private var selectedVolumeSummary: String {
        if let apfs = selectedAPFSVolume {
            let mount = apfs.mountPoint ?? "Not mounted"
            return "APFS • \(apfs.identifier) • \(mount)"
        }
        if let nonAPFS = selectedNonAPFSVolume {
            return "\(nonAPFS.filesystemType.uppercased()) • \(nonAPFS.mountPoint) • \(nonAPFS.deviceIdentifier)"
        }
        if selectedTrimmed.isEmpty {
            return "Select a USB volume to continue."
        }
        return "Selected value is not recognized as an external APFS/non-APFS USB volume."
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("USB Encryption")
                                .font(AegiroTypography.display(24, weight: .semibold))
                                .foregroundStyle(AegiroPalette.textPrimary)
                            Text("Select a USB volume, choose the best encryption flow for its format, then run encryption directly from this page.")
                                .font(AegiroTypography.body(13, weight: .regular))
                                .foregroundStyle(AegiroPalette.textSecondary)
                        }
                        Spacer()
                        Button("Back to Vault") {
                            onBackToVault()
                        }
                        .buttonStyle(.bordered)
                    }

                    if stage == .selectOption {
                        volumeSelectionCard
                        encryptionOptionCard

                        HStack {
                            Spacer()
                            Button(configureButtonTitle) {
                                openSelectedOptionConfiguration()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(AegiroPalette.accentIndigo)
                            .disabled(!canOpenSelectedOptionConfiguration)
                        }
                    } else if stage == .configureOption {
                        configurationHeaderCard
                        selectedOptionFormCard

                        HStack {
                            Button("Back") {
                                stage = .selectOption
                            }
                            .buttonStyle(.bordered)
                            Spacer()
                            Button(selectedOptionButtonTitle) {
                                runSelectedOption()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(AegiroPalette.accentIndigo)
                            .disabled(!canRunSelectedOption)
                        }
                    } else if stage == .success {
                        vaultPackSuccessStageContent
                    } else {
                        progressStageContent
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minWidth: proxy.size.width, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(AegiroPalette.backgroundMain)
        }
        .onAppear {
            stage = .selectOption
            vaultPackSuccessState = nil
            model.refreshAPFSVolumeOptions()
            model.clearUSBDataEncryptionProgressIfIdle()
            applyAutoSelectionIfNeeded(force: true)
            syncDefaultsForSelection(force: true)
            ensureSelectedOptionIsValid()
        }
        .onChange(of: model.apfsVolumeOptions) { _ in
            applyAutoSelectionIfNeeded(force: false)
            syncDefaultsForSelection(force: false)
            ensureSelectedOptionIsValid()
        }
        .onChange(of: model.mountedNonAPFSVolumes) { _ in
            applyAutoSelectionIfNeeded(force: false)
            syncDefaultsForSelection(force: false)
            ensureSelectedOptionIsValid()
        }
        .onChange(of: selectedVolume) { _ in
            syncDefaultsForSelection(force: false)
            ensureSelectedOptionIsValid()
        }
        .onChange(of: sourcePath) { _ in
            syncDefaultHiddenExclusionsForSource()
        }
    }

    private var configurationHeaderCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let selectedOption {
                Text(selectedOption.title)
                    .font(AegiroTypography.body(14, weight: .semibold))
                    .foregroundStyle(AegiroPalette.textPrimary)
                Text(selectedVolumeSummary)
                    .font(AegiroTypography.body(11, weight: .regular))
                    .foregroundStyle(hasValidSelection ? AegiroPalette.textSecondary : AegiroPalette.warningAmber)
            } else {
                Text("Select an encryption option first.")
                    .font(AegiroTypography.body(12, weight: .regular))
                    .foregroundStyle(AegiroPalette.warningAmber)
            }
        }
        .padding(12)
        .background(AegiroPalette.backgroundCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AegiroPalette.borderSubtle, lineWidth: 1)
        )
    }

    private var volumeSelectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            formLabel("USB Volume")
            APFSVolumeOptionsPanel(
                selectedDiskIdentifier: $selectedVolume,
                options: model.apfsVolumeOptions,
                nonAPFSVolumes: model.mountedNonAPFSVolumes,
                isLoading: model.apfsVolumeOptionsLoading,
                errorMessage: model.apfsVolumeOptionsError,
                onSelectNonAPFSVolume: { volume in
                    selectedVolume = volume.mountPoint
                    syncSuggestedVaultPaths(for: volume.mountPoint, force: true)
                }
            ) {
                model.refreshAPFSVolumeOptions()
            }

            formLabel("Selected Volume Identifier / Mount")
            TextField("disk9s1 or /Volumes/MyUSB", text: $selectedVolume)
                .textFieldStyle(.roundedBorder)

            Text(selectedVolumeSummary)
                .font(AegiroTypography.body(11, weight: .regular))
                .foregroundStyle(hasValidSelection ? AegiroPalette.textSecondary : AegiroPalette.warningAmber)
        }
        .padding(12)
        .background(AegiroPalette.backgroundCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AegiroPalette.borderSubtle, lineWidth: 1)
        )
    }

    private var encryptionOptionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            formLabel("Encryption Option")
            ForEach(EncryptionOption.allCases) { option in
                encryptionOptionRow(option)
            }
        }
        .padding(12)
        .background(AegiroPalette.backgroundCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AegiroPalette.borderSubtle, lineWidth: 1)
        )
    }

    private var selectedOptionFormCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selectedOption {
                switch selectedOption {
                case .apfsDisk:
                    apfsOptionForm
                case .vaultFile:
                    vaultFileOptionForm
                case .usbContainer:
                    usbContainerOptionForm
                }
            } else {
                Text("Select an encryption option to configure command inputs.")
                    .font(AegiroTypography.body(12, weight: .regular))
                    .foregroundStyle(AegiroPalette.textSecondary)
            }
        }
        .padding(12)
        .background(AegiroPalette.backgroundCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AegiroPalette.borderSubtle, lineWidth: 1)
        )
    }

    private func encryptionOptionRow(_ option: EncryptionOption) -> some View {
        let isSelected = selectedOption == option
        let isAvailable = optionIsAvailable(option)
        let isRecommended = recommendedOption == option && isAvailable
        let isRecommendedHighlight = isRecommended && selectedOption == nil

        return Button {
            guard isAvailable else { return }
            selectedOption = option
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(option.title)
                            .font(AegiroTypography.body(13, weight: .semibold))
                            .foregroundStyle(isAvailable ? AegiroPalette.textPrimary : AegiroPalette.textMuted)
                        if isRecommended {
                            badge(text: "Recommended", color: AegiroPalette.securityGreen)
                        }
                        if !isAvailable {
                            badge(text: "Unavailable", color: AegiroPalette.warningAmber)
                        }
                    }
                    Text(option.summary)
                        .font(AegiroTypography.body(11, weight: .regular))
                        .foregroundStyle(isAvailable ? AegiroPalette.textSecondary : AegiroPalette.textMuted)
                    if let hint = unavailableHint(for: option), !isAvailable {
                        Text(hint)
                            .font(AegiroTypography.body(11, weight: .regular))
                            .foregroundStyle(AegiroPalette.warningAmber)
                    }
                }
                Spacer(minLength: 8)
                if isSelected && isAvailable {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AegiroPalette.securityGreen)
                        .font(AegiroTypography.body(15, weight: .semibold))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill((isSelected && isAvailable) || isRecommendedHighlight
                          ? AegiroPalette.accentIndigo.opacity(0.18)
                          : AegiroPalette.backgroundMain.opacity(0.65))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke((isSelected && isAvailable) || isRecommendedHighlight
                            ? AegiroPalette.accentIndigo
                            : AegiroPalette.borderSubtle,
                            lineWidth: 1)
            )
            .opacity(isAvailable ? 1 : 0.75)
        }
        .buttonStyle(.plain)
    }

    private var apfsOptionForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            formLabel("APFS Volume (apfs-volume-encrypt / apfs-volume-decrypt)")
            if let apfs = selectedAPFSVolume {
                Text("Selected APFS volume: \(apfs.name) (\(apfs.identifier))")
                    .font(AegiroTypography.body(12, weight: .medium))
                    .foregroundStyle(AegiroPalette.textPrimary)
            } else {
                Text("Choose an APFS volume to use this option.")
                    .font(AegiroTypography.body(12, weight: .regular))
                    .foregroundStyle(AegiroPalette.warningAmber)
            }

            Picker("APFS Action", selection: $apfsAction) {
                ForEach(APFSAction.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            .pickerStyle(.segmented)

            formLabel("Recovery Passphrase")
            SecureField(apfsAction == .encrypt ? "Required to protect the PQC recovery bundle" : "Required to unlock using recovery bundle", text: $recoveryPassphrase)
                .textFieldStyle(.roundedBorder)

            formLabel("Recovery Bundle File")
            HStack(spacing: 8) {
                TextField("/path/to/disk.aegiro-diskkey.json", text: $recoveryPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose...") {
                    chooseRecoveryPath()
                }
                .buttonStyle(.bordered)
            }

            Toggle("Dry run only", isOn: $apfsDryRun)
            if apfsAction == .encrypt {
                Toggle("Overwrite existing recovery bundle", isOn: $apfsOverwrite)
            }

            Text("APFS option covers both encrypt and decrypt commands for the selected APFS external volume.")
                .font(AegiroTypography.body(10, weight: .regular))
                .foregroundStyle(AegiroPalette.textMuted)

            if apfsAction == .encrypt && isAPFSEncryptingSelectedDisk {
                progressCard(title: "APFS Encryption Progress",
                             message: model.diskEncryptionProgressMessage,
                             fraction: model.diskEncryptionProgressFraction,
                             detail: nil)
            }
        }
    }

    private var vaultFileOptionForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            formLabel("Vault Pack (usb-vault-pack)")
            if let mount = selectedMountPoint {
                Text("Target mount: \(mount)")
                    .font(AegiroTypography.body(12, weight: .medium))
                    .foregroundStyle(AegiroPalette.textPrimary)
            } else {
                Text("Select a mounted USB volume to use vault-file encryption.")
                    .font(AegiroTypography.body(12, weight: .regular))
                    .foregroundStyle(AegiroPalette.warningAmber)
            }

            formLabel("Source Folder to Encrypt")
            HStack(spacing: 8) {
                TextField("/Volumes/MyUSB", text: $sourcePath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose...") {
                    chooseSourceFolder()
                }
                .buttonStyle(.bordered)
            }

            formLabel("Vault File on USB")
            HStack(spacing: 8) {
                TextField("/Volumes/MyUSB/data.agvt", text: $vaultPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose...") {
                    chooseVaultPath()
                }
                .buttonStyle(.bordered)
            }
            if let existingVaultPathWarning {
                Text(existingVaultPathWarning)
                    .font(AegiroTypography.body(11, weight: .regular))
                    .foregroundStyle(AegiroPalette.warningAmber)
            }

            formLabel("Vault Passphrase")
            SecureField(vaultFileDryRun ? "Optional for scan-only" : "8+ chars with upper/lower letters and numbers", text: $vaultPassphrase)
                .textFieldStyle(.roundedBorder)
            if !vaultFileDryRun || !vaultPassphrase.isEmpty {
                PassphraseStrengthMeter(passphrase: vaultPassphrase)
            }

            formLabel("Confirm Passphrase")
            SecureField(vaultFileDryRun ? "Optional for scan-only" : "Repeat passphrase", text: $confirmVaultPassphrase)
                .textFieldStyle(.roundedBorder)

            Toggle("Dry run only (scan user files without encrypting)", isOn: $vaultFileDryRun)
            Toggle("Delete original files after successful encryption", isOn: $deleteOriginals)
                .disabled(vaultFileDryRun)

            formLabel("Do Not Encrypt (Optional)")
            VStack(alignment: .leading, spacing: 6) {
                if vaultPackExcludedPaths.isEmpty {
                    Text("No exclusions selected. Use this to skip USB/system folders or any paths you do not want encrypted.")
                        .font(AegiroTypography.body(11, weight: .regular))
                        .foregroundStyle(AegiroPalette.textMuted)
                } else {
                    ForEach(vaultPackExcludedPaths, id: \.self) { path in
                        HStack(spacing: 8) {
                            Text(path)
                                .font(AegiroTypography.mono(11, weight: .regular))
                                .foregroundStyle(AegiroPalette.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                vaultPackExcludedPaths.removeAll { $0 == path }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(AegiroPalette.textMuted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                HStack(spacing: 8) {
                    Button("Add Files/Folders...") {
                        chooseVaultPackExcludedPaths()
                    }
                    .buttonStyle(.bordered)
                    if !vaultPackExcludedPaths.isEmpty {
                        Button("Clear Exclusions") {
                            vaultPackExcludedPaths.removeAll()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Text("Only exclusions inside Source Folder are applied.")
                    .font(AegiroTypography.body(10, weight: .regular))
                    .foregroundStyle(AegiroPalette.textMuted)
            }

            Text("Single command flow: usb-vault-pack. Recommended for non-APFS drives when you want file-level vault packing.")
                .font(AegiroTypography.body(10, weight: .regular))
                .foregroundStyle(AegiroPalette.textMuted)

            if !vaultFileDryRun && vaultPassphrase != confirmVaultPassphrase && !confirmVaultPassphrase.isEmpty {
                Text("Passphrases do not match.")
                    .font(AegiroTypography.body(12, weight: .regular))
                    .foregroundStyle(AegiroPalette.dangerRed)
            }

            if !vaultFileDryRun && !vaultPassphrase.isEmpty && !vaultPassphraseStrength.isRequired {
                Text("Passphrase must be 8+ chars and include uppercase, lowercase, and a number.")
                    .font(AegiroTypography.body(12, weight: .regular))
                    .foregroundStyle(AegiroPalette.warningAmber)
            }

        }
    }

    private var usbContainerOptionForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            formLabel("USB Container Commands")
            Text("This flow maps to three commands:")
                .font(AegiroTypography.body(12, weight: .regular))
                .foregroundStyle(AegiroPalette.textSecondary)
            Text("usb-container-create / usb-container-open / usb-container-close")
                .font(AegiroTypography.mono(11, weight: .semibold))
                .foregroundStyle(AegiroPalette.textPrimary)
            Text("Use it when you want an encrypted APFS container file (.sparsebundle) on any writable external filesystem.")
                .font(AegiroTypography.body(11, weight: .regular))
                .foregroundStyle(AegiroPalette.textSecondary)

            Button("Open USB Container Create/Open/Close") {
                onOpenUSBContainer()
            }
            .buttonStyle(.bordered)
        }
    }

    private var progressStageContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            configurationHeaderCard
            if selectedOption == .vaultFile {
                if shouldShowVaultFileProgressSection {
                    progressCard(title: "Vault-File Encryption Progress",
                                 message: model.usbDataEncryptionProgressMessage,
                                 fraction: model.usbDataEncryptionProgressFraction,
                                 detail: vaultFileProgressDetail)
                } else {
                    Text(model.usbDataEncryptionProgressMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "No active encryption progress."
                         : model.usbDataEncryptionProgressMessage)
                        .font(AegiroTypography.body(12, weight: .regular))
                        .foregroundStyle(AegiroPalette.textSecondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(AegiroPalette.backgroundMain.opacity(0.72))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(AegiroPalette.borderSubtle.opacity(0.8), lineWidth: 1)
                        )
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let elapsed = vaultFileElapsedDuration(at: context.date) {
                        Text("Elapsed: \(formattedElapsedDuration(elapsed))")
                            .font(AegiroTypography.mono(11, weight: .semibold))
                            .foregroundStyle(AegiroPalette.textSecondary)
                    }
                }
                usbEncryptionDebugLogCard

                HStack {
                    if model.usbDataEncryptionActive {
                        Button("Cancel Encryption") {
                            model.cancelUSBDataEncryption()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AegiroPalette.dangerRed)
                    }
                    Spacer()
                    Button("Back to Configuration") {
                        stage = .configureOption
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.usbDataEncryptionActive)
                }
            } else {
                Text("No active USB vault-pack progress for the selected option.")
                    .font(AegiroTypography.body(12, weight: .regular))
                    .foregroundStyle(AegiroPalette.textSecondary)
                HStack {
                    Spacer()
                    Button("Back to Configuration") {
                        stage = .configureOption
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .background(AegiroPalette.backgroundCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AegiroPalette.borderSubtle, lineWidth: 1)
        )
    }

    private var vaultPackSuccessStageContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let success = vaultPackSuccessState {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(AegiroPalette.securityGreen)
                        Text("Vault Encryption Complete")
                            .font(AegiroTypography.body(14, weight: .semibold))
                            .foregroundStyle(AegiroPalette.textPrimary)
                    }
                    Text("Your files were packed into an encrypted vault. Use the steps below to open or decrypt/export your data.")
                        .font(AegiroTypography.body(12, weight: .regular))
                        .foregroundStyle(AegiroPalette.textSecondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    formLabel("Vault Info")
                    Text("Vault: \(success.result.vaultURL.path)")
                        .font(AegiroTypography.mono(11, weight: .regular))
                        .foregroundStyle(AegiroPalette.textPrimary)
                        .textSelection(.enabled)
                    Text("Source folder: \(success.sourceRootPath)")
                        .font(AegiroTypography.mono(11, weight: .regular))
                        .foregroundStyle(AegiroPalette.textSecondary)
                        .textSelection(.enabled)
                    Text("Volume: \(success.mountPoint)")
                        .font(AegiroTypography.body(11, weight: .regular))
                        .foregroundStyle(AegiroPalette.textSecondary)
                    Text("Files encrypted: \(success.result.encryptedFileCount) / \(success.result.scannedFileCount)")
                        .font(AegiroTypography.body(11, weight: .semibold))
                        .foregroundStyle(AegiroPalette.textPrimary)
                    Text("Skipped files/folders: \(success.result.skippedPathCount)")
                        .font(AegiroTypography.body(11, weight: .regular))
                        .foregroundStyle(AegiroPalette.textSecondary)
                    if deleteOriginals {
                        Text("Original files deleted: \(success.result.deletedOriginalCount)")
                            .font(AegiroTypography.body(11, weight: .regular))
                            .foregroundStyle(AegiroPalette.textSecondary)
                    }
                    Text("Completed at: \(success.completedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(AegiroTypography.body(11, weight: .regular))
                        .foregroundStyle(AegiroPalette.textMuted)
                    if let elapsed = success.elapsedDuration {
                        Text("Elapsed: \(formattedElapsedDuration(elapsed))")
                            .font(AegiroTypography.mono(11, weight: .semibold))
                            .foregroundStyle(AegiroPalette.textSecondary)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AegiroPalette.backgroundMain.opacity(0.72))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AegiroPalette.borderSubtle.opacity(0.8), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 8) {
                    formLabel("How to Decrypt / Export")
                    Text("1. Click \"Open Created Vault\" below.")
                        .font(AegiroTypography.body(11, weight: .regular))
                        .foregroundStyle(AegiroPalette.textSecondary)
                    Text("2. Unlock the vault in the app using the same passphrase you used for encryption.")
                        .font(AegiroTypography.body(11, weight: .regular))
                        .foregroundStyle(AegiroPalette.textSecondary)
                    Text("3. In the vault page, select the files you want to recover.")
                        .font(AegiroTypography.body(11, weight: .regular))
                        .foregroundStyle(AegiroPalette.textSecondary)
                    Text("4. Click \"Export Selected\" and choose an output folder.")
                        .font(AegiroTypography.body(11, weight: .regular))
                        .foregroundStyle(AegiroPalette.textSecondary)
                    Text("5. If you close this screen, use \"Open Existing\" in the app and select this vault file to reopen it.")
                        .font(AegiroTypography.body(11, weight: .regular))
                        .foregroundStyle(AegiroPalette.textSecondary)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AegiroPalette.backgroundMain.opacity(0.72))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AegiroPalette.borderSubtle.opacity(0.8), lineWidth: 1)
                )

                HStack {
                    Button("Encrypt More Files") {
                        vaultPackSuccessState = nil
                        stage = .configureOption
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button("Reveal Vault in Finder") {
                        revealCreatedVaultInFinder()
                    }
                    .buttonStyle(.bordered)
                    Button("Open Created Vault") {
                        openCreatedVaultFromSuccess()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AegiroPalette.securityGreen)
                }
            } else {
                Text("No completed vault-pack result is available yet.")
                    .font(AegiroTypography.body(12, weight: .regular))
                    .foregroundStyle(AegiroPalette.textSecondary)
                HStack {
                    Spacer()
                    Button("Back to Configuration") {
                        stage = .configureOption
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .background(AegiroPalette.backgroundCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AegiroPalette.borderSubtle, lineWidth: 1)
        )
    }

    private var usbEncryptionDebugLogCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                formLabel("Live Debug Info")
                Spacer()
                Button("Copy Logs") {
                    copyUSBDataEncryptionLogsToClipboard()
                }
                .buttonStyle(.bordered)
                .disabled(model.usbDataEncryptionLogs.isEmpty)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if model.usbDataEncryptionLogs.isEmpty {
                            Text("Waiting for logs...")
                                .font(AegiroTypography.body(11, weight: .regular))
                                .foregroundStyle(AegiroPalette.textMuted)
                        } else {
                            ForEach(model.usbDataEncryptionLogs) { entry in
                                Text(formattedUSBDataEncryptionLogLine(for: entry))
                                    .font(AegiroTypography.mono(11, weight: .regular))
                                    .foregroundStyle(AegiroPalette.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(entry.id)
                            }
                        }
                    }
                    .padding(8)
                    .textSelection(.enabled)
                }
                .frame(minHeight: 180, maxHeight: 280)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AegiroPalette.backgroundMain.opacity(0.72))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AegiroPalette.borderSubtle.opacity(0.8), lineWidth: 1)
                )
                .onAppear {
                    scrollToLatestUSBDataLog(using: proxy, animated: false)
                }
                .onChange(of: model.usbDataEncryptionLogs.count) { _ in
                    scrollToLatestUSBDataLog(using: proxy, animated: true)
                }
            }
        }
    }

    private func progressCard(title: String, message: String, fraction: Double?, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            formLabel(title)
            if let fraction {
                ProgressView(value: max(0, min(1, fraction)))
                    .tint(AegiroPalette.securityGreen)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            if let detail {
                Text(detail)
                    .font(AegiroTypography.body(11, weight: .semibold))
                    .foregroundStyle(AegiroPalette.textPrimary)
            }
            Text(message)
                .font(AegiroTypography.body(11, weight: .regular))
                .foregroundStyle(AegiroPalette.textSecondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AegiroPalette.backgroundMain.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AegiroPalette.borderSubtle.opacity(0.8), lineWidth: 1)
        )
    }

    private func formLabel(_ text: String) -> some View {
        Text(text)
            .font(AegiroTypography.body(12, weight: .semibold))
            .foregroundStyle(AegiroPalette.textSecondary)
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(AegiroTypography.body(10, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    private func optionIsAvailable(_ option: EncryptionOption) -> Bool {
        switch option {
        case .apfsDisk:
            return selectedAPFSVolume != nil
        case .vaultFile:
            return selectedMountPoint != nil
        case .usbContainer:
            return true
        }
    }

    private func unavailableHint(for option: EncryptionOption) -> String? {
        switch option {
        case .apfsDisk:
            if selectedNonAPFSVolume != nil {
                return "Requires APFS. Choose an APFS USB volume for this flow."
            }
            return "Select an APFS USB volume."
        case .vaultFile:
            if let selectedAPFSVolume, selectedAPFSVolume.mountPoint == nil {
                return "Mount the selected APFS volume first."
            }
            return "Select a mounted USB volume."
        case .usbContainer:
            return nil
        }
    }

    private func ensureSelectedOptionIsValid() {
        if let selectedOption, !optionIsAvailable(selectedOption) {
            self.selectedOption = nil
        }
        if selectedOption == nil, let recommendedOption, optionIsAvailable(recommendedOption) {
            selectedOption = recommendedOption
        }
        if selectedOption == nil {
            stage = .selectOption
        }
    }

    private func applyAutoSelectionIfNeeded(force: Bool) {
        let trimmed = selectedTrimmed
        guard !trimmed.isEmpty else { return }
        let isKnown = externalAPFSOptions.contains(where: { $0.identifier == trimmed })
            || model.mountedNonAPFSVolumes.contains(where: { $0.mountPoint == trimmed })
        if force || !isKnown {
            selectedVolume = ""
        }
    }

    private func syncDefaultsForSelection(force: Bool) {
        if let apfs = selectedAPFSVolume {
            syncRecoveryPathWithDisk(apfs.identifier, force: force)
            if let mount = apfs.mountPoint {
                syncSuggestedVaultPaths(for: mount, force: force)
            }
            return
        }
        if let nonAPFS = selectedNonAPFSVolume {
            syncSuggestedVaultPaths(for: nonAPFS.mountPoint, force: force)
        }
    }

    private func runSelectedOption() {
        guard let selectedOption else {
            model.status = "Select an encryption option first."
            return
        }
        switch selectedOption {
        case .apfsDisk:
            runAPFSAction()
        case .vaultFile:
            runVaultFileEncryption()
        case .usbContainer:
            onOpenUSBContainer()
        }
    }

    private func openSelectedOptionConfiguration() {
        guard let selectedOption else {
            model.status = "Select an encryption option first."
            return
        }
        guard optionIsAvailable(selectedOption) else {
            model.status = unavailableHint(for: selectedOption) ?? "Selected option is not available for this volume."
            return
        }
        syncDefaultsForSelection(force: true)
        vaultPackSuccessState = nil
        stage = .configureOption
    }

    private func runAPFSAction() {
        guard let apfs = selectedAPFSVolume else {
            model.status = "Select an APFS USB volume"
            return
        }
        let pass = recoveryPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = recoveryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pass.isEmpty else {
            model.status = "Enter a recovery passphrase"
            return
        }
        guard !path.isEmpty else {
            model.status = "Choose a recovery bundle file path"
            return
        }

        let recoveryURL = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        switch apfsAction {
        case .encrypt:
            model.encryptExternalDisk(
                diskIdentifier: apfs.identifier,
                recoveryPassphrase: pass,
                recoveryURL: recoveryURL,
                dryRun: apfsDryRun,
                overwrite: apfsOverwrite
            )
        case .decrypt:
            model.unlockExternalDisk(
                diskIdentifier: apfs.identifier,
                recoveryPassphrase: pass,
                recoveryURL: recoveryURL,
                dryRun: apfsDryRun
            )
        }
    }

    private func runVaultFileEncryption() {
        guard let mount = selectedMountPoint?.trimmingCharacters(in: .whitespacesAndNewlines), !mount.isEmpty else {
            model.status = "Select a mounted USB volume"
            return
        }

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
        if !vaultFileDryRun {
            guard vaultPassphraseStrength.isRequired else {
                model.status = "Passphrase is too weak. Use 8+ chars with uppercase, lowercase, and a number."
                return
            }
            guard vaultPassphrase == confirmVaultPassphrase else {
                model.status = "Passphrases do not match"
                return
            }
        }

        let requestedExcluded = Set(vaultPackExcludedPaths.map {
            URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        })
        let appliedExcluded = resolvedVaultPackExcludedPaths(for: source)
        let ignoredExcludedCount = max(0, requestedExcluded.count - Set(appliedExcluded).count)
        if ignoredExcludedCount > 0 {
            model.status = "Ignoring \(ignoredExcludedCount) exclusion path(s) outside the selected source folder."
        }

        let sourcePathForResult = source.path
        let unlockPassphraseForResult = vaultPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        stage = .progress
        vaultPackSuccessState = nil
        model.encryptNonAPFSUSBUserData(sourceRootURL: source,
                                        vaultURL: vault,
                                        vaultPassphrase: vaultPassphrase,
                                        deleteOriginals: deleteOriginals && !vaultFileDryRun,
                                        dryRun: vaultFileDryRun,
                                        targetMountPoint: mount,
                                        excludedSourcePaths: appliedExcluded) { success in
            guard success else { return }
            guard !vaultFileDryRun else { return }
            guard let result = model.usbDataEncryptionLastResult, !result.dryRun else { return }
            let elapsedDuration = vaultFileElapsedDuration(at: Date())
            vaultPackSuccessState = VaultPackSuccessState(result: result,
                                                          sourceRootPath: sourcePathForResult,
                                                          mountPoint: mount,
                                                          unlockPassphrase: unlockPassphraseForResult,
                                                          completedAt: Date(),
                                                          elapsedDuration: elapsedDuration)
            stage = .success
        }
    }

    private func chooseRecoveryPath() {
        let panel = NSSavePanel()
        panel.title = "Save PQC Recovery Bundle"
        panel.nameFieldStringValue = (defaultRecoveryPath(for: selectedTrimmed) as NSString).lastPathComponent
        panel.allowedContentTypes = [UTType.json]
        if panel.runModal() == .OK, let url = panel.url {
            recoveryPath = url.path
        }
    }

    private func chooseSourceFolder() {
        guard let mount = selectedMountPoint else {
            model.status = "Select a mounted USB volume first"
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose Source Folder to Encrypt"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        if !sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            panel.directoryURL = URL(fileURLWithPath: NSString(string: sourcePath).expandingTildeInPath, isDirectory: true)
        } else {
            panel.directoryURL = URL(fileURLWithPath: mount, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            sourcePath = url.path
        }
    }

    private func chooseVaultPath() {
        guard let mount = selectedMountPoint else {
            model.status = "Select a mounted USB volume first"
            return
        }
        let panel = NSSavePanel()
        panel.title = "Choose Vault File"
        panel.nameFieldStringValue = (defaultVaultPath(for: mount) as NSString).lastPathComponent
        panel.allowedContentTypes = [UTType(filenameExtension: "agvt") ?? .data]
        panel.directoryURL = URL(fileURLWithPath: mount, isDirectory: true)
        if panel.runModal() == .OK, var url = panel.url {
            if url.pathExtension.lowercased() != "agvt" {
                url.appendPathExtension("agvt")
            }
            vaultPath = url.path
        }
    }

    private func chooseVaultPackExcludedPaths() {
        guard let mount = selectedMountPoint else {
            model.status = "Select a mounted USB volume first"
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose Files or Folders to Exclude"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        let preferredRoot = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? mount : sourcePath
        panel.directoryURL = URL(fileURLWithPath: NSString(string: preferredRoot).expandingTildeInPath, isDirectory: true)
        if panel.runModal() == .OK {
            let normalized = panel.urls.map {
                $0.standardizedFileURL.resolvingSymlinksInPath().path
            }
            vaultPackExcludedPaths = Array(Set(vaultPackExcludedPaths + normalized)).sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
        }
    }

    private func syncDefaultHiddenExclusionsForSource() {
        let trimmedSource = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else { return }
        let sourceRoot = URL(fileURLWithPath: NSString(string: trimmedSource).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let preserved = resolvedVaultPackExcludedPaths(for: sourceRoot)
        let defaults = defaultHiddenExclusionPaths(for: sourceRoot)
        vaultPackExcludedPaths = Array(Set(preserved + defaults)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private func defaultHiddenExclusionPaths(for sourceRoot: URL) -> [String] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceRoot.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        let urls = (try? FileManager.default.contentsOfDirectory(at: sourceRoot,
                                                                 includingPropertiesForKeys: [.isHiddenKey],
                                                                 options: [])) ?? []
        var hiddenPaths = Set<String>()
        for url in urls {
            let name = url.lastPathComponent
            if name.hasPrefix(".") {
                hiddenPaths.insert(url.standardizedFileURL.resolvingSymlinksInPath().path)
                continue
            }
            let isHidden = (try? url.resourceValues(forKeys: [.isHiddenKey]).isHidden) ?? false
            if isHidden == true {
                hiddenPaths.insert(url.standardizedFileURL.resolvingSymlinksInPath().path)
            }
        }
        return hiddenPaths.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func resolvedVaultPackExcludedPaths(for sourceRoot: URL) -> [String] {
        let rootPath = sourceRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var kept = Set<String>()
        for path in vaultPackExcludedPaths {
            let normalized = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            if normalized == rootPath || normalized.hasPrefix(rootPrefix) {
                kept.insert(normalized)
            }
        }
        return kept.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func scrollToLatestUSBDataLog(using proxy: ScrollViewProxy, animated: Bool) {
        guard let id = model.usbDataEncryptionLogs.last?.id else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(id, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }

    private func formattedUSBDataEncryptionLogLine(for entry: USBDataEncryptionLogEntry) -> String {
        "[\(entry.timestamp.formatted(date: .omitted, time: .standard))] \(entry.message)"
    }

    private func copyUSBDataEncryptionLogsToClipboard() {
        let text = model.usbDataEncryptionLogs
            .map(formattedUSBDataEncryptionLogLine(for:))
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        copyToClipboard(text)
        model.status = "Copied USB encryption debug logs."
    }

    private func copyToClipboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func revealCreatedVaultInFinder() {
        guard let success = vaultPackSuccessState else { return }
        NSWorkspace.shared.activateFileViewerSelecting([success.result.vaultURL])
    }

    private func openCreatedVaultFromSuccess() {
        guard let success = vaultPackSuccessState else { return }
        let normalizedVaultURL = success.result.vaultURL.standardizedFileURL
        let targetVaultPath = normalizedVaultURL.path
        let trimmedPassphrase = success.unlockPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentVaultPath = model.vaultURL?.standardizedFileURL.path
        let alreadyOpenAndUnlocked = currentVaultPath == targetVaultPath
            && !model.locked
            && (trimmedPassphrase.isEmpty || model.passphrase == trimmedPassphrase)
        if !alreadyOpenAndUnlocked {
            model.openVault(at: normalizedVaultURL)
            if !trimmedPassphrase.isEmpty {
                model.unlock(with: trimmedPassphrase)
            } else {
                model.status = "Vault loaded. Enter passphrase to unlock."
            }
        }
        onBackToVault()
    }

    private func defaultRecoveryPath(for diskID: String) -> String {
        let trimmed = diskID.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = trimmed.isEmpty ? "external-disk" : trimmed.replacingOccurrences(of: "/", with: "_")
        let baseDir = defaultVaultDirectoryURL()
        return baseDir.appendingPathComponent("\(safe).aegiro-diskkey.json").path
    }

    private func normalizedMountPath(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "" }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
    }

    private func syncRecoveryPathWithDisk(_ diskID: String, force: Bool) {
        let suggested = defaultRecoveryPath(for: diskID)
        let trimmedCurrent = recoveryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if force || trimmedCurrent.isEmpty || recoveryPath == lastSuggestedRecoveryPath {
            recoveryPath = suggested
        }
        lastSuggestedRecoveryPath = suggested
    }

    private func syncSuggestedVaultPaths(for mountPoint: String, force: Bool) {
        let mount = mountPoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mount.isEmpty else { return }

        if force || sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sourcePath == lastSuggestedSourcePath {
            sourcePath = mount
        }
        lastSuggestedSourcePath = mount

        let suggestedVault = defaultVaultPath(for: mount)
        if force || vaultPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vaultPath == lastSuggestedVaultPath {
            vaultPath = suggestedVault
        }
        lastSuggestedVaultPath = suggestedVault
        syncDefaultHiddenExclusionsForSource()
    }

    private func defaultVaultPath(for mountPoint: String) -> String {
        URL(fileURLWithPath: mountPoint, isDirectory: true)
            .appendingPathComponent("data.agvt")
            .path
    }
}

struct CreateVaultSheet: View {
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) private var dismiss

    @State private var vaultName = "MyVault"
    @State private var parentPath: String = defaultVaultURL().deletingLastPathComponent().path
    @State private var passphrase = ""
    @State private var confirmPassphrase = ""

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
                .font(AegiroTypography.display(24, weight: .semibold))
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

            if passphrase != confirmPassphrase && !confirmPassphrase.isEmpty {
                Text("Passphrases do not match.")
                    .font(AegiroTypography.body(12, weight: .regular))
                    .foregroundStyle(AegiroPalette.dangerRed)
            }

            if !passphrase.isEmpty && !passphraseStrength.isRequired {
                Text("Passphrase must be 8+ chars and include uppercase, lowercase, and a number.")
                    .font(AegiroTypography.body(12, weight: .regular))
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
            .font(AegiroTypography.body(12, weight: .semibold))
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
            passphrase: passphrase
        )
        if model.vaultURL != nil {
            onDone()
            dismiss()
        }
    }
}

struct DiskEncryptSheet: View {
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

    private var shouldShowProgressOnlyView: Bool {
        isEncryptingSelectedDisk || isEncryptingSelectedUSBUserData
    }

    @ViewBuilder
    private var progressOnlyContent: some View {
        switch selectionKind {
        case .apfs:
            encryptionProgressCard
        case .nonAPFS:
            usbDataEncryptionProgressCard
        case .none, .invalid:
            ProgressView()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if shouldShowProgressOnlyView {
                progressOnlyContent
            } else {
                Text("Encrypt External Disk")
                    .font(AegiroTypography.display(24, weight: .semibold))
                    .foregroundStyle(AegiroPalette.textPrimary)

                Text("Use one flow for APFS disk encryption and non-APFS USB user-data encryption.")
                    .font(AegiroTypography.body(13, weight: .regular))
                    .foregroundStyle(AegiroPalette.textSecondary)

                if formPhase == .selectVolume {
                    selectionPhaseContent
                } else {
                    detailsPhaseContent
                }
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
                .font(AegiroTypography.body(10, weight: .regular))
                .foregroundStyle(AegiroPalette.textMuted)

            switch selectionKind {
            case .apfs:
                Text("APFS volume selected. Continue to configure recovery bundle + encryption options.")
                    .font(AegiroTypography.body(11, weight: .regular))
                    .foregroundStyle(AegiroPalette.textSecondary)
            case .nonAPFS:
                Text("Non-APFS volume selected. Continue to configure source/vault/passphrase options.")
                    .font(AegiroTypography.body(11, weight: .regular))
                    .foregroundStyle(AegiroPalette.textSecondary)
            case .none:
                Text("Select an external volume to continue.")
                    .font(AegiroTypography.body(11, weight: .regular))
                    .foregroundStyle(AegiroPalette.textMuted)
            case .invalid:
                Text("The selected value is not a valid external APFS volume identifier or mounted non-APFS external volume.")
                    .font(AegiroTypography.body(11, weight: .regular))
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
                        .font(AegiroTypography.body(12, weight: .medium))
                        .foregroundStyle(AegiroPalette.textPrimary)
                case .nonAPFS:
                    let fs = selectedNonAPFSVolume?.filesystemType.uppercased() ?? "NON-APFS"
                    Text("\(selectedDiskTrimmed) • \(fs)")
                        .font(AegiroTypography.body(12, weight: .medium))
                        .foregroundStyle(AegiroPalette.textPrimary)
                case .none, .invalid:
                    Text("No valid external volume selected.")
                        .font(AegiroTypography.body(12, weight: .regular))
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

                Text("APFS reports block/volume encryption progress only. Per-file counts are not available from diskutil.")
                    .font(AegiroTypography.body(10, weight: .regular))
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
                    .font(AegiroTypography.body(10, weight: .regular))
                    .foregroundStyle(AegiroPalette.textMuted)

                if !dryRun && vaultPassphrase != confirmVaultPassphrase && !confirmVaultPassphrase.isEmpty {
                    Text("Passphrases do not match.")
                        .font(AegiroTypography.body(12, weight: .regular))
                        .foregroundStyle(AegiroPalette.dangerRed)
                }

                if !dryRun && !vaultPassphrase.isEmpty && !usbPassphraseStrength.isRequired {
                    Text("Passphrase must be 8+ chars and include uppercase, lowercase, and a number.")
                        .font(AegiroTypography.body(12, weight: .regular))
                        .foregroundStyle(AegiroPalette.warningAmber)
                }

            case .none, .invalid:
                Text("Selection is no longer valid. Go back and select an external volume again.")
                    .font(AegiroTypography.body(12, weight: .regular))
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
                .font(AegiroTypography.body(11, weight: .regular))
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
                    .font(AegiroTypography.body(11, weight: .semibold))
                    .foregroundStyle(AegiroPalette.textPrimary)
            } else {
                Text("Preparing file list...")
                    .font(AegiroTypography.body(11, weight: .regular))
                    .foregroundStyle(AegiroPalette.textSecondary)
            }
            Text(model.usbDataEncryptionProgressMessage)
                .font(AegiroTypography.body(11, weight: .regular))
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
            .font(AegiroTypography.body(12, weight: .semibold))
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
        let baseDir = defaultVaultDirectoryURL()
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

struct DiskUnlockSheet: View {
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
                .font(AegiroTypography.display(24, weight: .semibold))
                .foregroundStyle(AegiroPalette.textPrimary)

            Text("Use a PQC recovery bundle + passphrase to decrypt (unlock) APFS external volumes.")
                .font(AegiroTypography.body(13, weight: .regular))
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
            .font(AegiroTypography.body(12, weight: .semibold))
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

struct USBUserDataEncryptSheet: View {
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
            if isEncryptingSelectedMount {
                usbProgressCard
            } else {
                Text("Encrypt USB User Data")
                    .font(AegiroTypography.display(24, weight: .semibold))
                    .foregroundStyle(AegiroPalette.textPrimary)

                Text("For non-APFS USB drives: encrypt user files into an Aegiro vault file without changing the USB format.")
                    .font(AegiroTypography.body(13, weight: .regular))
                    .foregroundStyle(AegiroPalette.textSecondary)

                formLabel("Mounted Non-APFS Volume")
                if volumes.isEmpty {
                    Text("No mounted non-APFS USB volumes found.")
                        .font(AegiroTypography.body(12, weight: .regular))
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
                    .font(AegiroTypography.body(10, weight: .regular))
                    .foregroundStyle(AegiroPalette.textMuted)

                if !dryRun && passphrase != confirmPassphrase && !confirmPassphrase.isEmpty {
                    Text("Passphrases do not match.")
                        .font(AegiroTypography.body(12, weight: .regular))
                        .foregroundStyle(AegiroPalette.dangerRed)
                }

                if !dryRun && !passphrase.isEmpty && !passphraseStrength.isRequired {
                    Text("Passphrase must be 8+ chars and include uppercase, lowercase, and a number.")
                        .font(AegiroTypography.body(12, weight: .regular))
                        .foregroundStyle(AegiroPalette.warningAmber)
                }

                HStack {
                    Spacer()
                    Button("Cancel") {
                        dismiss()
                    }

                    Button(dryRun ? "Scan User Data" : "Encrypt User Data") {
                        startEncrypt()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AegiroPalette.accentIndigo)
                    .disabled(!canSubmit)
                }
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
            .font(AegiroTypography.body(12, weight: .semibold))
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
                    .font(AegiroTypography.body(11, weight: .semibold))
                    .foregroundStyle(AegiroPalette.textPrimary)
            } else {
                Text("Preparing file list...")
                    .font(AegiroTypography.body(11, weight: .regular))
                    .foregroundStyle(AegiroPalette.textSecondary)
            }
            Text(model.usbDataEncryptionProgressMessage)
                .font(AegiroTypography.body(11, weight: .regular))
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

struct USBContainerSheet: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case create
        case mount
        case unmount

        var id: String { rawValue }

        var title: String {
            switch self {
            case .create:
                return "Create"
            case .mount:
                return "Mount"
            case .unmount:
                return "Unmount"
            }
        }
    }

    @EnvironmentObject private var model: VaultModel
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .create
    @State private var isRunning = false
    @State private var output: String = ""

    @State private var createImagePath = ""
    @State private var createSize = "16g"
    @State private var createVolumeName = "Aegiro USB"
    @State private var createRecoveryPassphrase = ""
    @State private var createRecoveryPath = ""
    @State private var createContainerPassphrase = ""
    @State private var createDryRun = false
    @State private var createForce = false

    @State private var mountImagePath = ""
    @State private var mountRecoveryPassphrase = ""
    @State private var mountRecoveryPath = ""
    @State private var mountContainerPassphrase = ""
    @State private var mountDryRun = false

    @State private var unmountTarget = ""
    @State private var unmountForce = false
    @State private var unmountDryRun = false

    var onDone: () -> Void

    private var canRun: Bool {
        switch mode {
        case .create:
            return !createImagePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !createSize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !createVolumeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !createRecoveryPassphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !createRecoveryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .mount:
            let hasPass = !mountRecoveryPassphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !mountContainerPassphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return !mountImagePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !mountRecoveryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && hasPass
        case .unmount:
            return !unmountTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var submitTitle: String {
        switch mode {
        case .create:
            return createDryRun ? "Validate Create" : "Create Container"
        case .mount:
            return mountDryRun ? "Validate Mount" : "Mount Container"
        case .unmount:
            return unmountDryRun ? "Validate Unmount" : "Unmount Container"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("USB Container")
                .font(AegiroTypography.display(24, weight: .semibold))
                .foregroundStyle(AegiroPalette.textPrimary)

            Text("Use the same app flow as usb-container-create, usb-container-open, and usb-container-close.")
                .font(AegiroTypography.body(13, weight: .regular))
                .foregroundStyle(AegiroPalette.textSecondary)

            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            .pickerStyle(.segmented)

            switch mode {
            case .create:
                createForm
            case .mount:
                mountForm
            case .unmount:
                unmountForm
            }

            if isRunning {
                ProgressView()
                    .controlSize(.small)
            }

            outputCard

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button(submitTitle) {
                    run()
                }
                .buttonStyle(.borderedProminent)
                .tint(AegiroPalette.accentIndigo)
                .disabled(!canRun || isRunning)
            }
        }
        .padding(24)
        .frame(width: 760)
        .background(AegiroPalette.backgroundPanel)
        .onAppear {
            bootstrapDefaults()
        }
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            formLabel("Container Image (.sparsebundle)")
            HStack(spacing: 8) {
                TextField("/Volumes/MyUSB/aegiro-portable.sparsebundle", text: $createImagePath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose...") { chooseCreateImagePath() }
                    .buttonStyle(.bordered)
            }

            formLabel("Container Size")
            TextField("16g", text: $createSize)
                .textFieldStyle(.roundedBorder)

            formLabel("Volume Name")
            TextField("Aegiro USB", text: $createVolumeName)
                .textFieldStyle(.roundedBorder)

            formLabel("Recovery Passphrase")
            SecureField("Required", text: $createRecoveryPassphrase)
                .textFieldStyle(.roundedBorder)

            formLabel("Recovery Bundle File")
            HStack(spacing: 8) {
                TextField("/Volumes/MyUSB/aegiro-portable.aegiro-usbkey.json", text: $createRecoveryPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose...") { chooseCreateRecoveryPath() }
                    .buttonStyle(.bordered)
            }

            formLabel("Container Passphrase (Optional)")
            SecureField("Leave empty to auto-generate", text: $createContainerPassphrase)
                .textFieldStyle(.roundedBorder)

            Toggle("Dry run only", isOn: $createDryRun)
            Toggle("Overwrite existing image/recovery files", isOn: $createForce)
        }
        .onChange(of: createImagePath) { newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if createRecoveryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                createRecoveryPath = defaultUSBContainerRecoveryPath(forImagePath: trimmed)
            }
        }
    }

    private var mountForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            formLabel("Container Image (.sparsebundle)")
            HStack(spacing: 8) {
                TextField("/Volumes/MyUSB/aegiro-portable.sparsebundle", text: $mountImagePath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose...") { chooseMountImagePath() }
                    .buttonStyle(.bordered)
            }

            formLabel("Recovery Bundle File")
            HStack(spacing: 8) {
                TextField("/Volumes/MyUSB/aegiro-portable.aegiro-usbkey.json", text: $mountRecoveryPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose...") { chooseMountRecoveryPath() }
                    .buttonStyle(.bordered)
            }

            formLabel("Recovery Passphrase")
            SecureField("Required unless using direct container passphrase", text: $mountRecoveryPassphrase)
                .textFieldStyle(.roundedBorder)

            formLabel("Container Passphrase Override (Optional)")
            SecureField("Optional direct passphrase", text: $mountContainerPassphrase)
                .textFieldStyle(.roundedBorder)

            Toggle("Dry run only", isOn: $mountDryRun)
        }
        .onChange(of: mountImagePath) { newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if mountRecoveryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                mountRecoveryPath = defaultUSBContainerRecoveryPath(forImagePath: trimmed)
            }
        }
    }

    private var unmountForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            formLabel("Unmount Target")
            TextField("/Volumes/AegiroUSB or disk9", text: $unmountTarget)
                .textFieldStyle(.roundedBorder)

            Toggle("Force unmount", isOn: $unmountForce)
            Toggle("Dry run only", isOn: $unmountDryRun)
        }
    }

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            formLabel("Output")
            ScrollView {
                Text(output.isEmpty ? "No output yet." : output)
                    .font(AegiroTypography.mono(11, weight: .regular))
                    .foregroundStyle(output.isEmpty ? AegiroPalette.textMuted : AegiroPalette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(minHeight: 110, maxHeight: 170)
            .background(AegiroPalette.backgroundMain, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AegiroPalette.borderSubtle, lineWidth: 1)
            )
        }
    }

    private func formLabel(_ text: String) -> some View {
        Text(text)
            .font(AegiroTypography.body(12, weight: .semibold))
            .foregroundStyle(AegiroPalette.textSecondary)
    }

    private func bootstrapDefaults() {
        if createImagePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let mount = model.mountedNonAPFSVolumes.first?.mountPoint {
            createImagePath = URL(fileURLWithPath: mount, isDirectory: true)
                .appendingPathComponent("aegiro-portable.sparsebundle")
                .path
            createRecoveryPath = defaultUSBContainerRecoveryPath(forImagePath: createImagePath)
        }

        if mountImagePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mountImagePath = createImagePath
            if !mountImagePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                mountRecoveryPath = defaultUSBContainerRecoveryPath(forImagePath: mountImagePath)
            }
        }
    }

    private func chooseCreateImagePath() {
        let panel = NSSavePanel()
        panel.title = "Choose Container Image Path"
        panel.nameFieldStringValue = (createImagePath.isEmpty ? "aegiro-portable.sparsebundle" : createImagePath as NSString).lastPathComponent
        panel.allowedContentTypes = [UTType(filenameExtension: "sparsebundle") ?? .data]
        if panel.runModal() == .OK, var url = panel.url {
            if url.pathExtension.lowercased() != "sparsebundle" {
                url.appendPathExtension("sparsebundle")
            }
            createImagePath = url.path
            createRecoveryPath = defaultUSBContainerRecoveryPath(forImagePath: url.path)
        }
    }

    private func chooseCreateRecoveryPath() {
        let panel = NSSavePanel()
        panel.title = "Choose Recovery Bundle Path"
        panel.nameFieldStringValue = (createRecoveryPath.isEmpty ? "aegiro-portable.aegiro-usbkey.json" : createRecoveryPath as NSString).lastPathComponent
        panel.allowedContentTypes = [UTType.json]
        if panel.runModal() == .OK, var url = panel.url {
            if url.pathExtension.lowercased() != "json" {
                url.appendPathExtension("json")
            }
            createRecoveryPath = url.path
        }
    }

    private func chooseMountImagePath() {
        let panel = NSOpenPanel()
        panel.title = "Choose Container Image"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            mountImagePath = url.path
            if mountRecoveryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                mountRecoveryPath = defaultUSBContainerRecoveryPath(forImagePath: url.path)
            }
        }
    }

    private func chooseMountRecoveryPath() {
        let panel = NSOpenPanel()
        panel.title = "Choose Recovery Bundle"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType.json]
        if panel.runModal() == .OK, let url = panel.url {
            mountRecoveryPath = url.path
        }
    }

    private func defaultUSBContainerRecoveryPath(forImagePath path: String) -> String {
        let imageURL = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        let base = imageURL.deletingPathExtension().lastPathComponent
        return imageURL.deletingLastPathComponent()
            .appendingPathComponent("\(base).aegiro-usbkey.json")
            .path
    }

    private func run() {
        output = ""
        isRunning = true
        switch mode {
        case .create:
            let imageURL = URL(fileURLWithPath: NSString(string: createImagePath).expandingTildeInPath)
            let recoveryURL = URL(fileURLWithPath: NSString(string: createRecoveryPath).expandingTildeInPath)
            let optionalContainerPass = createContainerPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
            model.createUSBContainer(
                imageURL: imageURL,
                size: createSize,
                volumeName: createVolumeName,
                recoveryPassphrase: createRecoveryPassphrase,
                recoveryURL: recoveryURL,
                overwrite: createForce,
                containerPassphrase: optionalContainerPass.isEmpty ? nil : optionalContainerPass,
                dryRun: createDryRun
            ) { result in
                isRunning = false
                switch result {
                case .success(let value):
                    output = value.dryRun
                        ? "Dry run complete.\nRecovery bundle: \(value.recoveryURL.path)"
                        : "Created container image: \(value.imageURL.path)\nRecovery bundle: \(value.recoveryURL.path)"
                    onDone()
                case .failure(let error):
                    output = "Error: \(formattedUserError(error))"
                }
            }
        case .mount:
            let imageURL = URL(fileURLWithPath: NSString(string: mountImagePath).expandingTildeInPath)
            let recoveryURL = URL(fileURLWithPath: NSString(string: mountRecoveryPath).expandingTildeInPath)
            let optionalOverride = mountContainerPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
            model.mountUSBContainer(
                imageURL: imageURL,
                recoveryPassphrase: mountRecoveryPassphrase,
                recoveryURL: recoveryURL,
                containerPassphraseOverride: optionalOverride.isEmpty ? nil : optionalOverride,
                dryRun: mountDryRun
            ) { result in
                isRunning = false
                switch result {
                case .success(let value):
                    if value.dryRun {
                        output = "Dry run complete: mount request validated."
                    } else {
                        var lines: [String] = []
                        if let mountPoint = value.mountPoint {
                            lines.append("Mounted at: \(mountPoint)")
                        } else {
                            lines.append("Mounted image (mount point unavailable).")
                        }
                        if let device = value.deviceIdentifier {
                            lines.append("Device: \(device)")
                        }
                        output = lines.joined(separator: "\n")
                    }
                    onDone()
                case .failure(let error):
                    output = "Error: \(formattedUserError(error))"
                }
            }
        case .unmount:
            model.unmountUSBContainer(target: unmountTarget, force: unmountForce, dryRun: unmountDryRun) { result in
                isRunning = false
                switch result {
                case .success:
                    output = unmountDryRun
                        ? "Dry run complete: unmount target validated."
                        : "Unmounted \(unmountTarget)."
                    onDone()
                case .failure(let error):
                    output = "Error: \(formattedUserError(error))"
                }
            }
        }
    }
}

struct BackupSheet: View {
    @EnvironmentObject private var model: VaultModel
    @Environment(\.dismiss) private var dismiss

    @State private var vaultPath = ""
    @State private var outPath = ""
    @State private var passphrase = ""
    @State private var isRunning = false
    @State private var output = ""

    var onDone: () -> Void

    private var canRun: Bool {
        !vaultPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !outPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isRunning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Backup Vault")
                .font(AegiroTypography.display(24, weight: .semibold))
                .foregroundStyle(AegiroPalette.textPrimary)

            Text("CLI parity for backup --vault <path> --out <path.aegirobackup> [--passphrase ...]. Optional passphrase validates vault unlock before backup.")
                .font(AegiroTypography.body(13, weight: .regular))
                .foregroundStyle(AegiroPalette.textSecondary)

            formLabel("Vault File")
            HStack(spacing: 8) {
                TextField("/path/to/vault.agvt", text: $vaultPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose...") { chooseVaultPath() }
                    .buttonStyle(.bordered)
            }

            formLabel("Backup Output Path")
            HStack(spacing: 8) {
                TextField("/path/to/vault.aegirobackup", text: $outPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose...") { chooseOutputPath() }
                    .buttonStyle(.bordered)
            }

            formLabel("Vault Passphrase for Validation (Optional)")
            SecureField("Optional: validates vault unlock (does not re-encrypt backup)", text: $passphrase)
                .textFieldStyle(.roundedBorder)

            if isRunning {
                ProgressView()
                    .controlSize(.small)
            }

            outputCard(output)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Run Backup") { runBackup() }
                    .buttonStyle(.borderedProminent)
                    .tint(AegiroPalette.accentIndigo)
                    .disabled(!canRun)
            }
        }
        .padding(24)
        .frame(width: 700)
        .background(AegiroPalette.backgroundPanel)
        .onAppear {
            if vaultPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                vaultPath = model.vaultURL?.path ?? ""
            }
            if outPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !vaultPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                outPath = defaultBackupPath(for: vaultPath)
            }
            if passphrase.isEmpty {
                passphrase = model.passphrase
            }
        }
    }

    private func formLabel(_ text: String) -> some View {
        Text(text)
            .font(AegiroTypography.body(12, weight: .semibold))
            .foregroundStyle(AegiroPalette.textSecondary)
    }

    private func outputCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            formLabel("Output")
            ScrollView {
                Text(text.isEmpty ? "No output yet." : text)
                    .font(AegiroTypography.mono(11, weight: .regular))
                    .foregroundStyle(text.isEmpty ? AegiroPalette.textMuted : AegiroPalette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(minHeight: 95, maxHeight: 150)
            .background(AegiroPalette.backgroundMain, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AegiroPalette.borderSubtle, lineWidth: 1)
            )
        }
    }

    private func chooseVaultPath() {
        let panel = NSOpenPanel()
        panel.title = "Choose Vault"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "agvt") ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            vaultPath = url.path
            if outPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                outPath = defaultBackupPath(for: url.path)
            }
        }
    }

    private func chooseOutputPath() {
        let panel = NSSavePanel()
        panel.title = "Choose Backup Output"
        panel.nameFieldStringValue = (outPath.isEmpty ? "vault.aegirobackup" : outPath as NSString).lastPathComponent
        panel.allowedContentTypes = [UTType(filenameExtension: "aegirobackup") ?? .data]
        if panel.runModal() == .OK, var url = panel.url {
            if url.pathExtension.lowercased() != "aegirobackup" {
                url.appendPathExtension("aegirobackup")
            }
            outPath = url.path
        }
    }

    private func defaultBackupPath(for vaultPath: String) -> String {
        let vaultURL = URL(fileURLWithPath: NSString(string: vaultPath).expandingTildeInPath)
        let baseName = vaultURL.deletingPathExtension().lastPathComponent
        return vaultURL.deletingLastPathComponent()
            .appendingPathComponent("\(baseName).aegirobackup")
            .path
    }

    private func runBackup() {
        output = ""
        isRunning = true

        let vaultURL = URL(fileURLWithPath: NSString(string: vaultPath).expandingTildeInPath)
        let outURL = URL(fileURLWithPath: NSString(string: outPath).expandingTildeInPath)
        model.exportBackup(vaultURL: vaultURL, outURL: outURL, passphrase: passphrase) { result in
            isRunning = false
            switch result {
            case .success:
                output = "Backup archive created at \(outURL.path)."
                onDone()
            case .failure(let error):
                output = "Error: \(formattedUserError(error))"
            }
        }
    }
}

struct RestoreSheet: View {
    @EnvironmentObject private var model: VaultModel
    @Environment(\.dismiss) private var dismiss

    @State private var backupPath = ""
    @State private var outPath = ""
    @State private var overwriteExisting = false
    @State private var isRunning = false
    @State private var output = ""

    var onDone: () -> Void

    private var canRun: Bool {
        !backupPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !outPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isRunning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Restore Vault")
                .font(AegiroTypography.display(24, weight: .semibold))
                .foregroundStyle(AegiroPalette.textPrimary)

            Text("Restore a vault file from backup archive (CLI parity for restore --backup <path.aegirobackup> --out <path.agvt> [--force]).")
                .font(AegiroTypography.body(13, weight: .regular))
                .foregroundStyle(AegiroPalette.textSecondary)

            formLabel("Backup Archive")
            HStack(spacing: 8) {
                TextField("/path/to/vault.aegirobackup", text: $backupPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose...") { chooseBackupPath() }
                    .buttonStyle(.bordered)
            }

            formLabel("Restore Output Path")
            HStack(spacing: 8) {
                TextField("/path/to/restored.agvt", text: $outPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose...") { chooseOutputPath() }
                    .buttonStyle(.bordered)
            }

            Toggle("Overwrite existing output", isOn: $overwriteExisting)
                .font(AegiroTypography.body(12, weight: .regular))
                .foregroundStyle(AegiroPalette.textSecondary)
                .toggleStyle(.checkbox)

            if isRunning {
                ProgressView()
                    .controlSize(.small)
            }

            outputCard(output)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Run Restore") { runRestore() }
                    .buttonStyle(.borderedProminent)
                    .tint(AegiroPalette.accentIndigo)
                    .disabled(!canRun)
            }
        }
        .padding(24)
        .frame(width: 700)
        .background(AegiroPalette.backgroundPanel)
        .onAppear {
            if outPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !backupPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                outPath = defaultRestorePath(for: backupPath)
            }
        }
    }

    private func formLabel(_ text: String) -> some View {
        Text(text)
            .font(AegiroTypography.body(12, weight: .semibold))
            .foregroundStyle(AegiroPalette.textSecondary)
    }

    private func outputCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            formLabel("Output")
            ScrollView {
                Text(text.isEmpty ? "No output yet." : text)
                    .font(AegiroTypography.mono(11, weight: .regular))
                    .foregroundStyle(text.isEmpty ? AegiroPalette.textMuted : AegiroPalette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(minHeight: 95, maxHeight: 150)
            .background(AegiroPalette.backgroundMain, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AegiroPalette.borderSubtle, lineWidth: 1)
            )
        }
    }

    private func chooseBackupPath() {
        let panel = NSOpenPanel()
        panel.title = "Choose Backup Archive"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "aegirobackup") ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            backupPath = url.path
            if outPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                outPath = defaultRestorePath(for: url.path)
            }
        }
    }

    private func chooseOutputPath() {
        let panel = NSSavePanel()
        panel.title = "Choose Restore Output"
        panel.nameFieldStringValue = (outPath.isEmpty ? "restored.agvt" : outPath as NSString).lastPathComponent
        panel.allowedContentTypes = [UTType(filenameExtension: "agvt") ?? .data]
        if panel.runModal() == .OK, var url = panel.url {
            if url.pathExtension.lowercased() != "agvt" {
                url.appendPathExtension("agvt")
            }
            outPath = url.path
        }
    }

    private func defaultRestorePath(for backupPath: String) -> String {
        let backupURL = URL(fileURLWithPath: NSString(string: backupPath).expandingTildeInPath)
        let baseName = backupURL.deletingPathExtension().lastPathComponent
        return backupURL.deletingLastPathComponent()
            .appendingPathComponent("\(baseName).agvt")
            .path
    }

    private func runRestore() {
        output = ""
        isRunning = true

        let backupURL = URL(fileURLWithPath: NSString(string: backupPath).expandingTildeInPath)
        let outURL = URL(fileURLWithPath: NSString(string: outPath).expandingTildeInPath)
        model.restoreBackup(backupURL: backupURL, outURL: outURL, overwrite: overwriteExisting) { result in
            isRunning = false
            switch result {
            case .success(let info):
                let backupDate = info.metadata.createdAt.formatted(date: .abbreviated, time: .shortened)
                output = """
                Restored vault to \(outURL.path).
                Backup created: \(backupDate)
                Source vault SHA256: \(info.metadata.sourceVaultSHA256Hex)
                """
                onDone()
            case .failure(let error):
                output = formattedUserError(error)
            }
        }
    }
}

struct VerifySheet: View {
    @EnvironmentObject private var model: VaultModel
    @Environment(\.dismiss) private var dismiss

    @State private var vaultPath = ""
    @State private var isRunning = false
    @State private var output = ""

    var onDone: () -> Void

    private var canRun: Bool {
        !vaultPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isRunning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Verify Vault")
                .font(AegiroTypography.display(24, weight: .semibold))
                .foregroundStyle(AegiroPalette.textPrimary)

            Text("CLI parity for verify --vault <path>.")
                .font(AegiroTypography.body(13, weight: .regular))
                .foregroundStyle(AegiroPalette.textSecondary)

            formLabel("Vault File")
            HStack(spacing: 8) {
                TextField("/path/to/vault.agvt", text: $vaultPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose...") { chooseVaultPath() }
                    .buttonStyle(.bordered)
            }

            if isRunning {
                ProgressView()
                    .controlSize(.small)
            }

            outputCard(output)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Run Verify") { runVerify() }
                    .buttonStyle(.borderedProminent)
                    .tint(AegiroPalette.accentIndigo)
                    .disabled(!canRun)
            }
        }
        .padding(24)
        .frame(width: 620)
        .background(AegiroPalette.backgroundPanel)
        .onAppear {
            if vaultPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                vaultPath = model.vaultURL?.path ?? ""
            }
        }
    }

    private func formLabel(_ text: String) -> some View {
        Text(text)
            .font(AegiroTypography.body(12, weight: .semibold))
            .foregroundStyle(AegiroPalette.textSecondary)
    }

    private func outputCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            formLabel("Output")
            ScrollView {
                Text(text.isEmpty ? "No output yet." : text)
                    .font(AegiroTypography.mono(11, weight: .regular))
                    .foregroundStyle(text.isEmpty ? AegiroPalette.textMuted : AegiroPalette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(minHeight: 95, maxHeight: 140)
            .background(AegiroPalette.backgroundMain, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AegiroPalette.borderSubtle, lineWidth: 1)
            )
        }
    }

    private func chooseVaultPath() {
        let panel = NSOpenPanel()
        panel.title = "Choose Vault"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "agvt") ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            vaultPath = url.path
        }
    }

    private func runVerify() {
        output = ""
        isRunning = true

        let vaultURL = URL(fileURLWithPath: NSString(string: vaultPath).expandingTildeInPath)
        model.verifyManifest(vaultURL: vaultURL) { result in
            isRunning = false
            switch result {
            case .success(let ok):
                output = ok ? "Manifest signature: OK" : "Manifest signature: INVALID"
                onDone()
            case .failure(let error):
                output = "Error: \(formattedUserError(error))"
            }
        }
    }
}

struct StatusSheet: View {
    @EnvironmentObject private var model: VaultModel
    @Environment(\.dismiss) private var dismiss

    @State private var vaultPath = ""
    @State private var passphrase = ""
    @State private var asJSON = false
    @State private var isRunning = false
    @State private var output = ""

    var onDone: () -> Void

    private var canRun: Bool {
        !vaultPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isRunning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Vault Status")
                .font(AegiroTypography.display(24, weight: .semibold))
                .foregroundStyle(AegiroPalette.textPrimary)

            Text("CLI parity for status --vault <path> [--passphrase ...] [--json].")
                .font(AegiroTypography.body(13, weight: .regular))
                .foregroundStyle(AegiroPalette.textSecondary)

            formLabel("Vault File")
            HStack(spacing: 8) {
                TextField("/path/to/vault.agvt", text: $vaultPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose...") { chooseVaultPath() }
                    .buttonStyle(.bordered)
            }

            formLabel("Passphrase (Optional)")
            SecureField("Optional for unlocked file count", text: $passphrase)
                .textFieldStyle(.roundedBorder)

            Toggle("Render JSON output", isOn: $asJSON)

            if isRunning {
                ProgressView()
                    .controlSize(.small)
            }

            outputCard

            HStack {
                Button("Copy Output") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                }
                .buttonStyle(.bordered)
                .disabled(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()
                Button("Cancel") { dismiss() }
                Button("Load Status") { runStatus() }
                    .buttonStyle(.borderedProminent)
                    .tint(AegiroPalette.accentIndigo)
                    .disabled(!canRun)
            }
        }
        .padding(24)
        .frame(width: 760)
        .background(AegiroPalette.backgroundPanel)
        .onAppear {
            if vaultPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                vaultPath = model.vaultURL?.path ?? ""
            }
            if passphrase.isEmpty {
                passphrase = model.passphrase
            }
        }
    }

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            formLabel("Output")
            ScrollView {
                Text(output.isEmpty ? "No output yet." : output)
                    .font(AegiroTypography.mono(11, weight: .regular))
                    .foregroundStyle(output.isEmpty ? AegiroPalette.textMuted : AegiroPalette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(minHeight: 180, maxHeight: 300)
            .background(AegiroPalette.backgroundMain, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AegiroPalette.borderSubtle, lineWidth: 1)
            )
        }
    }

    private func formLabel(_ text: String) -> some View {
        Text(text)
            .font(AegiroTypography.body(12, weight: .semibold))
            .foregroundStyle(AegiroPalette.textSecondary)
    }

    private func chooseVaultPath() {
        let panel = NSOpenPanel()
        panel.title = "Choose Vault"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "agvt") ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            vaultPath = url.path
        }
    }

    private func runStatus() {
        output = ""
        isRunning = true

        let vaultURL = URL(fileURLWithPath: NSString(string: vaultPath).expandingTildeInPath)
        let pass = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        model.renderVaultStatus(vaultURL: vaultURL, passphrase: pass.isEmpty ? nil : pass, asJSON: asJSON) { result in
            isRunning = false
            switch result {
            case .success(let text):
                output = text
                onDone()
            case .failure(let error):
                output = "Error: \(formattedUserError(error))"
            }
        }
    }
}

struct ScanSheet: View {
    @EnvironmentObject private var model: VaultModel
    @Environment(\.dismiss) private var dismiss

    @State private var pathInput: String = ""
    @State private var isRunning = false
    @State private var output = ""

    var onDone: () -> Void

    private var parsedPaths: [String] {
        pathInput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var canRun: Bool {
        !parsedPaths.isEmpty && !isRunning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Privacy Scan")
                .font(AegiroTypography.display(24, weight: .semibold))
                .foregroundStyle(AegiroPalette.textPrimary)

            Text("CLI parity for scan <paths...>.")
                .font(AegiroTypography.body(13, weight: .regular))
                .foregroundStyle(AegiroPalette.textSecondary)

            formLabel("Paths (one per line)")
            TextEditor(text: $pathInput)
                .font(AegiroTypography.mono(11, weight: .regular))
                .foregroundStyle(AegiroPalette.textPrimary)
                .frame(minHeight: 90, maxHeight: 130)
                .scrollContentBackground(.hidden)
                .background(AegiroPalette.backgroundMain, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(AegiroPalette.borderSubtle, lineWidth: 1)
                )

            HStack(spacing: 8) {
                Button("Add Paths...") { chooseScanPaths() }
                    .buttonStyle(.bordered)
                Button("Clear Paths") { pathInput = "" }
                    .buttonStyle(.bordered)
            }

            if isRunning {
                ProgressView()
                    .controlSize(.small)
            }

            outputCard

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Run Scan") { runScan() }
                    .buttonStyle(.borderedProminent)
                    .tint(AegiroPalette.accentIndigo)
                    .disabled(!canRun)
            }
        }
        .padding(24)
        .frame(width: 760)
        .background(AegiroPalette.backgroundPanel)
    }

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            formLabel("Output")
            ScrollView {
                Text(output.isEmpty ? "No output yet." : output)
                    .font(AegiroTypography.mono(11, weight: .regular))
                    .foregroundStyle(output.isEmpty ? AegiroPalette.textMuted : AegiroPalette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(minHeight: 140, maxHeight: 230)
            .background(AegiroPalette.backgroundMain, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AegiroPalette.borderSubtle, lineWidth: 1)
            )
        }
    }

    private func formLabel(_ text: String) -> some View {
        Text(text)
            .font(AegiroTypography.body(12, weight: .semibold))
            .foregroundStyle(AegiroPalette.textSecondary)
    }

    private func chooseScanPaths() {
        let panel = NSOpenPanel()
        panel.title = "Choose Files or Folders to Scan"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            let joined = panel.urls.map(\.path).joined(separator: "\n")
            if pathInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pathInput = joined
            } else {
                pathInput += "\n" + joined
            }
        }
    }

    private func runScan() {
        output = ""
        isRunning = true
        model.scanPrivacy(paths: parsedPaths) { matches in
            isRunning = false
            if matches.isEmpty {
                output = "No privacy matches found."
            } else {
                output = matches
                    .map { "\($0.path)\t\($0.reason)" }
                    .joined(separator: "\n")
            }
            onDone()
        }
    }
}

struct ShredSheet: View {
    @EnvironmentObject private var model: VaultModel
    @Environment(\.dismiss) private var dismiss

    @State private var pathInput: String = ""
    @State private var confirmDestructive = false
    @State private var isRunning = false
    @State private var output = ""

    var onDone: () -> Void

    private var parsedPaths: [String] {
        pathInput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var canRun: Bool {
        !parsedPaths.isEmpty && confirmDestructive && !isRunning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Secure Shred")
                .font(AegiroTypography.display(24, weight: .semibold))
                .foregroundStyle(AegiroPalette.textPrimary)

            Text("CLI parity for shred <paths...>. This permanently destroys selected files.")
                .font(AegiroTypography.body(13, weight: .regular))
                .foregroundStyle(AegiroPalette.textSecondary)

            formLabel("Files To Shred (one per line)")
            TextEditor(text: $pathInput)
                .font(AegiroTypography.mono(11, weight: .regular))
                .foregroundStyle(AegiroPalette.textPrimary)
                .frame(minHeight: 90, maxHeight: 130)
                .scrollContentBackground(.hidden)
                .background(AegiroPalette.backgroundMain, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(AegiroPalette.borderSubtle, lineWidth: 1)
                )

            HStack(spacing: 8) {
                Button("Add Files...") { chooseShredFiles() }
                    .buttonStyle(.bordered)
                Button("Clear Paths") { pathInput = "" }
                    .buttonStyle(.bordered)
            }

            Toggle("I understand this cannot be undone", isOn: $confirmDestructive)
                .foregroundStyle(confirmDestructive ? AegiroPalette.textPrimary : AegiroPalette.warningAmber)

            if isRunning {
                ProgressView()
                    .controlSize(.small)
            }

            outputCard

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Run Shred") { runShred() }
                    .buttonStyle(.borderedProminent)
                    .tint(AegiroPalette.dangerRed)
                    .disabled(!canRun)
            }
        }
        .padding(24)
        .frame(width: 760)
        .background(AegiroPalette.backgroundPanel)
    }

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            formLabel("Output")
            ScrollView {
                Text(output.isEmpty ? "No output yet." : output)
                    .font(AegiroTypography.mono(11, weight: .regular))
                    .foregroundStyle(output.isEmpty ? AegiroPalette.textMuted : AegiroPalette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(minHeight: 120, maxHeight: 220)
            .background(AegiroPalette.backgroundMain, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AegiroPalette.borderSubtle, lineWidth: 1)
            )
        }
    }

    private func formLabel(_ text: String) -> some View {
        Text(text)
            .font(AegiroTypography.body(12, weight: .semibold))
            .foregroundStyle(AegiroPalette.textSecondary)
    }

    private func chooseShredFiles() {
        let panel = NSOpenPanel()
        panel.title = "Choose Files to Shred"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            let joined = panel.urls.map(\.path).joined(separator: "\n")
            if pathInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pathInput = joined
            } else {
                pathInput += "\n" + joined
            }
        }
    }

    private func runShred() {
        output = ""
        isRunning = true
        model.shred(paths: parsedPaths) { result in
            isRunning = false
            switch result {
            case .success(let shredded):
                output = shredded.isEmpty
                    ? "No files were shredded."
                    : shredded.map { "Shredded \($0)" }.joined(separator: "\n")
                onDone()
            case .failure(let error):
                output = "Error: \(formattedUserError(error))"
            }
        }
    }
}

struct APFSVolumeOptionsPanel: View {
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

    private var selectedNormalizedPath: String {
        normalizedPath(selectedTrimmed)
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
                    .font(AegiroTypography.body(12, weight: .semibold))
                    .foregroundStyle(AegiroPalette.textSecondary)
                Spacer()
                if !mountedExternalOptions.isEmpty && mountedExternalOptions.count != externalOptions.count {
                    Button(showAllVolumes ? "Show Mounted Only" : "Show All External") {
                        showAllVolumes.toggle()
                    }
                    .buttonStyle(.bordered)
                    .font(AegiroTypography.body(11, weight: .semibold))
                }
                Button {
                    refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(AegiroTypography.body(11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .disabled(isLoading)
            }

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning volumes...")
                        .font(AegiroTypography.body(12, weight: .medium))
                        .foregroundStyle(AegiroPalette.textSecondary)
                }
            }

            if let errorMessage, !errorMessage.isEmpty {
                Text("Could not load APFS options: \(errorMessage)")
                    .font(AegiroTypography.body(11, weight: .regular))
                    .foregroundStyle(AegiroPalette.warningAmber)
            }

            if displayRows.isEmpty {
                Text(noAPFSMessage)
                    .font(AegiroTypography.body(11, weight: .regular))
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
                                                    .font(AegiroTypography.body(13, weight: .semibold))
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
                                                .font(AegiroTypography.mono(12, weight: .medium))
                                                .foregroundStyle(AegiroPalette.textSecondary)
                                            Text(optionMetaLine(for: option))
                                                .font(AegiroTypography.body(11, weight: .regular))
                                                .foregroundStyle(AegiroPalette.textMuted)
                                        }
                                        Spacer(minLength: 8)
                                        if isSelected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(AegiroPalette.securityGreen)
                                                .font(AegiroTypography.body(15, weight: .semibold))
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
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            case .nonAPFS(let volume):
                                if let onSelectNonAPFSVolume {
                                    let isSelected = normalizedPath(volume.mountPoint) == selectedNormalizedPath
                                    Button {
                                        selectedDiskIdentifier = volume.mountPoint
                                        onSelectNonAPFSVolume(volume)
                                    } label: {
                                        HStack(alignment: .top, spacing: 10) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                HStack(spacing: 6) {
                                                    Text(volume.mountPoint)
                                                        .font(AegiroTypography.mono(13, weight: .semibold))
                                                        .foregroundStyle(AegiroPalette.textPrimary)
                                                    badge(text: "Not APFS", color: AegiroPalette.warningAmber)
                                                }
                                                Text("\(volume.filesystemType.uppercased()) • \(volume.deviceIdentifier)")
                                                    .font(AegiroTypography.body(11, weight: .regular))
                                                    .foregroundStyle(AegiroPalette.textSecondary)
                                            }
                                            Spacer(minLength: 8)
                                            if isSelected {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundStyle(AegiroPalette.securityGreen)
                                                    .font(AegiroTypography.body(15, weight: .semibold))
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
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    HStack(alignment: .top, spacing: 10) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack(spacing: 6) {
                                                Text(volume.mountPoint)
                                                    .font(AegiroTypography.mono(13, weight: .semibold))
                                                    .foregroundStyle(AegiroPalette.textMuted)
                                                badge(text: "Not APFS", color: AegiroPalette.textMuted)
                                            }
                                            Text("\(volume.filesystemType.uppercased()) • \(volume.deviceIdentifier)")
                                                .font(AegiroTypography.body(11, weight: .regular))
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
                    .font(AegiroTypography.body(10, weight: .regular))
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

    private func normalizedPath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath, isDirectory: true).standardizedFileURL.path
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(AegiroTypography.body(10, weight: .bold))
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
    if isExcludedSimulatorAPFSOption(option) {
        return false
    }
    guard let mountPoint = option.mountPoint else {
        return false
    }
    if isExcludedSystemExternalMountPoint(mountPoint) {
        return false
    }
    return mountPoint == "/Volumes" || mountPoint.hasPrefix("/Volumes/")
}

private func isExternalAPFSVolume(_ option: APFSVolumeOption) -> Bool {
    if isExcludedSimulatorAPFSOption(option) {
        return false
    }
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

private func isExcludedSimulatorAPFSOption(_ option: APFSVolumeOption) -> Bool {
    isLikelySimulatorRuntimeVolumeName(option.name)
}

private func isExcludedSystemExternalMountPoint(_ mountPoint: String) -> Bool {
    let lowered = mountPoint.lowercased()
    if lowered.contains("/coresimulator/") {
        return true
    }
    return isSimulatorRuntimeVolumeMountPoint(mountPoint)
}

private func isLikelySimulatorRuntimeVolumeName(_ name: String) -> Bool {
    let lowered = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !lowered.isEmpty, lowered.contains("simulator") else {
        return false
    }
    let simulatorOSPrefixes = ["ios", "ipados", "watchos", "tvos", "visionos", "xros"]
    return simulatorOSPrefixes.contains(where: { lowered.hasPrefix($0) })
}

private func isSimulatorRuntimeVolumeMountPoint(_ mountPoint: String) -> Bool {
    let volumePrefix = "/Volumes/"
    guard mountPoint.hasPrefix(volumePrefix) else {
        return false
    }
    let volumeName = String(mountPoint.dropFirst(volumePrefix.count)).lowercased()
    guard !volumeName.isEmpty else {
        return false
    }
    let simulatorOSPrefixes = ["ios", "ipados", "watchos", "tvos", "visionos", "xros"]
    guard simulatorOSPrefixes.contains(where: { volumeName.hasPrefix($0) }) else {
        return false
    }
    return volumeName.contains("simulator")
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

struct DoctorSheet: View {
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) private var dismiss

    @State private var report: DoctorReport?
    @State private var runMessage: String = ""
    @State private var isRunning = false
    @State private var doctorLogLines: [String] = []
    @State private var doctorLogExpanded = true

    private var canApplyFix: Bool {
        let trimmed = model.passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !model.locked
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Vault Doctor")
                .font(AegiroTypography.display(24, weight: .semibold))
                .foregroundStyle(AegiroPalette.textPrimary)

            Text("Run integrity checks directly in the app.")
                .font(AegiroTypography.body(13, weight: .regular))
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
                        .font(AegiroTypography.body(12, weight: .medium))
                    }
                    if report.fixed {
                        Text("Fix applied: manifest was re-signed.")
                            .font(AegiroTypography.body(12, weight: .semibold))
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
                        .font(AegiroTypography.body(13, weight: .semibold))
                        .foregroundStyle(AegiroPalette.textPrimary)
                    ForEach(report.issues, id: \.self) { issue in
                        Text("- \(issue)")
                            .font(AegiroTypography.body(12, weight: .regular))
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
                    .font(AegiroTypography.body(12, weight: .regular))
                    .foregroundStyle(AegiroPalette.warningAmber)
            }

            if !runMessage.isEmpty {
                Text(runMessage)
                    .font(AegiroTypography.body(12, weight: .regular))
                    .foregroundStyle(AegiroPalette.textSecondary)
            }

            if isRunning || !doctorLogLines.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Activity")
                            .font(AegiroTypography.body(13, weight: .semibold))
                            .foregroundStyle(AegiroPalette.textPrimary)
                        Spacer()
                        Button {
                            doctorLogExpanded.toggle()
                        } label: {
                            Image(systemName: doctorLogExpanded ? "chevron.up" : "chevron.down")
                        }
                        .buttonStyle(.bordered)
                        .help(doctorLogExpanded ? "Collapse activity log" : "Expand activity log")
                        .accessibilityLabel(doctorLogExpanded ? "Collapse activity log" : "Expand activity log")
                    }
                    if doctorLogExpanded {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(doctorLogLines.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(AegiroTypography.mono(11, weight: .regular))
                                        .foregroundStyle(AegiroPalette.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(minHeight: 84, maxHeight: 140)
                        .padding(8)
                        .background(AegiroPalette.backgroundMain, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(AegiroPalette.borderSubtle, lineWidth: 1)
                        )
                    }
                }
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
        .font(AegiroTypography.mono(12, weight: .semibold))
    }

    private func runDoctor(fix: Bool) {
        guard let vaultURL = model.vaultURL else {
            runMessage = "Open a vault first."
            return
        }

        let trimmedPass = model.passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let passphrase = trimmedPass.isEmpty ? nil : trimmedPass

        doctorLogLines = []
        doctorLogExpanded = true
        isRunning = true
        runMessage = fix ? "Running doctor and applying fix..." : "Running doctor..."
        appendDoctorLog(runMessage)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try Doctor.run(vaultURL: vaultURL,
                                            passphrase: passphrase,
                                            fix: fix,
                                            deepCheck: !fix) { message in
                    DispatchQueue.main.async {
                        appendDoctorLog(message)
                    }
                }
                DispatchQueue.main.async {
                    report = result
                    if fix {
                        let flagsChanged = model.normalizeUnlockFlagsIfNeeded()
                        let hasIssues = !result.issues.isEmpty
                        switch (result.fixed, flagsChanged, hasIssues) {
                        case (true, true, _):
                            runMessage = "Doctor completed. Applied manifest fix and normalized unlock flags."
                        case (true, false, _):
                            runMessage = "Doctor completed. Applied manifest fix."
                        case (false, true, true):
                            runMessage = "Doctor completed. Normalized unlock flags. Remaining issues require manual repair."
                        case (false, true, false):
                            runMessage = "Doctor completed. Normalized unlock flags."
                        case (false, false, true):
                            runMessage = "Doctor completed. No automatic fix was applied. Review listed issues."
                        case (false, false, false):
                            runMessage = "Doctor completed. No fixes were needed."
                        }
                    } else {
                        runMessage = "Doctor completed."
                    }
                    appendDoctorLog(runMessage)
                    doctorLogExpanded = false
                    isRunning = false
                    model.refreshStatus()
                }
            } catch {
                DispatchQueue.main.async {
                    runMessage = "Doctor failed: \(formattedUserError(error))"
                    appendDoctorLog(runMessage)
                    doctorLogExpanded = false
                    isRunning = false
                }
            }
        }
    }

    private func appendDoctorLog(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if doctorLogLines.last == trimmed {
            return
        }
        doctorLogLines.append(trimmed)
        if doctorLogLines.count > 240 {
            doctorLogLines.removeFirst(doctorLogLines.count - 240)
        }
    }
}

enum ContentViewMode: Hashable {
    case list
    case grid
}

enum SortOption: CaseIterable {
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

extension VaultIndexEntry {
    var displayName: String {
        (logicalPath as NSString).lastPathComponent
    }

    var parentPathDisplay: String {
        let parent = (logicalPath as NSString).deletingLastPathComponent
        if parent.isEmpty || parent == "." {
            return "/"
        }
        return parent
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

extension ByteCountFormatter {
    static let fileFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()
}
