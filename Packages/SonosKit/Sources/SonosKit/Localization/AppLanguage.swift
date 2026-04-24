import Foundation

public enum AppLanguage: String, CaseIterable {
    case english = "en"
    case german = "de"
    case french = "fr"
    case dutch = "nl"
    case spanish = "es"
    case italian = "it"
    case swedish = "sv"
    case norwegian = "nb"
    case danish = "da"
    case japanese = "ja"
    case portuguese = "pt"
    case polish = "pl"
    case chineseSimplified = "zh-Hans"

    public var displayName: String {
        switch self {
        case .english: return "English"
        case .german: return "Deutsch"
        case .french: return "Fran\u{00E7}ais"
        case .dutch: return "Nederlands"
        case .spanish: return "Espa\u{00F1}ol"
        case .italian: return "Italiano"
        case .swedish: return "Svenska"
        case .norwegian: return "Norsk"
        case .danish: return "Dansk"
        case .japanese: return "\u{65E5}\u{672C}\u{8A9E}"
        case .portuguese: return "Portugu\u{00EA}s"
        case .polish: return "Polski"
        case .chineseSimplified: return "\u{7B80}\u{4F53}\u{4E2D}\u{6587}"
        }
    }

    public var englishName: String {
        switch self {
        case .english: return "English"
        case .german: return "German"
        case .french: return "French"
        case .dutch: return "Dutch"
        case .spanish: return "Spanish"
        case .italian: return "Italian"
        case .swedish: return "Swedish"
        case .norwegian: return "Norwegian"
        case .danish: return "Danish"
        case .japanese: return "Japanese"
        case .portuguese: return "Portuguese"
        case .polish: return "Polish"
        case .chineseSimplified: return "Chinese (Simplified)"
        }
    }

    /// Resolves the user's macOS preferred language to a supported
    /// `AppLanguage`. Walks `Locale.preferredLanguages` in order and returns
    /// the first match; falls back to English. Called once on first launch
    /// so the initial picker selection matches the machine's own setting.
    public static var systemDefault: AppLanguage {
        for preferred in Locale.preferredLanguages {
            let tag = preferred.lowercased()
            // Simplified Chinese: "zh-Hans", "zh-CN", "zh-SG", "zh-Hans-*".
            if tag.hasPrefix("zh") {
                if tag.contains("hans") || tag.contains("cn") || tag.contains("sg") {
                    return .chineseSimplified
                }
                // zh-Hant / zh-TW / zh-HK have no supported match — try next.
                continue
            }
            // Norwegian variants: "nb", "nn", "no".
            if tag.hasPrefix("nb") || tag.hasPrefix("nn") || tag.hasPrefix("no") {
                return .norwegian
            }
            let primary = String(tag.prefix(2))
            if let match = AppLanguage(rawValue: primary) {
                return match
            }
        }
        return .english
    }
}
