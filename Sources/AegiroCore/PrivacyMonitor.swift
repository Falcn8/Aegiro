
import Foundation

public struct PrivacyMatch {
    public let path: String
    public let reason: String
}

public final class PrivacyMonitor {
    static let patterns = [
        "passport", "ssn", "tax", "bank", "medical", "insurance", "id", "driver"
    ]

    public static func scan(paths: [String]) -> [PrivacyMatch] {
        var out: [PrivacyMatch] = []
        for p in paths {
            let fm = FileManager.default
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: p, isDirectory: &isDir) {
                if isDir.boolValue {
                    let enumerator = fm.enumerator(atPath: p)
                    while let e = enumerator?.nextObject() as? String {
                        let lower = e.lowercased()
                        for pat in patterns {
                            if lower.contains(pat) {
                                out.append(PrivacyMatch(path: (p as NSString).appendingPathComponent(e), reason: "name:\(pat)"))
                                break
                            }
                        }
                    }
                } else {
                    let lower = (p as NSString).lastPathComponent.lowercased()
                    for pat in patterns {
                        if lower.contains(pat) {
                            out.append(PrivacyMatch(path: p, reason: "name:\(pat)"))
                            break
                        }
                    }
                }
            }
        }
        return out
    }
}
