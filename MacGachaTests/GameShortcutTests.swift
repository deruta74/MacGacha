// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import RuntimeManager
@testable import MacGacha

struct GameShortcutTests {
    @Test(arguments: HonkaiImpactServer.allCases)
    func honkaiShortcutIdentitiesRouteToTheExactServer(server: HonkaiImpactServer) throws {
        let url = try #require(GameShortcut.playURL(server.rawValue))
        #expect(GameShortcut.gameID(from: url) == server.rawValue)
    }

    @Test func honkaiShortcutReusesItsDestinationWhenTheDescriptionChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HI3Shortcuts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try GameShortcut.write(gameID: "hi3-jp", name: "Honkai Impact 3rd (JP Server)", icns: nil,
            hostBundleID: "test", hostPath: "/Applications/MacGacha.app", in: directory)
        let updated = try GameShortcut.write(gameID: "hi3-jp", name: "崩壊3rd（日本サーバー）", icns: nil,
            hostBundleID: "test", hostPath: "/Applications/MacGacha.app", in: directory)
        #expect(updated == original)
        let fs = try ContainedFileSystem(root: directory)
        let legacy = try SafeRelativePath("崩壊3rd.app")
        let legacyPlist = try SafeRelativePath("\(legacy)/Contents/Info.plist")
        try fs.writeAtomically(GameShortcut.infoPlist(gameID: "hi3", name: "崩壊3rd", hasIcon: false), to: legacyPlist)
        let migrated = try GameShortcut.write(gameID: "hi3", name: "Honkai Impact 3rd (Europe & Americas Servers)", icns: nil,
            hostBundleID: "test", hostPath: "/Applications/MacGacha.app", in: directory)
        #expect(migrated == legacy.resolved(against: directory))
        #expect(try fs.itemType(at: SafeRelativePath("崩壊3rd（日本サーバー）.app")) == nil)
        #expect(try fs.itemType(at: SafeRelativePath("Honkai Impact 3rd (Europe & Americas Servers).app")) == nil)
        let data = try fs.readFile(at: legacyPlist, maxBytes: 4096)
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["CFBundleDisplayName"] as? String == "Honkai Impact 3rd (Europe & Americas Servers)")
    }

    @Test func acceptsOnlyPlayURLsForKnownGames() throws {
        #expect(GameShortcut.gameID(from: try #require(URL(string: "macgacha://play/genshin"))) == "genshin")
        #expect(GameShortcut.gameID(from: try #require(URL(string: "MacGacha://Play/zzz-cn"))) == "zzz-cn")
        for text in ["macgacha://play/unknown", "macgacha://play/genshin/extra", "macgacha://play/genshin?x=1",
            "macgacha://play/genshin#x", "macgacha://uninstall/genshin", "https://play/genshin", "macgacha://play/"] {
            #expect(GameShortcut.gameID(from: try #require(URL(string: text))) == nil, "\(text)")
        }
        #expect(GameShortcut.playURL("starrail")?.absoluteString == "macgacha://play/starrail")
    }

    @Test func appNamesAvoidFinderSlashes() {
        #expect(GameShortcut.appName(for: "Honkai: Star Rail") == "Honkai Star Rail")
        #expect(GameShortcut.appName(for: "崩坏：星穹铁道") == "崩坏：星穹铁道")
        #expect(GameShortcut.appName(for: " / ") == "MacGacha Game")
    }

    @Test func writesAndReplacesItsOwnShortcutOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Shortcuts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let icns = Data("icns synthetic".utf8)
        let app = try GameShortcut.write(gameID: "starrail", name: "Honkai: Star Rail", icns: icns,
            hostBundleID: "com.lo7ted.macgacha", hostPath: "/Applications/Mac'Gacha.app", in: directory)
        #expect(app.lastPathComponent == "Honkai Star Rail.app")
        let plistData = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        #expect(plist["CFBundleIdentifier"] as? String == "com.lo7ted.macgacha.shortcut.starrail")
        #expect(plist["MacGachaGameID"] as? String == "starrail")
        #expect(plist["CFBundleIconFile"] as? String == "AppIcon")
        #expect(plist["LSUIElement"] as? Bool == true)
        let script = app.appendingPathComponent("Contents/MacOS/launch")
        let attributes = try FileManager.default.attributesOfItem(atPath: script.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o755)
        let text = try String(contentsOf: script, encoding: .utf8)
        #expect(text.hasPrefix("#!/bin/sh\n"))
        #expect(text.contains("url='macgacha://play/starrail'"))
        #expect(text.contains("if [ -d '/Applications/Mac'\\''Gacha.app' ]; then"))
        #expect(text.contains("exec /usr/bin/open -a '/Applications/Mac'\\''Gacha.app' \"$url\" --args --macgacha-shortcut"))
        #expect(text.contains("exec /usr/bin/open -b 'com.lo7ted.macgacha' \"$url\" --args --macgacha-shortcut"))
        #expect(try Data(contentsOf: app.appendingPathComponent("Contents/Resources/AppIcon.icns")) == icns)

        // Writing again replaces the earlier shortcut in place, without the icon this time.
        let again = try GameShortcut.write(gameID: "starrail", name: "Honkai: Star Rail", icns: nil,
            hostBundleID: "com.lo7ted.macgacha", hostPath: "/Applications/Mac'Gacha.app", in: directory)
        #expect(again == app)
        #expect(!FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Resources/AppIcon.icns").path))

        // Another app with the game's name is left alone.
        let foreign = directory.appendingPathComponent("Genshin Impact.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("not ours".utf8).write(to: foreign.appendingPathComponent("marker"))
        let separate = try GameShortcut.write(gameID: "genshin", name: "Genshin Impact", icns: nil,
            hostBundleID: "com.lo7ted.macgacha", hostPath: "/Applications/Mac'Gacha.app", in: directory)
        #expect(separate.lastPathComponent == "Genshin Impact (MacGacha).app")
        #expect(try Data(contentsOf: foreign.appendingPathComponent("marker")) == Data("not ours".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty)
    }
}

