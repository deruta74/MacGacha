// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import Launch
@testable import RuntimeManager

private struct AudioRegistration: GameModeRegistering { func register(_ app: URL) throws {} }

@Suite(.timeLimit(.minutes(1))) struct GameModeSurroundTests {
    @Test(arguments: ["genshin", "genshin-cn", "zzz", "zzz-cn"], [false, true])
    func overlayIsPrivateVerifiedAndIndependentOfGameMode(gameID: String, gameMode: Bool) async throws {
        let f = try BundleFixture(), installed = try await gameModeTestBundle(f)
        let bundle = InstalledRuntimeBundle(id: try SafeIdentifier(SurroundAudio.bundleID), root: installed.root, wineBinary: installed.wineBinary,
            digest: installed.digest, source: installed.source)
        let fs = try ContainedFileSystem(root: f.store.paths.root)
        let source = try RuntimeJSONFile.relativePath(bundle.root, root: f.store.paths.root)
        let stock = try SafeRelativePath("\(source)/lib/wine/x86_64-unix/winecoreaudio.so")
        try fs.writeAtomically(gameModeMachO() + Data("stock".utf8), to: stock)
        let component = try SafeRelativePath("Runtimes/surroundAudio/wine-11.20-1")
        let module = try SafeRelativePath("\(component)/x86_64-unix/winecoreaudio.so")
        try fs.writeAtomically(gameModeMachO(rpaths: ["@loader_path/../.."], dylibs: ["@rpath/wine/x86_64-unix/driver.so"]) + Data("spatial".utf8), to: module)
        let record = try InstalledComponent(kind: .surroundAudio, version: "wine-11.20-1", installedAt: Date(timeIntervalSince1970: 1), source: .download)
        try fs.writeAtomically(JSONEncoder().encode(record), to: SafeRelativePath("\(component)/.macgacha-component.json"))
        let icons = try FixedGameModeIcon(), manager = GameModeHelper(paths: f.store.paths, icons: icons, registration: AudioRegistration())
        let game = GameDefinition.find(gameID)!, other = GameDefinition.find(gameID == "genshin" ? "genshin-cn" : "genshin")!
        let ids = f.bundle.components.map(\.rawValue) + [SurroundAudio.componentID]
        let normal = try await manager.prepare(bundle: bundle, game: other, componentIDs: ids)
        let options = GameModeOptions(gameModeEnabled: gameMode, surroundModule: module.resolved(against: f.store.paths.root))
        await #expect(throws: (any Error).self) {
            try await manager.prepare(bundle: bundle, game: GameDefinition.find("starrail")!, componentIDs: ids, options: options)
        }
        await #expect(throws: (any Error).self) {
            try await manager.prepare(bundle: bundle, game: game, componentIDs: f.bundle.components.map(\.rawValue), options: options)
        }
        await #expect(throws: (any Error).self) {
            try await manager.prepare(bundle: bundle, game: game, componentIDs: ids,
                options: GameModeOptions(surroundModule: stock.resolved(against: f.store.paths.root)))
        }
        let helper = try await manager.prepare(bundle: bundle, game: game, componentIDs: ids, options: options)
        #expect(helper.surroundModule == options.surroundModule)
        #expect(helper.gameModeEnabled == gameMode)
        let root = try RuntimeJSONFile.relativePath(helper.root, root: f.store.paths.root)
        #expect(try fs.regularFileIdentity(at: SafeRelativePath("\(root)/MacOS/winecoreaudio.so")) == fs.regularFileIdentity(at: module))
        #expect(try fs.regularFileIdentity(at: SafeRelativePath("\(root)/lib/wine/x86_64-unix/winecoreaudio.so")) == fs.regularFileIdentity(at: stock))
        let plist = try #require(try PropertyListSerialization.propertyList(from: fs.readFile(at: SafeRelativePath("\(root)/Info.plist"), maxBytes: 16384), format: nil) as? [String: Any])
        #expect(plist["LSSupportsGameMode"] as? Bool == gameMode)
        #expect(plist["LSApplicationCategoryType"] as? String == (gameMode ? "public.app-category.games" : "public.app-category.utilities"))
        try await manager.validate(helper, bundle: bundle)
        try await manager.validate(normal, bundle: bundle)
        var pin: RuntimePin? = try RuntimePin.pin(paths: f.store.paths, componentIDs: ids)
        #expect(throws: (any Error).self) { try f.store.remove(record) }
        await #expect(throws: (any Error).self) { try await manager.prepare(bundle: bundle, game: game, componentIDs: ids) }
        withExtendedLifetime(pin) {}; pin = nil
        try fs.writeAtomically(gameModeMachO(rpaths: ["@loader_path/../.."], dylibs: ["@rpath/wine/x86_64-unix/driver.so"]) + Data("new spatial".utf8), to: module)
        await #expect(throws: (any Error).self) { try await manager.validate(helper, bundle: bundle) }
        let rebuilt = try await manager.prepare(bundle: bundle, game: game, componentIDs: ids, options: options)
        try await manager.validate(rebuilt, bundle: bundle)
        let off = try await manager.prepare(bundle: bundle, game: game, componentIDs: ids)
        #expect(off.surroundModule == nil)
        #expect(try fs.regularFileIdentity(at: SafeRelativePath("\(root)/MacOS/winecoreaudio.so")) == fs.regularFileIdentity(at: stock))
        #expect(try fs.readFile(at: stock, maxBytes: 1024) == gameModeMachO() + Data("stock".utf8))
        _ = try await manager.prepare(bundle: bundle, game: game, componentIDs: ids, options: options)
        try f.store.remove(record)
        let store = f.store
        try await BlockingIO.run { try store.sweepStaging() }
        #expect(try fs.itemType(at: RuntimeJSONFile.relativePath(helper.root.deletingLastPathComponent(), root: f.store.paths.root)) == nil)
        try await manager.validate(normal, bundle: bundle)
    }

    @Test func missingStockAudioSlotCannotClaimAnActiveOverlay() async throws {
        let f = try BundleFixture(), installed = try await gameModeTestBundle(f)
        let bundle = InstalledRuntimeBundle(id: try SafeIdentifier(SurroundAudio.bundleID), root: installed.root,
            wineBinary: installed.wineBinary, digest: installed.digest, source: .download)
        let fs = try ContainedFileSystem(root: f.store.paths.root)
        let component = try SafeRelativePath("Runtimes/surroundAudio/wine-11.20-1")
        let module = try SafeRelativePath("\(component)/x86_64-unix/winecoreaudio.so")
        try fs.writeAtomically(gameModeMachO(), to: module)
        let record = try InstalledComponent(kind: .surroundAudio, version: "wine-11.20-1", installedAt: Date(timeIntervalSince1970: 1), source: .download)
        try fs.writeAtomically(JSONEncoder().encode(record), to: SafeRelativePath("\(component)/.macgacha-component.json"))
        let manager = GameModeHelper(paths: f.store.paths, icons: try FixedGameModeIcon(), registration: AudioRegistration())
        await #expect(throws: (any Error).self) {
            try await manager.prepare(bundle: bundle, game: GameDefinition.find("genshin")!,
                componentIDs: f.bundle.components.map(\.rawValue) + [SurroundAudio.componentID],
                options: GameModeOptions(surroundModule: module.resolved(against: f.store.paths.root)))
        }
    }
}
