import Foundation
import CryptoKit

// Convenience to access raw nonce bytes as Data
extension AES.GCM.Nonce {
    public var data: Data {
        return withUnsafeBytes { raw in
            Data(bytes: raw.baseAddress!, count: raw.count)
        }
    }
}

