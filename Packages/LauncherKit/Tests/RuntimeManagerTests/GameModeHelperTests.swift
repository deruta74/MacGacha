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

@Suite(.timeLimit(.minutes(1))) struct GameModeHelperTests {
    @Test func mirrorsWholeRuntimeAndVerifiesEveryInodeAndSymlink() async throws {
        let f = try BundleFixture(), registration = RecordingGameRegistration()
        let bundle = try await f.manager.install(f.bundle)
        let fs = try ContainedFileSystem(root: f.temp.url)
        let source = try RuntimeJSONFile.relativePath(bundle.root, root: f.temp.url)
        try fs.writeAtomically(Data("policy".utf8), to: SafeRelativePath("\(source)/policy.json"))
        try fs.createSymbolicLink(at: SafeRelativePath("\(source)/bin/wine64"), target: "wine")
        try fs.createSymbolicLink(at: SafeRelativePath("\(source)/lib/current"), target: "wine")
        let manager = GameModeHelper(paths: f.store.paths, registration: registration)
        let helper = try await manager.prepare(bundle: bundle, componentIDs: f.bundle.components.map(\.rawValue))
        #expect(helper.wineBinary.path.hasSuffix("MacGacha Game.app/Contents/MacOS/wine"))
        #expect(helper.wineserver.path.hasSuffix("Contents/MacOS/wineserver"))
        let mirror = try RuntimeJSONFile.relativePath(helper.root, root: f.temp.url)
        #expect(try fs.regularFileIdentity(at: SafeRelativePath("\(source)/bin/wine")) == fs.regularFileIdentity(at: SafeRelativePath("\(mirror)/MacOS/wine")))
        #expect(try fs.readFile(at: SafeRelativePath("\(mirror)/policy.json"), maxBytes: 1024) == Data("policy".utf8))
        let plist = try #require(PropertyListSerialization.propertyList(from: fs.readFile(at: SafeRelativePath("\(mirror)/Info.plist"), maxBytes: 16384), format: nil) as? [String: Any])
        #expect(plist["CFBundleExecutable"] as? String == "wine")
        #expect(plist["CFBundleIdentifier"] as? String == "com.lo7ted.macgacha.game")
        #expect(plist["LSApplicationCategoryType"] as? String == "public.app-category.games")
        #expect(plist["LSSupportsGameMode"] as? Bool == true)
        #expect(plist["LSUIElement"] as? Bool == true)
        try await manager.validate(helper, bundle: bundle)
        #expect(registration.calls.withLock { $0.count } == 1)
        // A byte-identical copy is not an owned hard link.
        let target = try SafeRelativePath("\(mirror)/policy.json")
        try fs.removeItem(at: target); try fs.writeAtomically(Data("policy".utf8), to: target)
        await #expect(throws: (any Error).self) { try await manager.validate(helper, bundle: bundle) }
        _ = try await manager.prepare(bundle: bundle, componentIDs: f.bundle.components.map(\.rawValue))
        try await manager.validate(helper, bundle: bundle)
        try fs.moveItem(at: SafeRelativePath("\(mirror)/lib/current"), to: SafeRelativePath("old-link"), allowingNonRegularSource: true)
        try fs.createSymbolicLink(at: SafeRelativePath("\(mirror)/lib/current"), target: "elsewhere")
        await #expect(throws: (any Error).self) { try await manager.validate(helper, bundle: bundle) }
    }

    @Test func rebuildsOnBundleAndWineDigestChangesAndRemovesWithBundle() async throws {
        let f = try BundleFixture(), registration = RecordingGameRegistration()
        let bundle = try await f.manager.install(f.bundle)
        let manager = GameModeHelper(paths: f.store.paths, registration: registration)
        let ids = f.bundle.components.map(\.rawValue)
        let helper = try await manager.prepare(bundle: bundle, componentIDs: ids)
        let changed = InstalledRuntimeBundle(id: bundle.id, root: bundle.root, wineBinary: bundle.wineBinary,
            digest: try Digest(algorithm: .sha256, hex: String(repeating: "b", count: 64)), source: bundle.source)
        _ = try await manager.prepare(bundle: changed, componentIDs: ids)
        #expect(registration.calls.withLock { $0.count } == 2)
        let fs = try ContainedFileSystem(root: f.temp.url)
        let path = try RuntimeJSONFile.relativePath(bundle.wineBinary, root: f.temp.url)
        try fs.writeAtomically(Data("new wrapper".utf8), to: path)
        await #expect(throws: (any Error).self) { try await manager.validate(helper, bundle: changed) }
        _ = try await manager.prepare(bundle: changed, componentIDs: ids)
        #expect(registration.calls.withLock { $0.count } == 3)
        try await f.manager.remove(f.bundle)
        #expect(try fs.itemType(at: SafeRelativePath("Runtimes/GameMode/\(f.bundle.id)")) == nil)
    }

    @Test func pinsAndUnresolvedJournalsPreventMutationButPermitValidReuse() async throws {
        let f = try BundleFixture(), bundle = try await f.manager.install(f.bundle)
        let registration = RecordingGameRegistration()
        let manager = GameModeHelper(paths: f.store.paths, registration: registration)
        let ids = f.bundle.components.map(\.rawValue)
        var pin: RuntimePin? = try RuntimePin.pin(paths: f.store.paths, componentIDs: ids)
        await #expect(throws: (any Error).self) { try await manager.prepare(bundle: bundle, componentIDs: ids) }
        #expect(registration.calls.withLock { $0.isEmpty })
        withExtendedLifetime(pin) {}; pin = nil
        let helper = try await manager.prepare(bundle: bundle, componentIDs: ids)
        pin = try RuntimePin.pin(paths: f.store.paths, componentIDs: ids)
        #expect(try await manager.prepare(bundle: bundle, componentIDs: ids) == helper)
        await #expect(throws: (any Error).self) { try await f.manager.remove(f.bundle) }
        withExtendedLifetime(pin) {}; pin = nil
        let fs = try ContainedFileSystem(root: f.temp.url)
        try fs.removeItem(at: SafeRelativePath("Runtimes/GameMode/\(f.bundle.id)"))
        try fs.writeAtomically(Data("unreadable journal".utf8), to: SafeRelativePath("Games/genshin/launch-session.json"))
        await #expect(throws: (any Error).self) { try await manager.prepare(bundle: bundle, componentIDs: ids) }
    }


    @Test func aMirroredRuntimeCanStillBeReassembledAfterComponentReplacement() async throws {
        let f = try BundleFixture(), first = try await f.manager.install(f.bundle)
        let helper = GameModeHelper(paths: f.store.paths, registration: RecordingGameRegistration())
        _ = try await helper.prepare(bundle: first, componentIDs: f.bundle.components.map(\.rawValue))
        for try await _ in f.installer.install(f.manifest.components[1]) {}
        let replacement = try await f.manager.install(f.bundle)
        #expect(replacement.digest != first.digest)
        let fs = try ContainedFileSystem(root: f.temp.url)
        #expect(try fs.itemType(at: SafeRelativePath("Runtimes/GameMode/\(f.bundle.id)")) == nil)
    }

    @Test func registrationAndHardLinkFailureNeverPublishAPartialMirror() async throws {
        let f = try BundleFixture(), bundle = try await f.manager.install(f.bundle)
        let ids = f.bundle.components.map(\.rawValue)
        let registration = RecordingGameRegistration(fails: true)
        await #expect(throws: (any Error).self) {
            try await GameModeHelper(paths: f.store.paths, registration: registration).prepare(bundle: bundle, componentIDs: ids)
        }
        let manager = GameModeHelper(paths: f.store.paths, registration: RecordingGameRegistration(), beforeLink: {
            throw LauncherError.fileSystemFailure("Injected cross-volume link failure", code: EXDEV)
        })
        let fs = try ContainedFileSystem(root: f.temp.url)
        try fs.removeItem(at: SafeRelativePath("Runtimes/GameMode/\(f.bundle.id)"))
        await #expect(throws: (any Error).self) { try await manager.prepare(bundle: bundle, componentIDs: ids) }
        #expect(try fs.itemType(at: SafeRelativePath("Runtimes/GameMode/\(f.bundle.id)/MacGacha Game.app")) == nil)
    }
}
