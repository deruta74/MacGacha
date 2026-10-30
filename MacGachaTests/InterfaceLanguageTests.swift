// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import HoYoPlayAPI
@testable import MacGacha

@Suite @MainActor struct InterfaceLanguageTests {
    @Test func storesAndClearsInTheAppDomainOnly() throws {
        let domain = "lang-\(UUID())", defaults = UserDefaults.standard
        defer { defaults.removePersistentDomain(forName: domain) }
        let before = defaults.persistentDomain(forName: UserDefaults.globalDomain)
        let settings = InterfaceLanguageSettings(appDomain: domain, defaults: defaults, globalLanguages: { ["en"] }, running: "en")
        settings.select(.uk)
        #expect(defaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String] == ["uk"])
        settings.select(nil)
        #expect(defaults.persistentDomain(forName: domain)?["AppleLanguages"] == nil)
        #expect(NSDictionary(dictionary: before ?? [:]).isEqual(to: defaults.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]))
    }
    @Test func normalizesScriptsAndRegions() {
        for id in ["zh-Hant-TW", "zh-Hant-HK", "zh-MO", "zh-TW"] { #expect(InterfaceLanguage(localization: id) == .zhHant) }
        for id in ["zh-Hans-HK", "zh-Hans-CN", "zh"] { #expect(InterfaceLanguage(localization: id) == .zhHans) }
        for id in ["pt-BR", "pt-PT"] { #expect(InterfaceLanguage(localization: id) == .pt) }
        #expect(InterfaceLanguage(localization: "es-419") == .es)
        #expect(InterfaceLanguage(localization: "it") == nil)
        #expect(InterfaceLanguage.allCases.count == 14)
    }
    @Test func systemResolvesFromGlobalLanguages() {
        let domain = "lang-\(UUID())", defaults = UserDefaults.standard
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = InterfaceLanguageSettings(appDomain: domain, defaults: defaults, globalLanguages: { ["it", "de"] }, running: "de")
        #expect(settings.selection == nil && settings.effective == "de" && !settings.needsRestart)
    }
    @Test func unsupportedOverrideReadsAsSystem() {
        let domain = "lang-\(UUID())", defaults = UserDefaults.standard
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.setPersistentDomain(["AppleLanguages": ["it"]], forName: domain)
        let settings = InterfaceLanguageSettings(appDomain: domain, defaults: defaults, globalLanguages: { ["de"] }, running: "en")
        #expect(settings.selection == nil && settings.effective == "de" && settings.needsRestart)
        defaults.setPersistentDomain(["AppleLanguages": ["ja"]], forName: domain)
        settings.reload()
        #expect(settings.selection == .ja && settings.effective == "ja")
    }
    @Test func ukrainianInterfaceGetsEnglishContent() {
        #expect(HoYoPlayLanguage.content(forInterface: "uk") == .enUS)
        #expect(HoYoPlayLanguage.content(forInterface: "ru") == .ruRU)
        #expect(HoYoPlayLanguage.content(forInterface: "zh-Hant") == .zhTW)
        #expect(HoYoPlayLanguage.content(forInterface: "it") == .enUS)
    }
}
