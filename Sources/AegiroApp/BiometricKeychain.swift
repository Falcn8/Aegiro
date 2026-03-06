import Foundation
@preconcurrency import LocalAuthentication
import Security

enum BiometricKeychainError: Error {
    case accessControlCreationFailed
    case itemNotFound
    case unexpectedStatus(OSStatus)
    case stringDecodingFailed
}

enum BiometricKeychain {
    private static let service = "app.aegiro.vaultpass"

    static func supportsBiometricKeychainStorage() -> Bool {
        // Try both data-protection and legacy keychain paths because debug/local builds can vary.
        return canStoreProbe(dataProtection: true) || canStoreProbe(dataProtection: nil)
    }

    static func save(passphrase: String, for vaultURL: URL) throws {
        let primaryAccount = canonicalAccount(for: vaultURL)
        let accounts = accountCandidates(for: vaultURL)
        let data = Data(passphrase.utf8)

        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            nil
        ) else {
            throw BiometricKeychainError.accessControlCreationFailed
        }

        // Remove any existing item first (both modern and legacy keychain stores).
        for account in accounts {
            deletePassphrase(account: account, dataProtection: true)
            deletePassphrase(account: account, dataProtection: nil)
        }

        var lastStatus: OSStatus = errSecSuccess
        for dataProtection in [true, nil] {
            let status = addPassphrase(
                account: primaryAccount,
                data: data,
                access: access,
                dataProtection: dataProtection
            )
            if status == errSecSuccess {
                return
            }
            lastStatus = status
            // If this build lacks data protection keychain entitlement, retry with legacy keychain.
            if status == errSecMissingEntitlement && dataProtection != nil {
                continue
            }
        }
        throw BiometricKeychainError.unexpectedStatus(lastStatus)
    }

    static func removePassphrase(for vaultURL: URL) {
        for account in accountCandidates(for: vaultURL) {
            deletePassphrase(account: account, dataProtection: true)
            deletePassphrase(account: account, dataProtection: nil)
        }
    }

    static func loadPassphrase(for vaultURL: URL, context: LAContext) throws -> String {
        for account in accountCandidates(for: vaultURL) {
            if let passphrase = try queryPassphrase(account: account, context: context, dataProtection: true, allowEntitlementFallback: true) {
                return passphrase
            }

            // Backward compatibility for items saved before data-protection keychain migration.
            if let legacy = try queryPassphrase(account: account, context: context, dataProtection: nil, allowEntitlementFallback: false) {
                try save(passphrase: legacy, for: vaultURL)
                return legacy
            }
        }
        throw BiometricKeychainError.itemNotFound
    }

    private static func canonicalAccount(for vaultURL: URL) -> String {
        vaultURL.standardizedFileURL.path
    }

    private static func accountCandidates(for vaultURL: URL) -> [String] {
        var candidates: [String] = []
        func addCandidate(_ path: String) {
            guard !path.isEmpty, !candidates.contains(path) else { return }
            candidates.append(path)
        }

        addCandidate(canonicalAccount(for: vaultURL))
        addCandidate(vaultURL.path)
        addCandidate(vaultURL.resolvingSymlinksInPath().path)
        return candidates
    }

    private static func deletePassphrase(account: String, dataProtection: Bool?) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let dataProtection {
            query[kSecUseDataProtectionKeychain as String] = dataProtection
        }
        SecItemDelete(query as CFDictionary)
    }

    private static func addPassphrase(account: String, data: Data, access: SecAccessControl, dataProtection: Bool?) -> OSStatus {
        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: access
        ]
        if let dataProtection {
            addQuery[kSecUseDataProtectionKeychain as String] = dataProtection
        }
        return SecItemAdd(addQuery as CFDictionary, nil)
    }

    private static func canStoreProbe(dataProtection: Bool?) -> Bool {
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            nil
        ) else {
            return false
        }

        let account = "probe.\(UUID().uuidString)"
        let data = Data("probe".utf8)

        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service + ".probe",
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: access
        ]
        if let dataProtection {
            addQuery[kSecUseDataProtectionKeychain as String] = dataProtection
        }

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        var deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service + ".probe",
            kSecAttrAccount as String: account
        ]
        if let dataProtection {
            deleteQuery[kSecUseDataProtectionKeychain as String] = dataProtection
        }
        SecItemDelete(deleteQuery as CFDictionary)

        return status == errSecSuccess || status == errSecDuplicateItem
    }

    private static func queryPassphrase(
        account: String,
        context: LAContext,
        dataProtection: Bool?,
        allowEntitlementFallback: Bool
    ) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        if let dataProtection {
            query[kSecUseDataProtectionKeychain as String] = dataProtection
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let pass = String(data: data, encoding: .utf8) else {
                throw BiometricKeychainError.stringDecodingFailed
            }
            return pass
        case errSecItemNotFound:
            return nil
        case errSecMissingEntitlement where allowEntitlementFallback:
            return nil
        default:
            throw BiometricKeychainError.unexpectedStatus(status)
        }
    }
}
