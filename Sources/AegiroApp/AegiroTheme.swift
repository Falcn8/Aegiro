import SwiftUI

enum AegiroPalette {
    static let accentIndigo = Color(hex: "#4F46E5")
    static let securityGreen = Color(hex: "#10B981")
    static let warningAmber = Color(hex: "#F59E0B")
    static let dangerRed = Color(hex: "#EF4444")

    static let backgroundMain = Color(hex: "#0F172A")
    static let backgroundPanel = Color(hex: "#111827")
    static let backgroundCard = Color(hex: "#1F2937")
    static let borderSubtle = Color(hex: "#374151")

    static let textPrimary = Color.white
    static let textSecondary = Color(hex: "#9CA3AF")
    static let textMuted = Color(hex: "#6B7280")

    static let selection = Color(hex: "#312E81")
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let r, g, b: UInt64
        switch cleaned.count {
        case 6:
            (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (255, 255, 255)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: 1
        )
    }
}
