// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import Launch
import TestSupport
@testable import RuntimeManager

private final class RecordingGameRegistration: GameModeRegistering, Sendable {
    let calls = Mutex<[URL]>([])
    let fails: Bool
    init(fails: Bool = false) { self.fails = fails }
    func register(_ app: URL) throws {
        calls.withLock { $0.append(app) }
        if fails { throw LauncherError.io("Registration failed") }
    }
}

private let mirrorGame = GameDefinition.find("genshin")!

func gameModeTestBundle(_ fixture: BundleFixture) async throws -> InstalledRuntimeBundle {
    let bundle = try await fixture.manager.install(fixture.bundle), paths = fixture.store.paths
    try await BlockingIO.run {
        let fs = try ContainedFileSystem(root: paths.root)
        let root = try RuntimeJSONFile.relativePath(bundle.root, root: paths.root)
        let native = Data([0xcf, 0xfa, 0xed, 0xfe]) + Data("native fixture".utf8)
        try fs.writeAtomically(Data("#!/bin/sh\nreal_wine=\"$wrapper_dir/wine.real\"\n".utf8), to: SafeRelativePath("\(root)/bin/wine"))
        try fs.writeAtomically(Data("old stub".utf8), to: SafeRelativePath("\(root)/bin/wine.real"))
        for file in ["wine", "ntdll.so", "driver.so"] {
            try fs.writeAtomically(native + Data(file.utf8), to: SafeRelativePath("\(root)/lib/wine/x86_64-unix/\(file)"))
        }
        try fs.createSymbolicLink(at: SafeRelativePath("\(root)/lib/wine/x86_64-unix/driver-alias.so"), target: "driver.so")
        try fs.createDirectory(at: SafeRelativePath("\(root)/share/wine"))
    }
    return bundle
}

