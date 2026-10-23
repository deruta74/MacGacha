// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation

/// A content language HoYoPlay serves art and news in, as its `language=` query value.
public enum HoYoPlayLanguage: String, CaseIterable, Sendable, Codable {
    case enUS = "en-us", ruRU = "ru-ru", zhCN = "zh-cn", zhTW = "zh-tw", jaJP = "ja-jp", koKR = "ko-kr"
    case deDE = "de-de", frFR = "fr-fr", esES = "es-es", ptPT = "pt-pt", idID = "id-id", thTH = "th-th", viVN = "vi-vn"

    /// The HoYoPlay language for one localization identifier such as `ru`, `zh-Hant` or `pt-BR`, if it serves one.
    public init?(localization: String) {
        let language = Locale.Language(identifier: localization)
        switch language.languageCode?.identifier {
        case "en": self = .enUS
        case "ru": self = .ruRU
        case "zh":
            // Traditional script, or a region that writes it, gets zh-tw; everything else simplified.
            let traditional = language.script?.identifier == "Hant"
                || (language.script == nil && ["TW", "HK", "MO"].contains(language.region?.identifier ?? ""))
            self = traditional ? .zhTW : .zhCN
        case "ja": self = .jaJP
        case "ko": self = .koKR
        case "de": self = .deDE
        case "fr": self = .frFR
        case "es": self = .esES
        case "pt": self = .ptPT
        case "id": self = .idID
        case "th": self = .thTH
        case "vi": self = .viVN
        default: return nil
        }
    }

    /// The first of `localizations` (most preferred first, as in `Bundle.preferredLocalizations`)
    /// HoYoPlay serves, or English.
    public static func preferred(_ localizations: [String]) -> Self {
        localizations.lazy.compactMap(Self.init(localization:)).first ?? .enUS
    }
}
