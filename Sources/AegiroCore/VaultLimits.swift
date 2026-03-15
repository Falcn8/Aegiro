import Foundation

public enum VaultLimits {
    // Practical default for JSON index size/perf while allowing large personal archives.
    public static let defaultMaxFilesPerVault = 1_000

    // Optional runtime override for power users and testing.
    public static let maxFilesEnvKey = "AEGIRO_MAX_FILES_PER_VAULT"

    // Internal override used by tests to avoid generating huge fixtures.
    static var testOverrideMaxFilesPerVault: Int?

    public static var maxFilesPerVault: Int {
        if let override = testOverrideMaxFilesPerVault, override > 0 {
            return override
        }
        if let raw = ProcessInfo.processInfo.environment[maxFilesEnvKey],
           let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           parsed > 0 {
            return parsed
        }
        return defaultMaxFilesPerVault
    }

    public static func enforceProjectedFileCount(existingCount: Int,
                                                 replacedCount: Int,
                                                 addingCount: Int) throws {
        let projected = existingCount - replacedCount + addingCount
        guard projected <= maxFilesPerVault else {
            throw AEGError.io("Vault file limit exceeded: \(projected) files would exceed max \(maxFilesPerVault). Split files across multiple vaults or raise \(maxFilesEnvKey).")
        }
    }
}
