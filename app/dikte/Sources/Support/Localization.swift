import Foundation
import Observation

/// App UI language. Independent of the macOS language and switchable at runtime.
enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case tr, en

    var id: String { rawValue }

    /// macOS's first preferred language if it is Turkish, otherwise English.
    static var systemDefault: AppLanguage {
        (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("tr") ? .tr : .en
    }

    /// Name shown in pickers — always written in that language itself.
    var nativeName: String { self == .tr ? "Türkçe" : "English" }

    var locale: Locale { Locale(identifier: self == .tr ? "tr_TR" : "en_US") }
}

/// Runtime UI localization.
///
/// Keys are the Turkish source texts (String Catalog `Resources/Localizable.xcstrings`,
/// source language `tr`). Turkish returns the key itself; English looks it up in `en.lproj`.
/// `string(_:)` reads `language`, so SwiftUI bodies / `withObservationTracking` calls that use
/// `L(...)` re-render automatically when the language changes.
@Observable
final class Localizer {
    static let shared = Localizer()

    var language: AppLanguage = .systemDefault {
        didSet { if language != oldValue { bundle = Self.bundle(for: language) } }
    }

    @ObservationIgnored private var bundle: Bundle?

    private init() {
        bundle = Self.bundle(for: language)
    }

    func string(_ key: String) -> String {
        guard language != .tr, let bundle else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    private static func bundle(for language: AppLanguage) -> Bundle? {
        Bundle.main.path(forResource: language.rawValue, ofType: "lproj").flatMap(Bundle.init(path:))
    }
}

/// Localized UI text. The key is the Turkish text: `Text(L("Dinliyorum…"))`.
func L(_ key: String) -> String {
    Localizer.shared.string(key)
}

/// Localized format string: `L("%@ GB boş", free)`. Numbers are formatted for the UI language.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: Localizer.shared.string(key), locale: Localizer.shared.language.locale,
           arguments: args)
}