@Suite(.timeLimit(.minutes(1))) struct GameModeHelperTests {
    @Test func cancellationDrainsPartialMirrorBeforeReleasingPins() async throws {
        let f = try BundleFixture(), bundle = try await gameModeTestBundle(f)
        let gate = BlockingTestGate(), calls = Mutex(0)
        defer { gate.release() }
        let store = f.store, ids = f.bundle.components.map(\.rawValue), bundleID = f.bundle.id
        let paths = store.paths
        let manager = GameModeHelper(paths: paths, icons: try FixedGameModeIcon(), registration: RecordingGameRegistration(), beforeLink: {
            let count = calls.withLock { $0 += 1; return $0 }
            if count == 2 { gate.block() }
        })
        let build = Task { try await manager.prepare(bundle: bundle, game: mirrorGame, componentIDs: ids) }
        try await gate.entered.wait()
        build.cancel(); gate.release()
        await #expect(throws: (any Error).self) { try await build.value }
        try await BlockingIO.run {
            let fs = try ContainedFileSystem(root: paths.root)
            let entries = try fs.contentsOfDirectory(at: SafeRelativePath("Runtimes/GameMode/\(bundleID)/genshin"))
            #expect(!entries.contains { $0.components.last!.hasPrefix(".incoming-") })
            // No abandoned hard links may keep the source's retired files alive.
            _ = try fs.inspectTree(at: RuntimeJSONFile.relativePath(bundle.root, root: paths.root))
            _ = try RuntimeRemovalLease(paths: paths, componentIDs: ids)
        }
    }

    @Test(arguments: [false, true]) func crashStagingIsReclaimedAndLiveMirrorsSurvive(underInstallLease: Bool) async throws {
        let f = try BundleFixture(), bundle = try await gameModeTestBundle(f)
        let store = f.store, ids = f.bundle.components.map(\.rawValue), bundleID = f.bundle.id
        let paths = store.paths
        let manager = GameModeHelper(paths: paths, icons: try FixedGameModeIcon(), registration: RecordingGameRegistration())
        let helper = try await manager.prepare(bundle: bundle, game: mirrorGame, componentIDs: ids)
        let stage = try SafeRelativePath("Runtimes/GameMode/\(bundleID)/genshin/.incoming-crashed")
        try await BlockingIO.run {
            let fs = try ContainedFileSystem(root: paths.root)
            try fs.createHardLink(at: SafeRelativePath("\(stage)/Contents/MacOS/wine"), to: RuntimeJSONFile.relativePath(bundle.wineBinary, root: paths.root))
        }
        if underInstallLease { _ = try await f.manager.install(f.bundle) }
        else { try await BlockingIO.run { try store.sweepStaging() } }
        let remaining = try await BlockingIO.run { try ContainedFileSystem(root: paths.root).itemType(at: stage) }
        #expect(remaining == nil)
        try await manager.validate(helper, bundle: bundle)
    }

    @Test(arguments: [false, true]) func retiredBundleMirrorsAreReclaimedIncludingLegacyMarkers(legacy: Bool) async throws {
        let f = try BundleFixture(), bundle = try await gameModeTestBundle(f)
        let store = f.store, ids = f.bundle.components.map(\.rawValue), bundleID = f.bundle.id
        let paths = store.paths
        let manager = GameModeHelper(paths: paths, icons: try FixedGameModeIcon(), registration: RecordingGameRegistration())
        _ = try await manager.prepare(bundle: bundle, game: mirrorGame, componentIDs: ids)
        try await BlockingIO.run {
            let fs = try ContainedFileSystem(root: paths.root)
            let parent = try SafeRelativePath("Runtimes/GameMode/\(bundleID)/genshin")
            if legacy {
                let marker = try SafeRelativePath("\(parent)/Genshin Impact.app/.macgacha-game-mode.json")
                var object = try #require(try JSONSerialization.jsonObject(with: fs.readFile(at: marker, maxBytes: 4096)) as? [String: Any])
                object.removeValue(forKey: "sourceRoot")
                try fs.writeAtomically(JSONSerialization.data(withJSONObject: object), to: marker)
            }
            try fs.removeItem(at: RuntimeJSONFile.relativePath(bundle.root, root: paths.root))
            try store.sweepStaging()
            #expect(try fs.itemType(at: parent) == nil)
            #expect(try store.installed().count == 2)
        }
    }

    @Test func legacyDownloadedComponentMirrorIsReclaimedAfterComponentRemoval() async throws {
        let temp = try TempDir(), paths = AppPaths(root: temp.url)
        let record = try InstalledComponent(kind: .d3dmetal, version: "1", installedAt: Date(timeIntervalSince1970: 1), source: .download)
        let root = paths.runtimes.appendingPathComponent("d3dmetal/1")
        var hash = StreamingHasher(.sha256); hash.update(Data("wrapper".utf8))
        let bundle = InstalledRuntimeBundle(id: try SafeIdentifier("metal-bundle"), root: root,
            wineBinary: root.appendingPathComponent("bin/wine"), digest: hash.finalize(), source: .download)
        try await BlockingIO.run {
            let fs = try ContainedFileSystem(root: paths.root)
            try fs.writeAtomically(Data([0xcf, 0xfa, 0xed, 0xfe]), to: SafeRelativePath("Runtimes/d3dmetal/1/bin/wine"))
            for file in ["wine", "ntdll.so"] { try fs.writeAtomically(Data([0xcf, 0xfa, 0xed, 0xfe]), to: SafeRelativePath("Runtimes/d3dmetal/1/lib/wine/x86_64-unix/\(file)")) }
            try fs.createDirectory(at: SafeRelativePath("Runtimes/d3dmetal/1/lib/wine/x86_64-windows"))
            try fs.writeAtomically(JSONEncoder().encode(record), to: SafeRelativePath("Runtimes/d3dmetal/1/.macgacha-component.json"))
        }
        _ = try await GameModeHelper(paths: paths, icons: try FixedGameModeIcon(), registration: RecordingGameRegistration()).prepare(bundle: bundle, game: mirrorGame, componentIDs: ["d3dmetal-1"])
        try await BlockingIO.run {
            let fs = try ContainedFileSystem(root: paths.root)
            let parent = try SafeRelativePath("Runtimes/GameMode/metal-bundle/genshin")
            let marker = try SafeRelativePath("\(parent)/Genshin Impact.app/.macgacha-game-mode.json")
            var object = try #require(try JSONSerialization.jsonObject(with: fs.readFile(at: marker, maxBytes: 4096)) as? [String: Any])
            object.removeValue(forKey: "sourceRoot")
            try fs.writeAtomically(JSONSerialization.data(withJSONObject: object), to: marker)
            try fs.removeItem(at: SafeRelativePath("Runtimes/d3dmetal/1"))
            try RuntimeStore(paths: paths).sweepStaging()
            #expect(try fs.itemType(at: parent) == nil)
        }
    }

    @Test(arguments: ["pin", "journal"]) func mirrorSweepFailsClosedUntilOwnershipDrains(blocker: String) async throws {
        let f = try BundleFixture(), bundle = try await gameModeTestBundle(f)
        let store = f.store, ids = f.bundle.components.map(\.rawValue), bundleID = f.bundle.id
        let paths = store.paths
        let manager = GameModeHelper(paths: paths, icons: try FixedGameModeIcon(), registration: RecordingGameRegistration())
        _ = try await manager.prepare(bundle: bundle, game: mirrorGame, componentIDs: ids)
        try await BlockingIO.run {
            let fs = try ContainedFileSystem(root: paths.root)
            let parent = try SafeRelativePath("Runtimes/GameMode/\(bundleID)/genshin")
            let stage = try SafeRelativePath("\(parent)/.incoming-crashed")
            try fs.createHardLink(at: SafeRelativePath("\(stage)/wine"), to: RuntimeJSONFile.relativePath(bundle.wineBinary, root: paths.root))
            try fs.removeItem(at: RuntimeJSONFile.relativePath(bundle.root, root: paths.root))
            var pin: RuntimePin?
            let journal = try SafeRelativePath("Games/genshin/launch-session.json")
            if blocker == "pin" { pin = try RuntimePin.pin(paths: paths, componentIDs: ids) }
            else { try fs.writeAtomically(Data("unresolved".utf8), to: journal) }
            #expect(throws: (any Error).self) { try store.sweepStaging() }
            #expect(try fs.itemType(at: stage) == .directory)
            withExtendedLifetime(pin) {}; pin = nil
            if blocker == "journal" { try fs.removeFile(at: journal) }
            try store.sweepStaging()
            #expect(try fs.itemType(at: parent) == nil)
        }
    }

    @Test func mirrorsWholeRuntimeAndVerifiesEveryInodeAndSymlink() async throws {
        let f = try BundleFixture(), registration = RecordingGameRegistration()
        let bundle = try await gameModeTestBundle(f)
        let fs = try ContainedFileSystem(root: f.temp.url)
        let source = try RuntimeJSONFile.relativePath(bundle.root, root: f.temp.url)
        try fs.writeAtomically(Data("policy".utf8), to: SafeRelativePath("\(source)/policy.json"))
        try fs.createSymbolicLink(at: SafeRelativePath("\(source)/bin/wine64"), target: "wine")
        try fs.createSymbolicLink(at: SafeRelativePath("\(source)/lib/current"), target: "wine")
        let manager = GameModeHelper(paths: f.store.paths, icons: try FixedGameModeIcon(), registration: registration)
        let helper = try await manager.prepare(bundle: bundle, game: mirrorGame, componentIDs: f.bundle.components.map(\.rawValue))
        #expect(helper.wineBinary.path.hasSuffix("Genshin Impact.app/Contents/MacOS/wine-wrapper"))
        #expect(helper.wineserver.path.hasSuffix("Contents/bin/wineserver"))
        let mirror = try RuntimeJSONFile.relativePath(helper.root, root: f.temp.url)
        #expect(try fs.regularFileIdentity(at: SafeRelativePath("\(source)/bin/wine")) == fs.regularFileIdentity(at: SafeRelativePath("\(mirror)/MacOS/wine-wrapper")))
        #expect(try fs.readFile(at: SafeRelativePath("\(mirror)/policy.json"), maxBytes: 1024) == Data("policy".utf8))
        let plist = try #require(PropertyListSerialization.propertyList(from: fs.readFile(at: SafeRelativePath("\(mirror)/Info.plist"), maxBytes: 16384), format: nil) as? [String: Any])
        #expect(plist["CFBundleExecutable"] as? String == "wine")
        #expect(plist["CFBundleIdentifier"] as? String == "com.lo7ted.macgacha.game.genshin")
        #expect(plist["LSApplicationCategoryType"] as? String == "public.app-category.games")
        #expect(plist["LSSupportsGameMode"] as? Bool == true)
        #expect(plist["LSUIElement"] as? Bool == true)
        try await manager.validate(helper, bundle: bundle)
        #expect(registration.calls.withLock { $0.count } == 1)
        // A byte-identical copy is not an owned hard link.
        let target = try SafeRelativePath("\(mirror)/policy.json")
        try fs.removeItem(at: target); try fs.writeAtomically(Data("policy".utf8), to: target)
        await #expect(throws: (any Error).self) { try await manager.validate(helper, bundle: bundle) }
        _ = try await manager.prepare(bundle: bundle, game: mirrorGame, componentIDs: f.bundle.components.map(\.rawValue))
        try await manager.validate(helper, bundle: bundle)
        try fs.moveItem(at: SafeRelativePath("\(mirror)/lib/current"), to: SafeRelativePath("old-link"), allowingNonRegularSource: true)
        try fs.createSymbolicLink(at: SafeRelativePath("\(mirror)/lib/current"), target: "elsewhere")
        await #expect(throws: (any Error).self) { try await manager.validate(helper, bundle: bundle) }
    }

    @Test func rebuildsOnBundleAndWineDigestChangesAndRemovesWithBundle() async throws {
        let f = try BundleFixture(), registration = RecordingGameRegistration()
        let bundle = try await gameModeTestBundle(f)
        let manager = GameModeHelper(paths: f.store.paths, icons: try FixedGameModeIcon(), registration: registration)
        let ids = f.bundle.components.map(\.rawValue)
        let helper = try await manager.prepare(bundle: bundle, game: mirrorGame, componentIDs: ids)
        let changed = InstalledRuntimeBundle(id: bundle.id, root: bundle.root, wineBinary: bundle.wineBinary,
            digest: try Digest(algorithm: .sha256, hex: String(repeating: "b", count: 64)), source: bundle.source)
        _ = try await manager.prepare(bundle: changed, game: mirrorGame, componentIDs: ids)
        #expect(registration.calls.withLock { $0.count } == 2)
        let fs = try ContainedFileSystem(root: f.temp.url)
        let path = try RuntimeJSONFile.relativePath(bundle.wineBinary, root: f.temp.url)
        try fs.writeAtomically(Data("#!/bin/sh\nreal_wine=\"$wrapper_dir/wine.real\"\n# changed wrapper\n".utf8), to: path)
        await #expect(throws: (any Error).self) { try await manager.validate(helper, bundle: changed) }
        _ = try await manager.prepare(bundle: changed, game: mirrorGame, componentIDs: ids)
        #expect(registration.calls.withLock { $0.count } == 3)
        try await f.manager.remove(f.bundle)
        #expect(try fs.itemType(at: SafeRelativePath("Runtimes/GameMode/\(f.bundle.id)")) == nil)
    }

    @Test func pinsAndUnresolvedJournalsPreventMutationButPermitValidReuse() async throws {
        let f = try BundleFixture(), bundle = try await gameModeTestBundle(f)
        let registration = RecordingGameRegistration()
        let manager = GameModeHelper(paths: f.store.paths, icons: try FixedGameModeIcon(), registration: registration)
        let ids = f.bundle.components.map(\.rawValue)
        var pin: RuntimePin? = try RuntimePin.pin(paths: f.store.paths, componentIDs: ids)
        await #expect(throws: (any Error).self) { try await manager.prepare(bundle: bundle, game: mirrorGame, componentIDs: ids) }
        #expect(registration.calls.withLock { $0.isEmpty })
        withExtendedLifetime(pin) {}; pin = nil
        let helper = try await manager.prepare(bundle: bundle, game: mirrorGame, componentIDs: ids)
        pin = try RuntimePin.pin(paths: f.store.paths, componentIDs: ids)
        #expect(try await manager.prepare(bundle: bundle, game: mirrorGame, componentIDs: ids) == helper)
        await #expect(throws: (any Error).self) { try await f.manager.remove(f.bundle) }
        withExtendedLifetime(pin) {}; pin = nil
        let fs = try ContainedFileSystem(root: f.temp.url)
        try fs.removeItem(at: SafeRelativePath("Runtimes/GameMode/\(f.bundle.id)"))
        try fs.writeAtomically(Data("unreadable journal".utf8), to: SafeRelativePath("Games/genshin/launch-session.json"))
        await #expect(throws: (any Error).self) { try await manager.prepare(bundle: bundle, game: mirrorGame, componentIDs: ids) }
    }


    @Test func aMirroredRuntimeCanStillBeReassembledAfterComponentReplacement() async throws {
        let f = try BundleFixture(), first = try await gameModeTestBundle(f)
        let helper = GameModeHelper(paths: f.store.paths, icons: try FixedGameModeIcon(), registration: RecordingGameRegistration())
        _ = try await helper.prepare(bundle: first, game: mirrorGame, componentIDs: f.bundle.components.map(\.rawValue))
        for try await _ in f.installer.install(f.manifest.components[1]) {}
        let replacement = try await gameModeTestBundle(f)
        #expect(replacement.digest != first.digest)
        let fs = try ContainedFileSystem(root: f.temp.url)
        #expect(try fs.itemType(at: SafeRelativePath("Runtimes/GameMode/\(f.bundle.id)")) == nil)
    }

    @Test func registrationAndHardLinkFailureNeverPublishAPartialMirror() async throws {
        let f = try BundleFixture(), bundle = try await gameModeTestBundle(f)
        let ids = f.bundle.components.map(\.rawValue)
        let registration = RecordingGameRegistration(fails: true)
        await #expect(throws: (any Error).self) {
            try await GameModeHelper(paths: f.store.paths, icons: try FixedGameModeIcon(), registration: registration).prepare(bundle: bundle, game: mirrorGame, componentIDs: ids)
        }
        let manager = GameModeHelper(paths: f.store.paths, icons: try FixedGameModeIcon(), registration: RecordingGameRegistration(), beforeLink: {
            throw LauncherError.fileSystemFailure("Injected cross-volume link failure", code: EXDEV)
        })
        let fs = try ContainedFileSystem(root: f.temp.url)
        try fs.removeItem(at: SafeRelativePath("Runtimes/GameMode/\(f.bundle.id)"))
        await #expect(throws: (any Error).self) { try await manager.prepare(bundle: bundle, game: mirrorGame, componentIDs: ids) }
        #expect(try fs.itemType(at: SafeRelativePath("Runtimes/GameMode/\(f.bundle.id)/Genshin Impact.app")) == nil)
    }
}
