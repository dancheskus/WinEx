import Foundation

/// WinEx's languages. The Russian text in the code is the key; other languages are looked up in
/// a dictionary (English.swift). Settings ▸ Основные ▸ Язык: the system's language (Russian if
/// it's Russian, English otherwise) or a fixed one — applied at the next launch.
enum Localization {
    enum Language: String, CaseIterable {
        case system, ru, en

        /// Shown in its own language, like the system does.
        var title: String {
            switch self {
            case .system: L("Как в системе")
            case .ru: "Русский"
            case .en: "English"
            }
        }
    }

    /// The choice in Settings (takes effect at the next launch).
    static var chosen: Language {
        get { Language(rawValue: AppDefaults.store.string(forKey: "language") ?? "") ?? .system }
        set { AppDefaults.store.set(newValue.rawValue, forKey: "language") }
    }

    /// The language this run speaks (fixed at launch).
    nonisolated(unsafe) private(set) static var isEnglish = false

    /// The system's language, read before WinEx sets its own (after that the system answers
    /// with WinEx's language).
    nonisolated(unsafe) private(set) static var systemIsRussian = Locale.preferredLanguages.first?.hasPrefix("ru") == true

    /// "ru" or "en": what `language` means on this Mac.
    static func resolved(_ language: Language) -> String {
        language == .system ? (systemIsRussian ? "ru" : "en") : language.rawValue
    }

    /// Whether the chosen language differs from the one this run speaks (a restart applies it).
    static var needsRestart: Bool { resolved(chosen) != (isEnglish ? "en" : "ru") }

    /// Called first thing at launch.
    static func start() {
        var language = chosen
        #if DEBUG
        // Scenario runs: WINEX_LANG=en
        if let forced = ProcessInfo.processInfo.environment["WINEX_LANG"].flatMap(Language.init(rawValue:)) { language = forced }
        #endif
        systemIsRussian = Locale.preferredLanguages.first?.hasPrefix("ru") == true
        let resolved = resolved(language)
        isEnglish = resolved == "en"
        if language != .system {
            // AppKit's own texts (standard buttons, panels) and the size units follow it too
            UserDefaults.standard.setVolatileDomain(["AppleLanguages": [resolved]], forName: UserDefaults.argumentDomain)
        }
    }

    /// Dates and numbers in the app's language, with the user's region.
    static var locale: Locale {
        Locale(identifier: (isEnglish ? "en" : "ru") + "_" + (Locale.current.region?.identifier ?? (isEnglish ? "US" : "RU")))
    }
}

/// The text for the app's language.
func L(_ key: String) -> String {
    Localization.isEnglish ? (English.strings[key] ?? key) : key
}

/// A text with values: each "%@" of the key takes the next value, in order.
func L(_ key: String, _ values: Any...) -> String {
    let parts = L(key).components(separatedBy: "%@")
    var result = parts[0]
    for (index, part) in parts.dropFirst().enumerated() {
        result += (index < values.count ? "\(values[index])" : "") + part
    }
    return result
}
