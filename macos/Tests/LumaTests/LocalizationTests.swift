import Foundation
import Testing
@testable import Luma

struct LocalizationTests {
    @Test func resolvesSystemAndPerAppLanguagePreferences() {
        #expect(L10n.resolveLanguage(["en-US", "zh-Hans"]) == "en")
        #expect(L10n.resolveLanguage(["zh_CN", "en"]) == "zh-Hans")
        #expect(L10n.resolveLanguage(["zh-Hant-TW"]) == "zh-Hans")
        #expect(L10n.resolveLanguage(["fr-FR", "zh-Hans"]) == "zh-Hans")
        #expect(L10n.resolveLanguage(["fr-FR"]) == "en")
        #expect(L10n.resolveLanguage([]) == "en")
    }

    @Test func loadsBothLanguagesAndFallsBackToEnglish() {
        #expect(L10n.string("action.play", table: "Interface", language: "en") == "Play")
        #expect(L10n.string("action.play", table: "Interface", language: "zh-Hans") == "播放")
        #expect(L10n.string("action.play", table: "Interface", language: "fr") == "Play")
        #expect(L10n.string("demo.tokyo.title", table: "Service", language: "en") == "Tokyo After Dark")
        #expect(L10n.string("demo.tokyo.title", table: "Service", language: "zh-Hans") == "东京夜行")
    }

    @Test func translationsHaveMatchingKeysAndFormatArguments() throws {
        let pattern = try NSRegularExpression(pattern: #"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h|z)?[@diuoxXfFeEgGcCsSp]"#)
        func formats(_ value: String) -> [String] {
            let text = value.replacingOccurrences(of: "%%", with: "")
            return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .map { (text as NSString).substring(with: $0.range) }
        }
        for table in ["Interface", "Playback", "Service"] {
            func load(_ language: String) throws -> [String: String] {
                let folder = try #require(L10n.resources.localizations.first { $0.caseInsensitiveCompare(language) == .orderedSame })
                let url = try #require(L10n.resources.url(forResource: table, withExtension: "strings", subdirectory: nil, localization: folder))
                let data = try Data(contentsOf: url)
                return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
            }
            let english = try load("en")
            let chinese = try load("zh-Hans")
            #expect(!english.isEmpty)
            #expect(Set(english.keys) == Set(chinese.keys), "Missing translations in \(table)")
            for (key, value) in english {
                let translation = try #require(chinese[key])
                #expect(!value.isEmpty && !translation.isEmpty, "Empty translation: \(table).\(key)")
                #expect(formats(value) == formats(translation), "Format mismatch: \(table).\(key)")
            }
        }
    }
}
