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
            deletePassphrase(account: account, dataProtection: false)
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: primaryAccount,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: access,
            kSecUseDataProtectionKeychain as String: true
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BiometricKeychainError.unexpectedStatus(status)
        }
    }

    static func removePassphrase(for vaultURL: URL) {
        for account in accountCandidates(for: vaultURL) {
            deletePassphrase(account: account, dataProtection: true)
            deletePassphrase(account: account, dataProtection: false)
        }
    }

    static func loadPassphrase(for vaultURL: URL, context: LAContext) throws -> String {
        for account in accountCandidates(for: vaultURL) {
            if let passphrase = try queryPassphrase(account: account, context: context, dataProtection: true) {
                return passphrase
            }

            // Backward compatibility for items saved before data-protection keychain migration.
            if let legacy = try queryPassphrase(account: account, context: context, dataProtection: false) {
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

    private static func deletePassphrase(account: String, dataProtection: Bool) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        query[kSecUseDataProtectionKeychain as String] = dataProtection
        SecItemDelete(query as CFDictionary)
    }

    private static func queryPassphrase(account: String, context: LAContext, dataProtection: Bool) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        query[kSecUseDataProtectionKeychain as String] = dataProtection

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
        default:
            throw BiometricKeychainError.unexpectedStatus(status)
        }
    }
}
