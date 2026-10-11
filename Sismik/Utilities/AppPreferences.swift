import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case turkish
    case english
    case german
    case spanish
    case french
    case italian
    case japanese
    case russian
    case arabic
    case greek
    case portuguese
    case indonesian
    case korean
    case chinese

    var id: String { rawValue }

    /// Uygulama içi dil kodu (sunucuya da bu gider) → paketteki `.lproj` adı.
    /// Kodlar kısa tutulur ("pt", "zh"); paket adı bölge/yazı içerir.
    static let bundleLocalizations: [String: String] = [
        "tr": "tr", "en": "en", "de": "de", "es": "es", "fr": "fr", "it": "it",
        "ja": "ja", "ru": "ru", "ar": "ar", "el": "el", "pt": "pt-BR",
        "id": "id", "ko": "ko", "zh": "zh-Hans"
    ]

    /// `.lproj` adından uygulama koduna ("pt-BR" → "pt", "zh-Hans" → "zh").
    static func code(forLocalization localization: String) -> String? {
        if bundleLocalizations[localization] != nil { return localization }
        return bundleLocalizations.first { $0.value == localization }?.key
            ?? bundleLocalizations.keys.first { localization.hasPrefix($0 + "-") || localization.hasPrefix($0 + "_") }
    }

    var title: String {
        switch self {
        case .system:   return L("settings.language.system")
        case .turkish:  return "Türkçe"
        case .english:  return "English"
        case .german:   return "Deutsch"
        case .spanish:  return "Español"
        case .french:   return "Français"
        case .italian:  return "Italiano"
        case .japanese: return "日本語"
        case .russian:  return "Русский"
        case .arabic:   return "العربية"
        case .greek:    return "Ελληνικά"
        case .portuguese: return "Português (Brasil)"
        case .indonesian: return "Bahasa Indonesia"
        case .korean:   return "한국어"
        case .chinese:  return "简体中文"
        }
    }

    var code: String {
        switch self {
        case .system:
            // Standart iOS davranışı: paketin desteklediği diller arasından
            // kullanıcının tercih ettiği (Ayarlar → Sismik → Dil dahil).
            let preferred = Bundle.main.preferredLocalizations.first ?? "en"
            return Self.code(forLocalization: preferred) ?? "en"
        case .turkish:  return "tr"
        case .english:  return "en"
        case .german:   return "de"
        case .spanish:  return "es"
        case .french:   return "fr"
        case .italian:  return "it"
        case .japanese: return "ja"
        case .russian:  return "ru"
        case .arabic:   return "ar"
        case .greek:    return "el"
        case .portuguese: return "pt"
        case .indonesian: return "id"
        case .korean:   return "ko"
        case .chinese:  return "zh"
        }
    }

    var localeIdentifier: String {
        switch self {
        case .system:   return Locale.current.identifier
        case .turkish:  return "tr_TR"
        case .english:  return "en_US"
        case .german:   return "de_DE"
        case .spanish:  return "es_ES"
        case .french:   return "fr_FR"
        case .italian:  return "it_IT"
        case .japanese: return "ja_JP"
        case .russian:  return "ru_RU"
        case .arabic:   return "ar_SA"
        case .greek:    return "el_GR"
        case .portuguese: return "pt_BR"
        case .indonesian: return "id_ID"
        case .korean:   return "ko_KR"
        case .chinese:  return "zh_Hans_CN"
        }
    }

    var layoutDirection: LayoutDirection {
        Locale.Language(identifier: code).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }

    static var current: AppLanguage {
        let raw = UserDefaults.standard.string(forKey: "appLanguage") ?? ""
        return AppLanguage(rawValue: raw) ?? .system
    }

    /// Etkin dilin kodunu (tr, en, de, es, fr, it, ja, ru, ar, el, pt, id, ko, zh) döndürür.
    static var currentLanguageCode: String {
        current.code
    }

    /// Etkin dilin Türkçe olup olmadığını çözer (geriye dönük uyumluluk).
    static var isTurkish: Bool {
        currentLanguageCode == "tr"
    }

}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L("settings.appearance.system")
        case .light:  return L("settings.appearance.light")
        case .dark:   return L("settings.appearance.dark")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}


/// `Locale(identifier:)` her çağrıda ICU tarafında yeni bir nesne kurar.
/// Oynatma paneli, liste satırları ve teknik kart gibi saniyede onlarca kez
/// değerlendirilen gövdelerde bu ölçülebilir bir maliyet. Eşleme saf olduğu
/// (aynı kimlik → aynı locale) ve dil kümesi dokuz öğeyle sınırlı olduğu için
/// önbelleğin geçersiz kılınması gerekmez ve sınırsız büyümez.
private nonisolated(unsafe) var cachedLocales: [String: Locale] = [:]
private let localeLock = NSLock()

extension AppLanguage {
    /// Kimliğe göre bellekte tutulan `Locale`.
    static func locale(for identifier: String) -> Locale {
        localeLock.lock()
        defer { localeLock.unlock() }
        if let cached = cachedLocales[identifier] { return cached }
        let locale = Locale(identifier: identifier)
        cachedLocales[identifier] = locale
        return locale
    }

    /// Seçili dilin `Locale`'i.
    static var currentLocale: Locale { locale(for: current.localeIdentifier) }
}

/// Uygulama metinleri: `AppStrings.xcstrings` (String Catalog) derlemede her
/// dil için `<dil>.lproj/AppStrings.strings` olur ve Apple'ın standart
/// `Bundle.localizedString` yoluyla okunur. Uygulama içi dil seçimi, seçilen
/// dilin `.lproj` paketi açılarak uygulanır; "Sistem" seçiliyken iOS'un
/// dil tercihleri (Ayarlar → Sismik → Dil dahil) geçerlidir.
///
/// Eksik çeviride sıra: seçili dil → İngilizce → Türkçe → anahtarın kendisi.
final class TranslationStore: @unchecked Sendable {
    static let shared = TranslationStore()

    static let table = "AppStrings"
    private static let missing = "\u{0}__missing__"

    private var bundles: [String: Bundle] = [:]
    private let lock = NSLock()

    private init() {}

    private func bundle(for code: String) -> Bundle? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = bundles[code] { return cached }
        let name = AppLanguage.bundleLocalizations[code] ?? code
        guard let path = Bundle.main.path(forResource: name, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        bundles[code] = bundle
        return bundle
    }

    func translate(_ key: String, lang: String) -> String {
        for code in [lang, "en", "tr"] {
            guard let bundle = bundle(for: code) else { continue }
            let value = bundle.localizedString(forKey: key, value: Self.missing, table: Self.table)
            if value != Self.missing { return value }
        }
        return key
    }
}

/// Tüm dillerde anında ve gecikmesiz yerelleştirilmiş metin döndürür.
func L(_ key: String) -> String {
    let code = AppLanguage.currentLanguageCode
    return TranslationStore.shared.translate(key, lang: code)
}

/// Format argümanlarıyla yerelleştirilmiş metin döndürür.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = L(key)
    return String(format: format, locale: AppLanguage.currentLocale, arguments: args)
}

extension String {
    /// Pratik kullanım: `"key".localized`
    var localized: String {
        L(self)
    }

    /// Pratik format kullanımı: `"key".localized(arg1, arg2)`
    func localized(with arguments: CVarArg...) -> String {
        let format = L(self)
        return String(format: format, locale: AppLanguage.currentLocale, arguments: arguments)
    }
}
