
import Foundation

public final class SessionLock {
    private var badAttempts = 0
    private var nextAllowed: Date = .distantPast

    public func recordBadAttempt() -> TimeInterval {
        badAttempts += 1
        let delay: TimeInterval
        switch badAttempts {
        case 1: delay = 5
        case 2: delay = 15
        case 3: delay = 60
        default: delay = 300
        }
        nextAllowed = Date().addingTimeInterval(delay)
        return delay
    }
    public func canAttempt() -> Bool { Date() >= nextAllowed }
    public func reset() { badAttempts = 0; nextAllowed = .distantPast }
}
