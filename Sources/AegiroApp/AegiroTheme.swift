import SwiftUI
import Foundation
#if os(macOS)
import AppKit
import CoreText
#endif

enum AegiroPalette {
    static let accentIndigo = Color(hex: "#8F56FF")
    static let accentSub = Color(hex: "#FF69C5")
    static let securityGreen = Color(hex: "#10B981")
    static let warningAmber = Color(hex: "#F59E0B")
    static let dangerRed = Color(hex: "#EF4444")

    static let backgroundMain = Color(hex: "#1A1A1A")
    static let backgroundPanel = Color(hex: "#1A1A1A")
    static let backgroundCard = Color(hex: "#1A1A1A")
    static let borderSubtle = Color(hex: "#8F56FF").opacity(0.45)

    static let textPrimary = Color(hex: "#DAE1EB")
    static let textSecondary = Color(hex: "#DAE1EB").opacity(0.88)
    static let textMuted = Color(hex: "#DAE1EB").opacity(0.68)

    static let selection = Color(hex: "#FF69C5")
}

enum AegiroResourceLocator {
    #if os(macOS)
    private static let appBundleName = "Aegiro_AegiroApp.bundle"
    private static let cachedBundle: Bundle = locateResourceBundle() ?? .main
    #endif

    static var resourceBundle: Bundle {
        #if os(macOS)
        return cachedBundle
        #else
        return .main
        #endif
    }

    #if os(macOS)
    static func image(named name: String, ext: String = "png") -> NSImage? {
        let bundle = cachedBundle
        if let image = bundle.image(forResource: NSImage.Name(name)) {
            return image
        }
        if let url = bundle.url(forResource: name, withExtension: ext),
           let image = NSImage(contentsOf: url) {
            return image
        }
        if let url = Bundle.main.url(forResource: name, withExtension: ext),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return nil
    }

    private static func locateResourceBundle() -> Bundle? {
        for candidate in candidateBundleURLs() {
            if let bundle = Bundle(url: candidate) {
                return bundle
            }
        }
        return nil
    }

    private static func candidateBundleURLs() -> [URL] {
        var results = [URL]()
        var seen = Set<String>()

        func append(_ url: URL?) {
            guard let url else { return }
            let key = url.standardizedFileURL.path
            guard !seen.contains(key) else { return }
            seen.insert(key)
            results.append(url)
        }

        let mainBundle = Bundle.main
        append(mainBundle.resourceURL?.appendingPathComponent(appBundleName, isDirectory: true))
        append(mainBundle.bundleURL.appendingPathComponent(appBundleName, isDirectory: true))
        append(mainBundle.bundleURL.appendingPathComponent("Contents/Resources/\(appBundleName)", isDirectory: true))
        append(mainBundle.executableURL?.deletingLastPathComponent().appendingPathComponent(appBundleName, isDirectory: true))
        return results
    }
    #endif
}

enum AegiroFontRegistry {
    #if os(macOS)
    private static var didRegister = false
    private static var registeredByFamily: [String: [String]] = [:]
    #endif

    static func registerBundledFonts() {
        #if os(macOS)
        guard !didRegister else { return }
        didRegister = true

        let fontURLs = bundledFontURLs()
        for fontURL in fontURLs {
            registerFont(at: fontURL)
        }
        #endif
    }

    static func firstRegisteredPostScriptName(matching candidates: [String]) -> String? {
        #if os(macOS)
        for candidate in candidates {
            if let names = registeredByFamily[candidate],
               let resolved = names.first(where: { NSFont(name: $0, size: 12) != nil }) {
                return resolved
            }
            if let resolved = caseInsensitiveMatch(for: candidate) {
                return resolved
            }
        }
        #endif
        return nil
    }

