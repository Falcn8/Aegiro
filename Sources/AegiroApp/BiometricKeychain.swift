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
        let account = vaultURL.path
        let data = Data(passphrase.utf8)

        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            nil
        ) else {
            throw BiometricKeychainError.accessControlCreationFailed
        }

        // Remove any existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let context = LAContext()
        context.interactionNotAllowed = true
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: access,
            kSecUseAuthenticationContext as String: context
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BiometricKeychainError.unexpectedStatus(status)
        }
    }

    static func removePassphrase(for vaultURL: URL) {
        let account = vaultURL.path
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)
    }

    static func loadPassphrase(for vaultURL: URL, context: LAContext) throws -> String {
        let account = vaultURL.path
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let pass = String(data: data, encoding: .utf8) else {
                throw BiometricKeychainError.stringDecodingFailed
            }
            return pass
        case errSecItemNotFound:
            throw BiometricKeychainError.itemNotFound
        default:
            throw BiometricKeychainError.unexpectedStatus(status)
        }
    }
}
