
import Foundation

public struct PrivacyMatch {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct PrivacyScanOptions {
    public var includeFileContents: Bool
    public var maxFileBytes: Int

    public init(includeFileContents: Bool = true, maxFileBytes: Int = 2_000_000) {
        self.includeFileContents = includeFileContents
        self.maxFileBytes = max(1, maxFileBytes)
    }
}

public final class PrivacyMonitor {
    static let patterns: [String] = [
        "passport", "ssn", "social", "tax", "bank", "medical", "insurance", "id", "driver", "invoice", "payroll"
    ]

    private static let regexDetectors: [(label: String, regex: NSRegularExpression)] = [
        ("ssn-pattern", makeRegex(#"\b\d{3}-\d{2}-\d{4}\b"#)),
        ("email-pattern", makeRegex(#"\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b"#, options: [.caseInsensitive])),
        ("card-number", makeRegex(#"\b(?:\d[ -]*?){13,19}\b"#))
    ]

    public static func scan(paths: [String], options: PrivacyScanOptions = PrivacyScanOptions()) -> [PrivacyMatch] {
        var out: [PrivacyMatch] = []
        let fm = FileManager.default

        for p in paths {
            let expanded = NSString(string: p).expandingTildeInPath
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: expanded, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                let rootURL = URL(fileURLWithPath: expanded, isDirectory: true)
                let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
                let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: Array(keys), options: [], errorHandler: nil)
                while let fileURL = enumerator?.nextObject() as? URL {
                    let values = try? fileURL.resourceValues(forKeys: keys)
                    appendMatches(forPath: fileURL.path,
                                  fileSize: values?.fileSize,
                                  options: options,
                                  into: &out)
                }
            } else {
                let size = (try? fm.attributesOfItem(atPath: expanded)[.size] as? NSNumber)?.intValue
                appendMatches(forPath: expanded,
                              fileSize: size,
                              options: options,
                              into: &out)
            }
        }
        return out
    }

    private static func appendMatches(forPath path: String,
                                      fileSize: Int?,
                                      options: PrivacyScanOptions,
                                      into out: inout [PrivacyMatch]) {
        let reasons = detectedReasons(forPath: path, fileSize: fileSize, options: options)
        for reason in reasons.sorted() {
            out.append(PrivacyMatch(path: path, reason: reason))
        }
    }

    private static func detectedReasons(forPath path: String,
                                        fileSize: Int?,
                                        options: PrivacyScanOptions) -> Set<String> {
        var reasons = Set<String>()
        let lowerName = (path as NSString).lastPathComponent.lowercased()
        for pattern in patterns where lowerName.contains(pattern) {
            reasons.insert("name:\(pattern)")
        }

        guard options.includeFileContents else { return reasons }
        guard let fileSize else { return reasons }
        guard fileSize > 0 && fileSize <= options.maxFileBytes else { return reasons }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]) else {
            return reasons
        }
        guard data.count <= options.maxFileBytes else { return reasons }
        guard data.firstIndex(of: 0) == nil else { return reasons } // Skip likely binary files.
        guard let text = decodeText(data) else { return reasons }

        let lowerText = text.lowercased()
        for pattern in patterns where lowerText.contains(pattern) {
            reasons.insert("content:\(pattern)")
        }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for detector in regexDetectors {
            switch detector.label {
            case "card-number":
                if containsValidCardNumber(in: text, regex: detector.regex, range: fullRange) {
                    reasons.insert("content:card-number")
                }
            default:
                if detector.regex.firstMatch(in: text, options: [], range: fullRange) != nil {
                    reasons.insert("content:\(detector.label)")
                }
            }
        }

        return reasons
    }

    private static func decodeText(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let utf16 = String(data: data, encoding: .utf16) {
            return utf16
        }
        if let latin = String(data: data, encoding: .isoLatin1) {
            return latin
        }
        return nil
    }

    private static func containsValidCardNumber(in text: String,
                                                regex: NSRegularExpression,
                                                range: NSRange) -> Bool {
        for match in regex.matches(in: text, options: [], range: range) {
            guard let swiftRange = Range(match.range, in: text) else { continue }
            let digits = text[swiftRange].filter(\.isNumber)
            guard digits.count >= 13 && digits.count <= 19 else { continue }
            if passesLuhn(digits) {
                return true
            }
        }
        return false
    }

    private static func passesLuhn<S: StringProtocol>(_ digits: S) -> Bool {
        var sum = 0
        var shouldDouble = false
        for char in digits.reversed() {
            guard let value = char.wholeNumberValue else { return false }
            var current = value
            if shouldDouble {
                current *= 2
                if current > 9 {
                    current -= 9
                }
            }
            sum += current
            shouldDouble.toggle()
        }
        return sum % 10 == 0
    }

    private static func makeRegex(_ pattern: String,
                                  options: NSRegularExpression.Options = []) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("Invalid regex pattern: \(pattern)")
        }
    }
}