    #if os(macOS)
    private static func bundledFontURLs() -> [URL] {
        let bundle = AegiroResourceLocator.resourceBundle
        var urls = [URL]()
        urls.append(contentsOf: bundle.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
        urls.append(contentsOf: bundle.urls(forResourcesWithExtension: "otf", subdirectory: "Fonts") ?? [])
        urls.append(contentsOf: bundle.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
        urls.append(contentsOf: bundle.urls(forResourcesWithExtension: "otf", subdirectory: nil) ?? [])
        return Array(Set(urls))
    }

    private static func registerFont(at url: URL) {
        var registrationError: Unmanaged<CFError>?
        let didRegisterURL = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &registrationError)
        if !didRegisterURL, registrationError == nil {
            return
        }

        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else {
            return
        }
        for descriptor in descriptors {
            guard let attrs = CTFontDescriptorCopyAttributes(descriptor) as? [CFString: Any],
                  let postScriptName = attrs[kCTFontNameAttribute] as? String else {
                continue
            }
            let family = (attrs[kCTFontFamilyNameAttribute] as? String) ?? postScriptName
            appendFont(postScriptName, to: family)
            appendFont(postScriptName, to: postScriptName)
        }
    }

    private static func appendFont(_ postScriptName: String, to key: String) {
        let existing = registeredByFamily[key] ?? []
        if existing.contains(postScriptName) {
            return
        }
        registeredByFamily[key] = existing + [postScriptName]
    }

    private static func caseInsensitiveMatch(for candidate: String) -> String? {
        for (key, names) in registeredByFamily where key.caseInsensitiveCompare(candidate) == .orderedSame {
            if let resolved = names.first(where: { NSFont(name: $0, size: 12) != nil }) {
                return resolved
            }
        }
        return nil
    }
    #endif
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

enum AegiroTypography {
    static func display(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        resolvedFont(candidates: displayCandidates(for: weight), size: size, weight: weight, relativeTo: textStyle)
    }

    static func body(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        resolvedFont(candidates: bodyCandidates(for: weight), size: size, weight: weight, relativeTo: textStyle)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        resolvedFont(candidates: monoCandidates(for: weight), size: size, weight: weight, relativeTo: textStyle)
    }

    private static func resolvedFont(candidates: [String], size: CGFloat, weight: Font.Weight, relativeTo textStyle: Font.TextStyle) -> Font {
        if let name = firstInstalledFontName(in: candidates) {
            return .custom(name, size: size, relativeTo: textStyle)
        }
        return .system(size: size, weight: weight)
    }

    private static func displayCandidates(for weight: Font.Weight) -> [String] {
        switch weightBucket(weight) {
        case .light:
            return ["Fraunces-Light", "Fraunces-Regular", "Fraunces"]
        case .regular:
            return ["Fraunces-Regular", "Fraunces"]
        case .medium:
            return ["Fraunces-SemiBold", "Fraunces-Bold", "Fraunces-Regular", "Fraunces"]
        case .bold:
            return ["Fraunces-Bold", "Fraunces-9ptBlack", "Fraunces-SemiBold", "Fraunces-Regular", "Fraunces"]
        }
    }

    private static func bodyCandidates(for weight: Font.Weight) -> [String] {
        switch weightBucket(weight) {
        case .light:
            return ["SpaceGrotesk-Light", "SpaceGrotesk-Light_Regular", "SpaceGrotesk-Regular", "Space Grotesk"]
        case .regular:
            return ["SpaceGrotesk-Light_Regular", "SpaceGrotesk-Regular", "Space Grotesk", "SpaceGrotesk-Light"]
        case .medium:
            return ["SpaceGrotesk-Light_Medium", "SpaceGrotesk-Light_Regular", "SpaceGrotesk-Regular", "Space Grotesk"]
        case .bold:
            return ["SpaceGrotesk-Light_Bold", "SpaceGrotesk-Light_Medium", "SpaceGrotesk-Light_Regular", "SpaceGrotesk-Regular", "Space Grotesk"]
        }
    }

    private static func monoCandidates(for weight: Font.Weight) -> [String] {
        switch weightBucket(weight) {
        case .light:
            return ["JetBrainsMono-Regular_Light", "JetBrainsMono-Regular_ExtraLight", "JetBrainsMono-Regular_Thin", "JetBrainsMono-Regular", "JetBrains Mono"]
        case .regular:
            return ["JetBrainsMono-Regular", "JetBrains Mono", "JetBrainsMono"]
        case .medium:
            return ["JetBrainsMono-Regular_Medium", "JetBrainsMono-Regular", "JetBrains Mono", "JetBrainsMono"]
        case .bold:
            return ["JetBrainsMono-Regular_SemiBold", "JetBrainsMono-Regular_Bold", "JetBrainsMono-Regular_ExtraBold", "JetBrainsMono-Regular", "JetBrains Mono", "JetBrainsMono"]
        }
    }

    private enum WeightBucket {
        case light
        case regular
        case medium
        case bold
    }

    private static func weightBucket(_ weight: Font.Weight) -> WeightBucket {
        switch weight {
        case .ultraLight, .thin, .light:
            return .light
        case .medium, .semibold:
            return .medium
        case .bold, .heavy, .black:
            return .bold
        default:
            return .regular
        }
    }

    private static func firstInstalledFontName(in names: [String]) -> String? {
        #if os(macOS)
        for name in names where NSFont(name: name, size: 12) != nil {
            return name
        }
        if let registeredName = AegiroFontRegistry.firstRegisteredPostScriptName(matching: names) {
            return registeredName
        }
        #endif
        return nil
    }
}
