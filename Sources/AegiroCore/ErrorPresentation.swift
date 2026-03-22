import Foundation

public enum AegiroUserError {
    public static func message(for error: Error) -> String {
        if let aegError = error as? AEGError {
            return aegError.userMessage
        }

        let nsError = error as NSError
        if let description = (nsError.userInfo[NSLocalizedDescriptionKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            return description
        }

        let localized = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !localized.isEmpty {
            return localized
        }

        return String(describing: error)
    }

    public static func supportCode(for error: Error) -> String? {
        if let aegError = error as? AEGError {
            switch aegError {
            case .crypto:
                return "AEG-CRY-001"
            case .io:
                return "AEG-IO-001"
            case .integrity:
                return "AEG-INT-001"
            case .unsupported:
                return "AEG-UNS-001"
            }
        }

        let nsError = error as NSError
        let number = formattedCodeNumber(nsError.code)

        switch nsError.domain {
        case "Backup":
            return "AEG-BKP-\(number)"
        case "ManifestIO":
            return "AEG-MAN-\(number)"
        case "VaultRead":
            return "AEG-VRD-\(number)"
        case "VaultHeader":
            return "AEG-VHD-\(number)"
        case "VaultSettings":
            return "AEG-VST-\(number)"
        case "Shred":
            return "AEG-SHD-\(number)"
        case "VaultModel":
            return "AEG-APP-\(number)"
        default:
            let token = nsError.domain.uppercased().filter { $0.isLetter || $0.isNumber }
            guard !token.isEmpty else { return nil }
            return "AEG-\(String(token.prefix(6)))-\(number)"
        }
    }

    public static func messageWithCode(for error: Error) -> String {
        let userMessage = message(for: error)
        guard let supportCode = supportCode(for: error) else { return userMessage }
        return "\(userMessage) [Code: \(supportCode)]"
    }

    private static func formattedCodeNumber(_ rawCode: Int) -> String {
        let safeCode: Int
        if rawCode == Int.min {
            safeCode = 0
        } else {
            safeCode = abs(rawCode)
        }
        return String(format: "%03d", safeCode)
    }
}

extension AEGError {
    fileprivate var userMessage: String {
        switch self {
        case .crypto(let message):
            return message
        case .io(let message):
            return message
        case .integrity(let message):
            return message
        case .unsupported(let message):
            return message
        }
    }
}

extension AEGError: LocalizedError {
    public var errorDescription: String? {
        userMessage
    }
}
