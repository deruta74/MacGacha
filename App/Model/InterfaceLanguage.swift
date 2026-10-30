// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Observation
import HoYoPlayAPI

enum InterfaceLanguage: String, CaseIterable, Identifiable, Sendable {
    case en, zhHans = "zh-Hans", zhHant = "zh-Hant", ja, ko, ru, uk, de, fr, es, pt, id, th, vi
    var id: String { rawValue }
    var endonym: String {
        switch self {
        case .en: "English"
        case .zhHans: "简体中文"
        case .zhHant: "繁體中文"
        case .ja: "日本語"
        case .ko: "한국어"
        case .ru: "Русский"
        case .uk: "Українська"
        case .de: "Deutsch"
        case .fr: "Français"
        case .es: "Español"
        case .pt: "Português"
        case .id: "Bahasa Indonesia" // comment: Language endonyms do not change with the interface.
        case .th: "ไทย"
        case .vi: "Tiếng Việt"
        }
    }
    init?(localization: String) {
        let language = Locale.Language(identifier: localization)
        if language.languageCode?.identifier == "zh" {
            let traditional = language.script?.identifier == "Hant" ||
                (language.script == nil && ["TW", "HK", "MO"].contains(language.region?.identifier ?? ""))
            self = traditional ? .zhHant : .zhHans
        } else {
            guard let code = language.languageCode?.identifier, let value = Self(rawValue: code) else { return nil }
            self = value
        }
    }
}

@MainActor @Observable final class InterfaceLanguageSettings {
    static let runningLocalization = Bundle.main.preferredLocalizations.first ?? "en"
    static var systemName: String { String(localized: "System") }
    private(set) var selection: InterfaceLanguage?
    private let appDomain: String
    private let defaults: UserDefaults
    private let globalLanguages: () -> [String]
    let running: String

    init(appDomain: String = Bundle.main.bundleIdentifier ?? "com.lo7ted.macgacha",
        defaults: UserDefaults = .standard,
        globalLanguages: @escaping () -> [String] = {
            UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String] ?? ["en"]
        }, running: String = InterfaceLanguageSettings.runningLocalization) {
        self.appDomain = appDomain; self.defaults = defaults; self.globalLanguages = globalLanguages
        self.running = InterfaceLanguage(localization: running)?.rawValue ?? "en"
        reload()
    }
    var effective: String {
        selection?.rawValue ?? Bundle.preferredLocalizations(from: InterfaceLanguage.allCases.map(\.rawValue),
            forPreferences: globalLanguages()).first ?? "en"
    }
    var needsRestart: Bool { effective != running }
    func reload() {
        let stored = defaults.persistentDomain(forName: appDomain)?["AppleLanguages"] as? [String]
        selection = stored?.first.flatMap(InterfaceLanguage.init(localization:))
    }
    func select(_ language: InterfaceLanguage?) {
        var domain = defaults.persistentDomain(forName: appDomain) ?? [:]
        if let language { domain["AppleLanguages"] = [language.rawValue] }
        else { domain.removeValue(forKey: "AppleLanguages") }
        defaults.setPersistentDomain(domain, forName: appDomain)
        reload()
    }
}

extension HoYoPlayLanguage {
    static func content(forInterface localization: String) -> Self {
        Self(localization: localization) ?? .enUS
    }
}
