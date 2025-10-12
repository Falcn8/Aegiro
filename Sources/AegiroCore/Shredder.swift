
import Foundation

public final class Shredder {
    public static func shred(path: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return }
        let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard let handle = FileHandle(forWritingAtPath: path) else { throw NSError(domain: "Shred", code: 1) }
        let chunk = 1024 * 1024
        var remaining = Int(size)
        var buf = Data(count: chunk)
        while remaining > 0 {
            let n = min(remaining, chunk)
            buf = Data((0..<n).map { _ in UInt8.random(in: 0...255) })
            try handle.write(contentsOf: buf)
            remaining -= n
        }
        try handle.synchronize()
        try handle.seek(toOffset: 0)
        remaining = Int(size)
        while remaining > 0 {
            let n = min(remaining, chunk)
            buf = Data(count: n)
            try handle.write(contentsOf: buf)
            remaining -= n
        }
        try handle.synchronize()
        try handle.close()
        try fm.removeItem(atPath: path)
    }
}
