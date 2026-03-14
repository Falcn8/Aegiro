import SwiftUI
import Foundation
#if os(macOS)
import AppKit
import CoreText
#endif

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
    private static let displayCandidates = ["Fraunces-Regular", "Fraunces", "Fraunces 72pt", "Fraunces 9pt", "Fraunces Variable"]
    private static let bodyCandidates = ["SpaceGrotesk-Regular", "Space Grotesk", "SpaceGrotesk", "SpaceGrotesk-Light_Regular"]
    private static let monoCandidates = ["JetBrainsMono-Regular", "JetBrains Mono", "JetBrainsMono"]

    static func display(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        resolvedFont(candidates: displayCandidates, size: size, weight: weight, relativeTo: textStyle)
    }

    static func body(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        resolvedFont(candidates: bodyCandidates, size: size, weight: weight, relativeTo: textStyle)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        resolvedFont(candidates: monoCandidates, size: size, weight: weight, relativeTo: textStyle)
    }

    private static func resolvedFont(candidates: [String], size: CGFloat, weight: Font.Weight, relativeTo textStyle: Font.TextStyle) -> Font {
        if let name = firstInstalledFontName(in: candidates) {
            return .custom(name, size: size, relativeTo: textStyle).weight(weight)
        }
        return .system(size: size, weight: weight)
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
