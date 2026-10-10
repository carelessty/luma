import Foundation

/// Shared by AppKit and background services. The selected language is immutable
/// for an app launch, matching macOS's per-application language preference.
enum L10n {
    static let language = resolveLanguage(Locale.preferredLanguages)

    static let resources: Bundle = {
        // SwiftPM's generated accessor also contains a build-directory fallback.
        // Prefer the installed resource bundle so packaged apps are independent
        // of the machine and directory in which they were compiled.
        if let url = Bundle.main.url(forResource: "Luma_Luma", withExtension: "bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()

    private static let bundles: [String: Bundle] = {
        Dictionary(uniqueKeysWithValues: ["en", "zh-Hans"].compactMap { language in
            // SwiftPM normalizes localized resource folder names to lowercase.
            // Match the actual bundle spelling, including on case-sensitive disks.
            guard let folder = resources.localizations.first(where: { $0.caseInsensitiveCompare(language) == .orderedSame }),
                  let url = resources.url(forResource: folder, withExtension: "lproj"),
                  let bundle = Bundle(url: url) else { return nil }
            return (language, bundle)
        })
    }()

    static func resolveLanguage(_ preferences: [String]) -> String {
        for preference in preferences {
            let code = preference.replacingOccurrences(of: "_", with: "-").lowercased()
            if code == "en" || code.hasPrefix("en-") { return "en" }
            if code == "zh" || code.hasPrefix("zh-") { return "zh-Hans" }
        }
        return "en"
    }

    static func string(_ key: String, table: String, language: String = L10n.language) -> String {
        let fallback = bundles["en"]?.localizedString(forKey: key, value: key, table: table) ?? key
        return bundles[language]?.localizedString(forKey: key, value: fallback, table: table) ?? fallback
    }

    private static func formatted(_ key: String, table: String, arguments: [CVarArg]) -> String {
        let template = string(key, table: table)
        guard !arguments.isEmpty else { return template }
        return String(format: template, locale: Locale(identifier: language), arguments: arguments)
    }

    static func ui(_ key: String, _ arguments: CVarArg...) -> String {
        formatted(key, table: "Interface", arguments: arguments)
    }

    static func playback(_ key: String, _ arguments: CVarArg...) -> String {
        formatted(key, table: "Playback", arguments: arguments)
    }

    static func service(_ key: String, _ arguments: CVarArg...) -> String {
        formatted(key, table: "Service", arguments: arguments)
    }
}
