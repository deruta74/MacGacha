// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import RuntimeManager
import GameLibrary
import DownloadEngine
@testable import Launch

struct StorageInventoryTests {
    @Test func sixEditionsAndOnlyOrphanPrefixesCanBeCleaned() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = AppPaths(root: root), fs = try ContainedFileSystem(root: root)
        try fs.writeAtomically(Data([1]), to: SafeRelativePath("Prefixes/genshin-old/drive_c/file"))
        try fs.writeAtomically(Data([2]), to: SafeRelativePath("Games/precious/file"))
        let service = StorageInventory(paths: paths)
        let context = StorageContext(region: .global)
        let snapshot = try await service.refresh(context)
        #expect(snapshot.editions.count == 6)
        let candidate = try #require(snapshot.candidates.first { $0.kind == .orphanedPrefix })
        #expect(candidate.bytes > 0)
        do {
            let lease = try await GameRecordStore(directory: paths.games).acquireOperationLease()
            await #expect(throws: (any Error).self) { try await service.cleanUp(candidate, context: context) }
            withExtendedLifetime(lease) {}
        }
        try await service.cleanUp(candidate, context: context)
        #expect(try fs.itemType(at: SafeRelativePath("Prefixes/genshin-old")) == nil)
        #expect(try fs.readFile(at: SafeRelativePath("Games/precious/file"), maxBytes: 10) == Data([2]))
    }

    @Test func journalAndSessionExclusionsAndStaleCandidates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = AppPaths(root: root), fs = try ContainedFileSystem(root: root)
        try fs.createDirectory(at: SafeRelativePath("Prefixes/genshin-old"))
        let service = StorageInventory(paths: paths), context = StorageContext(region: .global)
        let candidate = try #require(try await service.refresh(context).candidates.first)
        let session = try SessionLock.acquire(paths: paths, game: "genshin")
        #expect(try await service.refresh(context).candidates.isEmpty)
        await #expect(throws: (any Error).self) { try await service.cleanUp(candidate, context: context) }
        withExtendedLifetime(session) {}
        try fs.writeAtomically(Data("{}".utf8), to: SafeRelativePath("Games/genshin/launch-session.json"))
        #expect(try await service.refresh(context).candidates.isEmpty)
        await #expect(throws: (any Error).self) { try await service.cleanUp(candidate, context: context) }
    }

    @Test func unavailableLocationKeepsOtherTotalsAndSelectedPrefixes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = AppPaths(root: root), fs = try ContainedFileSystem(root: root)
        try fs.createDirectory(at: SafeRelativePath("install"))
        let install = try #require(try fs.pinDirectoryIfPresent(at: SafeRelativePath("install")))
        let record = GameRecord(installPath: root.appendingPathComponent("install"), ownership: .created,
            executable: try SafeRelativePath("game.exe"),
            installed: InstalledBuild(tag: "1", buildID: "1", categories: [], voices: []),
            installIdentity: try install.rootIdentity())
        try await GameRecordStore(directory: paths.games).save(record, for: "genshin-cn")
        try fs.createDirectory(at: SafeRelativePath("Prefixes/genshin-cn-current"))
        try fs.createDirectory(at: SafeRelativePath("Prefixes/genshin-cn-old"))
        try fs.writeAtomically(Data([1]), to: SafeRelativePath("Logs/ordinary.log"))
        let context = StorageContext(region: .global, selectedRuntimeIDs: ["current"])
        let service = StorageInventory(paths: paths, locationProbe: UnavailableStorageVolume())
        let snapshot = try await service.refresh(context)
        let edition = try #require(snapshot.editions.first { $0.id == "genshin-cn" })
        #expect(edition.game == .unavailable)
        #expect(edition.preDownload == .unavailable)
        #expect(edition.prefixes.bytes != nil)
        #expect(snapshot.logs.bytes! > 0)
        #expect(snapshot.candidates.filter { $0.kind == .orphanedPrefix }.count == 1)
        let unknownSelection = StorageContext(region: .global, prefixSelectionKnown: false)
        #expect(try await service.refresh(unknownSelection).candidates.allSatisfy { $0.kind != .orphanedPrefix })
        let old = try #require(snapshot.candidates.first)
        try fs.moveItem(at: SafeRelativePath("Prefixes/genshin-cn-old"), to: SafeRelativePath("Prefixes/saved"))
        try fs.createDirectory(at: SafeRelativePath("Prefixes/genshin-cn-old"))
        await #expect(throws: (any Error).self) { try await service.cleanUp(old, context: context) }
        #expect(try fs.itemType(at: SafeRelativePath("Prefixes/genshin-cn-old")) == .directory)
    }

    @Test func gameAndPreDownloadAccountingAreSeparate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = AppPaths(root: root), fs = try ContainedFileSystem(root: root)
        try fs.writeAtomically(Data(repeating: 1, count: 4096), to: SafeRelativePath("install/game.exe"))
        try fs.writeAtomically(Data(repeating: 2, count: 32768), to: SafeRelativePath("install/.macgacha-predownload/container"))
        let install = try #require(try fs.pinDirectoryIfPresent(at: SafeRelativePath("install")))
        let record = GameRecord(installPath: root.appendingPathComponent("install"), ownership: .created,
            executable: try SafeRelativePath("game.exe"), installIdentity: try install.rootIdentity())
        try await GameRecordStore(directory: paths.games).save(record, for: "zzz")
        let snapshot = try await StorageInventory(paths: paths).refresh(StorageContext(region: .global))
        let edition = try #require(snapshot.editions.first { $0.id == "zzz" })
        #expect(edition.game.bytes == (try install.allocatedBytes(excluding: [SafeRelativePath(".macgacha-predownload")])))
        #expect(edition.preDownload.bytes == (try install.allocatedBytes(at: SafeRelativePath(".macgacha-predownload"))))
    }

    @Test func newestOwnedLogAndActiveRegionSurviveCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = AppPaths(root: root), fs = try ContainedFileSystem(root: root)
        let first = try SessionLog.create(paths: paths, game: "genshin", header: [:], now: Date(timeIntervalSince1970: 100), timeZone: .gmt, maxBytes: 4096)
        first.finish()
        let newest = try SessionLog.create(paths: paths, game: "genshin", header: [:], now: Date(timeIntervalSince1970: 200), timeZone: .gmt, maxBytes: 4096)
        newest.finish()
        try fs.writeAtomically(Data([3]), to: SafeRelativePath("cache/GameArt/global.png"))
        try fs.writeAtomically(Data([4]), to: SafeRelativePath("cache/GameArt/cn/image.png"))
        try fs.writeAtomically(Data([5]), to: SafeRelativePath("cache/GameEvents/events-index.json"))
        try fs.writeAtomically(Data([6]), to: SafeRelativePath("cache/GameEvents/cn/events-index.json"))
        let service = StorageInventory(paths: paths)
        let context = StorageContext(region: .global, cacheDirectory: root.appendingPathComponent("cache"))
        let snapshot = try await service.refresh(context)
        let log = try #require(snapshot.candidates.first { $0.kind == .oldSessionLog })
        try await service.cleanUp(log, context: context)
        #expect(!FileManager.default.fileExists(atPath: first.url.path))
        #expect(FileManager.default.fileExists(atPath: newest.url.path))
        let cache = try #require(snapshot.candidates.first { $0.kind == .inactiveRegionCache })
        await #expect(throws: (any Error).self) {
            try await service.cleanUp(cache, context: StorageContext(region: .mainlandChina, cacheDirectory: context.cacheDirectory))
        }
        try await service.cleanUp(cache, context: context)
        #expect(try fs.itemType(at: SafeRelativePath("cache/GameArt/cn")) == nil)
        #expect(try fs.itemType(at: SafeRelativePath("cache/GameEvents/cn")) == nil)
        #expect(try fs.readFile(at: SafeRelativePath("cache/GameArt/global.png"), maxBytes: 10) == Data([3]))
        let cnContext = StorageContext(region: .mainlandChina, cacheDirectory: context.cacheDirectory)
        let global = try #require(try await service.refresh(cnContext).candidates.first { $0.kind == .inactiveRegionCache })
        try await service.cleanUp(global, context: cnContext)
        #expect(try fs.itemType(at: SafeRelativePath("cache/GameArt/global.png")) == nil)
        #expect(try fs.itemType(at: SafeRelativePath("cache/GameEvents/events-index.json")) == nil)
    }

    @Test func runtimeCandidatesRespectSelectionRollbackPinsAndLivePins() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = AppPaths(root: root), fs = try ContainedFileSystem(root: root)
        for version in ["old", "current", "pinned", "live"] {
            let installed = try InstalledComponent(kind: .wine, version: version, installedAt: Date(timeIntervalSince1970: 1), source: .download)
            try fs.writeAtomically(JSONEncoder().encode(installed), to: SafeRelativePath("Runtimes/wine/\(version)/.macgacha-component.json"))
            try fs.writeAtomically(Data([1]), to: SafeRelativePath("Runtimes/wine/\(version)/bin/wine"))
        }
        let pin = try RuntimePin.pin(paths: paths, componentIDs: ["wine-live"])
        let service = StorageInventory(paths: paths)
        let context = StorageContext(region: .global, selectedRuntimeIDs: ["wine-current"],
            pinnedRuntimeIDs: ["wine-pinned"], manifest: try RuntimeManifest(components: []))
        let snapshot = try await service.refresh(context)
        let candidates = snapshot.candidates.filter { $0.kind == .runtimeVersion }
        #expect(candidates.map(\.runtimeID) == ["wine-old"])
        withExtendedLifetime(pin) {}
        let item = try #require(candidates.first)
        try await service.validateRuntimeCandidate(item, context: context)
        let newContext = StorageContext(region: .global, selectedRuntimeIDs: ["wine-old"], manifest: context.manifest)
        await #expect(throws: (any Error).self) { try await service.validateRuntimeCandidate(item, context: newContext) }
    }

    @Test(arguments: [false, true])
    func legacyBundleComponentsRespectSelectionAndRollbackPins(pinned: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root), fs = try ContainedFileSystem(root: root)
        let component = try RuntimeComponent(id: SafeIdentifier("d3dmetal-4.0b3"), kind: .d3dmetal,
            version: SafeIdentifier("4.0b3"), sourceMode: .importFromGPTK,
            license: ComponentLicense(name: "Fixture", url: URL(string: "https://fixtures.invalid/license")!,
                redistributable: false, termsRevision: "1"), consent: .appleGPTK,
            rootPath: SafeRelativePath("payload"), wineBinary: SafeRelativePath("bin/wine"))
        let bundle = try RuntimeBundle(id: SafeIdentifier("d3dmetal-wine11.20-gptk4.0b3"), displayName: "Fixture",
            backend: .d3dmetal, components: [component.id])
        let manifest = try RuntimeManifest(components: [component], bundles: [bundle])
        let installed = try InstalledComponent(kind: .d3dmetal, version: "4.0b3",
            installedAt: Date(timeIntervalSince1970: 1), source: .importFromGPTK)
        try fs.writeAtomically(JSONEncoder().encode(installed),
            to: SafeRelativePath("Runtimes/d3dmetal/4.0b3/.macgacha-component.json"))
        try fs.writeAtomically(Data([7]), to: SafeRelativePath("Runtimes/d3dmetal/4.0b3/bin/wine"))
        #expect(try fs.itemType(at: SafeRelativePath("Runtimes/bundles/\(bundle.id)")) == nil)
        let service = StorageInventory(paths: paths)
        let candidate = try #require(try await service.refresh(StorageContext(region: .global, manifest: manifest))
            .candidates.first { $0.runtimeID == "d3dmetal-4.0b3" })
        let context = StorageContext(region: .global,
            selectedRuntimeIDs: pinned ? [] : [bundle.id.rawValue],
            pinnedRuntimeIDs: pinned ? [bundle.id.rawValue] : [], manifest: manifest)
        #expect(try await service.refresh(context).candidates.allSatisfy { $0.kind != .runtimeVersion })
        await #expect(throws: (any Error).self) { try await service.validateRuntimeCandidate(candidate, context: context) }
        #expect(try fs.readFile(at: SafeRelativePath("Runtimes/d3dmetal/4.0b3/bin/wine"), maxBytes: 10) == Data([7]))
    }

    @Test func cacheContainingAnInstallationIsNeverDeleted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = AppPaths(root: root), fs = try ContainedFileSystem(root: root)
        try fs.writeAtomically(Data([9]), to: SafeRelativePath("cache/GameArt/cn/game/game.exe"))
        let service = StorageInventory(paths: paths)
        let context = StorageContext(region: .global, cacheDirectory: root.appendingPathComponent("cache"))
        let candidate = try #require(try await service.refresh(context).candidates.first { $0.kind == .inactiveRegionCache })
        let install = try #require(try fs.pinDirectoryIfPresent(at: SafeRelativePath("cache/GameArt/cn/game")))
        let record = GameRecord(installPath: root.appendingPathComponent("cache/GameArt/cn/game").resolvingSymlinksInPath(), ownership: .adopted,
            executable: try SafeRelativePath("game.exe"), installIdentity: try install.rootIdentity())
        try await GameRecordStore(directory: paths.games).save(record, for: "zzz")
        #expect(try await service.refresh(context).candidates.allSatisfy { $0.kind != .inactiveRegionCache })
        await #expect(throws: (any Error).self) { try await service.cleanUp(candidate, context: context) }
        #expect(try fs.readFile(at: SafeRelativePath("cache/GameArt/cn/game/game.exe"), maxBytes: 10) == Data([9]))
    }

    @Test func runtimeBundleEstimateIncludesItsHelperHardLinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root), fs = try ContainedFileSystem(root: root)
        let license = try ComponentLicense(name: "Fixture", url: URL(string: "https://fixtures.invalid/license")!, redistributable: true, termsRevision: "1")
        let components = try [ComponentKind.wine, .dxmt].map { kind in
            try RuntimeComponent(id: SafeIdentifier("\(kind.idPrefix)-old"), kind: kind, version: SafeIdentifier("old"),
                sourceMode: .download, url: URL(string: "https://fixtures.invalid/runtime.zip")!, size: 1, installedSize: 1,
                sha256: Digest(algorithm: .sha256, hex: String(repeating: "a", count: 64)), archive: .zip, license: license,
                rootPath: SafeRelativePath("payload"), wineBinary: kind == .wine ? SafeRelativePath("bin/wine") : nil,
                overlay: kind == .dxmt ? [RuntimeOverlay(source: SafeRelativePath("d3d11.dll"), destination: SafeRelativePath("lib/wine/d3d11.dll"))] : [])
        }
        let bundle = try RuntimeBundle(id: SafeIdentifier("dxmt-old-bundle"), displayName: "Fixture", backend: .dxmt, components: components.map(\.id))
        let manifest = try RuntimeManifest(components: components, bundles: [bundle])
        for component in components {
            let installed = try InstalledComponent(kind: component.kind, version: "old", installedAt: Date(timeIntervalSince1970: 1), source: .download)
            try fs.writeAtomically(JSONEncoder().encode(installed), to: SafeRelativePath("Runtimes/\(component.kind.rawValue)/old/.macgacha-component.json"))
        }
        let payload = try SafeRelativePath("Runtimes/wine/old/bin/wine")
        try fs.writeAtomically(Data(repeating: 1, count: 2 << 20), to: payload)
        try fs.createDirectory(at: SafeRelativePath("Runtimes/bundles/dxmt-old-bundle/bin"))
        try fs.createDirectory(at: SafeRelativePath("Runtimes/GameMode/dxmt-old-bundle/genshin"))
        try fs.createHardLink(at: SafeRelativePath("Runtimes/bundles/dxmt-old-bundle/bin/wine"), to: payload)
        try fs.createHardLink(at: SafeRelativePath("Runtimes/GameMode/dxmt-old-bundle/genshin/wine"), to: payload)
        let snapshot = try await StorageInventory(paths: paths).refresh(StorageContext(region: .global, manifest: manifest))
        let candidate = try #require(snapshot.candidates.first { $0.runtimeID == "dxmt-old-bundle" })
        #expect(candidate.bytes >= 2 << 20)
    }

    @Test func cancelledRefreshDoesNotProducePartialSnapshot() async throws {
        let service = StorageInventory(paths: AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.refresh(StorageContext(region: .global))
        }
        await #expect(throws: (any Error).self) { try await task.value }
    }
}

private struct UnavailableStorageVolume: GameLocationProbing {
    func requireAvailable(at root: URL) throws { throw LauncherError.installVolumeUnavailable }
}
