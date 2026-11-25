// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).

/// The Global HoYoPlay roster, in publisher order. Raw values are durable edition IDs.
public enum HonkaiImpactServer: String, CaseIterable, Sendable, Hashable {
    case europeAmericas = "hi3"
    case japan = "hi3-jp"
    case korea = "hi3-kr"
    case southeastAsia = "hi3-sea"
    case traditionalChinese = "hi3-tw"

    public var gameID: String {
        switch self {
        case .europeAmericas: "5TIVvvcwtM"
        case .japan: "g0mMIvshDb"
        case .korea: "uxB4MC7nzC"
        case .southeastAsia: "bxPTXSET5t"
        case .traditionalChinese: "wkE5P5WsIf"
        }
    }

    public var packageName: String {
        switch self {
        case .europeAmericas: "glb_official"
        case .japan: "jp_official"
        case .korea: "kr_official"
        case .southeastAsia: "overseas_official"
        case .traditionalChinese: "asia_official"
        }
    }

    public var englishDescription: String {
        switch self {
        case .europeAmericas: "Europe & Americas Servers"
        case .japan: "JP Server"
        case .korea: "KR Server"
        case .southeastAsia: "SEA Server"
        case .traditionalChinese: "Traditional Chinese Server"
        }
    }

    var installDirectoryName: String {
        switch self {
        case .europeAmericas: "Honkai Impact 3rd"
        case .japan: "Houkai3rd"
        case .korea: "Honkai Impact 3rd kr"
        case .southeastAsia: "Honkai Impact 3"
        case .traditionalChinese: "Honkai Impact 3rd asia"
        }
    }

    var unityLogProductName: String {
        switch self {
        case .europeAmericas: "Honkai Impact 3rd"
        case .japan, .traditionalChinese: "崩壊3rd"
        case .korea: "붕괴3rd"
        case .southeastAsia: "Honkai Impact 3"
        }
    }

    public var deliveryHost: String {
        switch self {
        case .europeAmericas: "autopatchglb.honkaiimpact3.com"
        case .japan: "autopatchjp.honkaiimpact3.com"
        case .korea: "autopatchkr.honkaiimpact3.com"
        case .southeastAsia: "autopatchos.honkaiimpact3.com"
        case .traditionalChinese: "autopatchasia.honkaiimpact3.com"
        }
    }

    var definition: GameDefinition {
        GameDefinition(id: rawValue, biz: "bh3_global", gameID: gameID, voices: [], family: .honkaiImpact)
    }
}
