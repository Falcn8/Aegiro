
import Foundation
public final class NetworkAllowlist {
    public static let allowedHosts: [String] = [
        "updates.aegiro.local"
    ]
    public static func isAllowed(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains(host)
    }
}
