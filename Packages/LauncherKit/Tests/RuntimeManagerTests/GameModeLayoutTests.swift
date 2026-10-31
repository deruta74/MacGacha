// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import Launch
import TestSupport
@testable import RuntimeManager

private struct LayoutRegistration: GameModeRegistering { func register(_ app: URL) throws {} }

@Suite(.timeLimit(.minutes(1))) struct GameModeLayoutTests {
    @Test(arguments: GameDefinition.all) func perEditionMetadataAndChildLoaderLayout(game: GameDefinition) async throws {
        let f = try BundleFixture(), bundle = try await gameModeTestBundle(f)
        let icons = try FixedGameModeIcon()
        let manager = GameModeHelper(paths: f.store.paths, icons: icons, registration: LayoutRegistration())
        let helper = try await manager.prepare(bundle: bundle, game: game, componentIDs: f.bundle.components.map(\.rawValue))
        let names = ["genshin": "Genshin Impact", "starrail": "Honkai: Star Rail", "zzz": "Zenless Zone Zero",
            "genshin-cn": "原神", "starrail-cn": "崩坏：星穹铁道", "zzz-cn": "绝区零"]
        #expect(game.gameApplicationName == names[game.id])
        #expect(helper.root.path.contains("/\(game.id)/\(game.gameApplicationName).app/Contents"))
        #expect(helper.wineBinary.lastPathComponent == "wine-wrapper")
        #expect(helper.loader.lastPathComponent == "wine")
        #expect(helper.wineserver.path.hasSuffix("Contents/bin/wineserver"))
        let fs = try ContainedFileSystem(root: f.store.paths.root)
        let root = try RuntimeJSONFile.relativePath(helper.root, root: f.store.paths.root)
        let source = try RuntimeJSONFile.relativePath(bundle.root, root: f.store.paths.root)
        for name in ["wine", "ntdll.so", "driver.so"] {
            #expect(try fs.regularFileIdentity(at: SafeRelativePath("\(root)/MacOS/\(name)")) == fs.regularFileIdentity(at: SafeRelativePath("\(source)/lib/wine/x86_64-unix/\(name)")))
        }
        #expect(try fs.regularFileIdentity(at: SafeRelativePath("\(root)/MacOS/wine.real")) == fs.regularFileIdentity(at: SafeRelativePath("\(source)/lib/wine/x86_64-unix/wine")))
        #expect(try fs.regularFileIdentity(at: SafeRelativePath("\(root)/MacOS/wine.real")) != fs.regularFileIdentity(at: SafeRelativePath("\(source)/bin/wine.real")))
        let links = Dictionary(uniqueKeysWithValues: try fs.inspectTree(at: SafeRelativePath(root.components.dropLast().joined(separator: "/")), allowingExternalHardLinks: true).compactMap { entry in entry.linkTarget.map { (entry.path.description, $0) } })
        #expect(links["Contents/MacOS/driver-alias.so"] == "../lib/wine/x86_64-unix/driver.so")
        #expect(links["Contents/MacOS/x86_64-windows"] == "../lib/wine/x86_64-windows")
        #expect(links["Contents/MacOS/x86_64-unix"] == ".")
        for name in ["bin", "lib", "share"] { #expect(links[name] == "Contents/\(name)") }
        let plist = try #require(try PropertyListSerialization.propertyList(from: fs.readFile(at: SafeRelativePath("\(root)/Info.plist"), maxBytes: 16384), format: nil) as? [String: Any])
        #expect(plist["CFBundleIdentifier"] as? String == "com.lo7ted.macgacha.game.\(game.id)")
        #expect(plist["CFBundleName"] as? String == game.gameApplicationName)
        #expect(plist["CFBundleDisplayName"] as? String == game.gameApplicationName)
        for key in ["CFBundleShortVersionString", "CFBundleVersion", "CFBundleInfoDictionaryVersion", "CFBundleIconName", "CFBundleIconFile"] { #expect(plist[key] as? String != nil) }
        #expect(plist["CFBundleExecutable"] as? String == "wine")
        #expect(plist["LSUIElement"] as? Bool == true)
        #expect(try fs.readFile(at: SafeRelativePath("\(root)/Resources/AppIcon.icns"), maxBytes: 16 << 20) == icons.value.icns)
        try await manager.validate(helper, bundle: bundle)
        try fs.writeAtomically(Data("changed".utf8), to: SafeRelativePath("\(root)/MacOS/ntdll.so"))
        await #expect(throws: (any Error).self) { try await manager.validate(helper, bundle: bundle) }
    }

    @Test func iconChangeRebuildsAndMigrationWaitsForOldSessionPins() async throws {
        let f = try BundleFixture(), bundle = try await gameModeTestBundle(f), game = GameDefinition.all[0]
        let fs = try ContainedFileSystem(root: f.store.paths.root)
        let legacy = try SafeRelativePath("Runtimes/GameMode/\(f.bundle.id)/MacGacha Game.app")
        try fs.createHardLink(at: SafeRelativePath("\(legacy)/Contents/MacOS/wine"), to: RuntimeJSONFile.relativePath(bundle.wineBinary, root: f.store.paths.root))
        let ids = f.bundle.components.map(\.rawValue)
        let manager = GameModeHelper(paths: f.store.paths, icons: try FixedGameModeIcon(), registration: LayoutRegistration())
        var pin: RuntimePin? = try RuntimePin.pin(paths: f.store.paths, componentIDs: ids)
        await #expect(throws: (any Error).self) { try await manager.prepare(bundle: bundle, game: game, componentIDs: ids) }
        #expect(try fs.itemType(at: legacy) == .directory)
        withExtendedLifetime(pin) {}; pin = nil
        let first = try await manager.prepare(bundle: bundle, game: game, componentIDs: ids)
        #expect(try fs.itemType(at: legacy) == nil)
        let changed = GameModeHelper(paths: f.store.paths, icons: try FixedGameModeIcon(red: 0), registration: LayoutRegistration())
        _ = try await changed.prepare(bundle: bundle, game: game, componentIDs: ids)
        await #expect(throws: (any Error).self) { try await manager.validate(first, bundle: bundle) }
        try await changed.validate(first, bundle: bundle)
    }

    @Test func editionsKeepIndependentHelpersAndBundleRemovalClearsBoth() async throws {
        let f = try BundleFixture(), bundle = try await gameModeTestBundle(f)
        let manager = GameModeHelper(paths: f.store.paths, icons: try FixedGameModeIcon(), registration: LayoutRegistration())
        let ids = f.bundle.components.map(\.rawValue)
        let first = try await manager.prepare(bundle: bundle, game: GameDefinition.find("genshin")!, componentIDs: ids)
        let second = try await manager.prepare(bundle: bundle, game: GameDefinition.find("genshin-cn")!, componentIDs: ids)
        #expect(first.root != second.root)
        try await manager.validate(first, bundle: bundle)
        try await manager.validate(second, bundle: bundle)
        try await f.manager.remove(f.bundle)
        let fs = try ContainedFileSystem(root: f.store.paths.root)
        #expect(try fs.itemType(at: SafeRelativePath("Runtimes/GameMode/\(f.bundle.id)")) == nil)
    }

    @Test func nativeWineUsesTheUnixLoaderAndUnknownWrappersAreRefused() async throws {
        let f = try BundleFixture(), bundle = try await gameModeTestBundle(f), game = GameDefinition.all[0]
        let fs = try ContainedFileSystem(root: f.store.paths.root), path = try RuntimeJSONFile.relativePath(bundle.wineBinary, root: f.store.paths.root)
        try fs.writeAtomically(Data([0xcf, 0xfa, 0xed, 0xfe]), to: path)
        let manager = GameModeHelper(paths: f.store.paths, icons: try FixedGameModeIcon(), registration: LayoutRegistration())
        let helper = try await manager.prepare(bundle: bundle, game: game, componentIDs: f.bundle.components.map(\.rawValue))
        #expect(helper.wineBinary == helper.loader)
        try fs.writeAtomically(Data("#!/bin/sh\nunknown layout".utf8), to: path)
        await #expect(throws: (any Error).self) { try await manager.prepare(bundle: bundle, game: game, componentIDs: f.bundle.components.map(\.rawValue)) }
    }
}
