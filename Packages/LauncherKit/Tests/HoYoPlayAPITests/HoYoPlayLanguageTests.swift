// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import HoYoPlayAPI

@Test(arguments: [
    ("en", HoYoPlayLanguage.enUS), ("en-GB", .enUS), ("ru", .ruRU), ("ru-RU", .ruRU),
    ("zh-Hans", .zhCN), ("zh-CN", .zhCN), ("zh", .zhCN), ("zh-Hant", .zhTW), ("zh-TW", .zhTW), ("zh-HK", .zhTW),
    ("zh-Hant-HK", .zhTW), ("zh-Hans-HK", .zhCN), ("ja", .jaJP), ("ko-KR", .koKR), ("de", .deDE), ("fr-CA", .frFR),
    ("es-419", .esES), ("pt-BR", .ptPT), ("pt-PT", .ptPT), ("id", .idID), ("th", .thTH), ("vi", .viVN),
])
func localizationMapsToHoYoPlayLanguage(_ localization: String, _ expected: HoYoPlayLanguage) {
    #expect(HoYoPlayLanguage(localization: localization) == expected)
}

@Test
func unsupportedLocalizationsFallBackToEnglish() {
    #expect(HoYoPlayLanguage(localization: "uk") == nil)
    #expect(HoYoPlayLanguage(localization: "Base") == nil)
    #expect(HoYoPlayLanguage.preferred(["uk", "pl", "ru", "en"]) == .ruRU)
    #expect(HoYoPlayLanguage.preferred(["uk", "pl"]) == .enUS)
    #expect(HoYoPlayLanguage.preferred([]) == .enUS)
}

@Test
func everyLanguageCodeIsLowercaseLanguageAndRegion() {
    #expect(HoYoPlayLanguage.allCases.map(\.rawValue).sorted() == ["de-de", "en-us", "es-es", "fr-fr", "id-id", "ja-jp", "ko-kr",
        "pt-pt", "ru-ru", "th-th", "vi-vn", "zh-cn", "zh-tw"])
}

@Test(arguments: HoYoPlayLanguage.allCases)
func apiURLsCarryTheLanguage(_ language: HoYoPlayLanguage) throws {
    let urls = GameArtService.apiURLs(language: language)
    for (url, path) in [(urls.games, "/hyp/hyp-connect/api/getGames"), (urls.basic, "/hyp/hyp-connect/api/getAllGameBasicInfo")] {
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https" && components.host == "sg-hyp-api.hoyoverse.com" && components.path == path)
        #expect(components.queryItems == [URLQueryItem(name: "launcher_id", value: "VYTpXlbWo8"),
            URLQueryItem(name: "language", value: language.rawValue)])
    }
}

@Test
func defaultURLsAreUnchangedEnglish() {
    let urls = GameArtService.apiURLs(language: .enUS)
    #expect(urls.games.absoluteString == "https://sg-hyp-api.hoyoverse.com/hyp/hyp-connect/api/getGames?launcher_id=VYTpXlbWo8&language=en-us")
    #expect(urls.basic.absoluteString == "https://sg-hyp-api.hoyoverse.com/hyp/hyp-connect/api/getAllGameBasicInfo?launcher_id=VYTpXlbWo8&language=en-us")
}
