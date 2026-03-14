import Foundation
import SwiftUI

struct PassphraseStrengthReport {
    let length: Int
    let hasLowercase: Bool
    let hasUppercase: Bool
    let hasDigit: Bool
    let hasSymbol: Bool
    let categoryCount: Int
    let score: Int
    let isRequired: Bool
    let isStrong: Bool

    var label: String {
        switch score {
        case 0:
            return "Enter passphrase"
        case 1:
            return "Very weak"
        case 2:
            return "Weak"
        case 3:
            return "Fair"
        case 4:
            return "Good"
        default:
            return "Strong"
        }
    }

    var color: Color {
        switch score {
        case 0:
            return AegiroPalette.textMuted
        case 1:
            return AegiroPalette.dangerRed
        case 2:
            return AegiroPalette.warningAmber
        case 3:
            return AegiroPalette.accentIndigo
        case 4:
            return Color(hex: "#22C55E")
        default:
            return AegiroPalette.securityGreen
        }
    }

    static func evaluate(_ passphrase: String) -> PassphraseStrengthReport {
        let length = passphrase.count
        let hasLowercase = passphrase.rangeOfCharacter(from: .lowercaseLetters) != nil
        let hasUppercase = passphrase.rangeOfCharacter(from: .uppercaseLetters) != nil
        let hasDigit = passphrase.rangeOfCharacter(from: .decimalDigits) != nil
        let symbols = CharacterSet.punctuationCharacters.union(.symbols)
        let hasSymbol = passphrase.rangeOfCharacter(from: symbols) != nil

        let categories = [hasLowercase, hasUppercase, hasDigit, hasSymbol]
        let categoryCount = categories.filter { $0 }.count
        let isRequired = length >= 8 && hasLowercase && hasUppercase && hasDigit
        let isStrong = length >= 20 || (length >= 12 && categoryCount >= 3)

        var score = 0
        if length >= 4 { score += 1 }
        if length >= 8 { score += 1 }
        if hasLowercase && hasUppercase { score += 1 }
        if hasDigit { score += 1 }
        if hasSymbol { score += 1 }

        if isStrong {
            score = 5
        } else {
            score = min(score, 4)
        }
        score = max(0, min(5, score))

        return PassphraseStrengthReport(length: length,
                                        hasLowercase: hasLowercase,
                                        hasUppercase: hasUppercase,
                                        hasDigit: hasDigit,
                                        hasSymbol: hasSymbol,
                                        categoryCount: categoryCount,
                                        score: score,
                                        isRequired: isRequired,
                                        isStrong: isStrong)
    }
}

struct PassphraseStrengthMeter: View {
    let passphrase: String

    private var report: PassphraseStrengthReport {
        PassphraseStrengthReport.evaluate(passphrase)
    }

    private var progress: CGFloat {
        CGFloat(report.score) / 5.0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Strength")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AegiroPalette.textSecondary)
                Spacer()
                Text(report.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(report.color)
            }

            GeometryReader { proxy in
                let totalWidth = max(0, proxy.size.width)
                let fillWidth = totalWidth * progress
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(AegiroPalette.borderSubtle.opacity(0.62))
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(colors: [report.color.opacity(0.72), report.color],
                                           startPoint: .leading,
                                           endPoint: .trailing)
                        )
                        .frame(width: fillWidth)
                }
            }
            .frame(height: 10)

            HStack(spacing: 8) {
                requirementTag("8+ chars", met: report.length >= 8)
                requirementTag("upper + lower", met: report.hasUppercase && report.hasLowercase)
                requirementTag("number", met: report.hasDigit)
            }

            Text("Strong: 12+ chars with 3+ character types, or 20+ chars.")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(AegiroPalette.textMuted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AegiroPalette.backgroundCard.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AegiroPalette.borderSubtle.opacity(0.8), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.18), value: report.score)
        .animation(.easeInOut(duration: 0.18), value: passphrase)
    }

    private func requirementTag(_ title: String, met: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: met ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background((met ? AegiroPalette.securityGreen : AegiroPalette.textMuted).opacity(0.16), in: Capsule())
        .foregroundStyle(met ? AegiroPalette.securityGreen : AegiroPalette.textMuted)
    }
}