@MainActor struct GameShortcutModelTests {
    private func model(hidden: Bool, reveals: @escaping @MainActor () -> Void) -> AppModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacGachaTests-\(UUID().uuidString)")
        return AppModel(paths: AppPaths(root: root), manifest: try? RuntimeManifest(components: []),
            services: FakeRuntimeServices(), defaults: nil, notificationReveal: reveals,
            launchArguments: hidden ? ["MacGacha", GameShortcut.launchArgument] : ["MacGacha"])
    }

    @Test func shortcutForAGameThatCantPlayOpensTheLauncherOnIt() async {
        var reveals = 0
        let model = model(hidden: true) { reveals += 1 }
        #expect(model.launchedHidden)
        await model.start()
        await model.playFromShortcut("zzz")
        #expect(!model.launchedHidden)
        #expect(model.notificationSelection?.gameID == "zzz")
        #expect(reveals == 1)
    }

    @Test func otherURLsDoNothing() async {
        var reveals = 0
        let model = model(hidden: true) { reveals += 1 }
        model.openShortcutURL(URL(string: "macgacha://uninstall/genshin")!)
        #expect(model.shortcutTask == nil)
        #expect(model.launchedHidden)
        #expect(reveals == 0)
    }

    @Test func honkaiShortcutRevealsTheExactServer() async {
        let model = model(hidden: true) {}
        await model.start()
        await model.playFromShortcut("hi3-sea")
        #expect(model.notificationSelection?.gameID == "hi3-sea")
        #expect(model.selectedHonkaiServer == .southeastAsia)
    }

    @Test func errorsOpenAHiddenLauncher() {
        var reveals = 0
        let model = model(hidden: true) { reveals += 1 }
        model.show(LauncherError.busy("test"))
        #expect(!model.launchedHidden)
        #expect(reveals == 1)
        #expect(model.lastError != nil)
    }

    @Test func ordinaryLaunchIsNotHidden() {
        #expect(!model(hidden: false) {}.launchedHidden)
    }
}
