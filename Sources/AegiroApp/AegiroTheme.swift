import SwiftUI

enum AegiroPalette {
    static let iceBlue = Color(hex: "#8ECAE6")
    static let tealBlue = Color(hex: "#219EBC")
    static let deepNavy = Color(hex: "#023047")
    static let sunYellow = Color(hex: "#FFB703")
    static let orange = Color(hex: "#FB8500")
    static let primaryBlue = Color(hex: "#219EBC")
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
