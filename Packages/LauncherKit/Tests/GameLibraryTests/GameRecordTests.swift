// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import Sophon
import TestSupport
@testable import GameLibrary

@Suite struct GameRecordTests {
    @Test func gameDefinitionsCoverGlobalGamesAndVoices() {
        #expect(GameDefinition.all.map(\.id) == ["genshin", "starrail", "zzz"])
        #expect(GameDefinition.all.map(\.biz) == ["hk4e_global", "hkrpg_global", "nap_global"])
        for game in GameDefinition.all {
            #expect(game.voices.map(\.code) == ["zh-cn", "en-us", "ja-jp", "ko-kr"])
            #expect(game.voices.allSatisfy { !$0.name.isEmpty })
        }
    }

    @Test func pendingAllowsOnlyResumeAndUninstall() throws {
        var record = sampleRecord(); record.pending = samplePending()
        for action in actions {
            switch action {
            case .resume, .uninstall: try GameRecordRules.check(action, record: record, others: [])
            default:
                #expect(throws: LauncherError.busy("finish or uninstall the paused operation first")) {
                    try GameRecordRules.check(action, record: record, others: [])
                }
            }
        }
    }

    @Test func uninstallingAllowsOnlyUninstall() throws {
        var record = sampleRecord(); record.uninstalling = true; record.pending = samplePending()
        for action in actions {
            if action == .uninstall { try GameRecordRules.check(action, record: record, others: []) }
            else {
                #expect(throws: LauncherError.busy("finish uninstall first")) {
                    try GameRecordRules.check(action, record: record, others: [])
                }
            }
        }
    }

    @Test func updateRequiresInstalledAndNoPending() throws {
        for action in [GameAction.update, .repair, .voices] {
            #expect(throws: LauncherError.io("game is not installed")) { try GameRecordRules.check(action, record: nil, others: []) }
            var record = sampleRecord(); record.installed = nil
            #expect(throws: LauncherError.io("game is not installed")) { try GameRecordRules.check(action, record: record, others: []) }
            record.installed = sampleBuild()
            try GameRecordRules.check(action, record: record, others: [])
            record.pending = samplePending()
            #expect(throws: LauncherError.busy("finish or uninstall the paused operation first")) { try GameRecordRules.check(action, record: record, others: []) }
        }
    }

    @Test func installAndAdoptRequireNoRecord() throws {
        for action in [GameAction.install, .adopt] {
            try GameRecordRules.check(action, record: nil, others: [])
            #expect(throws: LauncherError.io("game already has a record")) {
                try GameRecordRules.check(action, record: sampleRecord(), others: [])
            }
        }
        #expect(throws: LauncherError.io("no pending operation")) { try GameRecordRules.check(.resume, record: sampleRecord(), others: []) }
        #expect(throws: LauncherError.io("game is not installed")) { try GameRecordRules.check(.uninstall, record: nil, others: []) }
    }

    @Test func installRequiresEmptyOrMissingFolder() throws {
        let temp = try TempDir(); let folder = temp.url.appendingPathComponent("new")
        try GameRecordRules.checkInstallFolder(folder)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try GameRecordRules.checkInstallFolder(folder)
        try Data("foreign data".utf8).write(to: folder.appendingPathComponent(".hidden"))
        #expect(throws: LauncherError.io("folder is not empty — use an existing installation instead")) {
            try GameRecordRules.checkInstallFolder(folder)
        }
        #expect(try Data(contentsOf: folder.appendingPathComponent(".hidden")) == Data("foreign data".utf8))
        let file = temp.url.appendingPathComponent("file"); try Data().write(to: file)
        #expect(throws: LauncherError.unsafePath("install location")) { try GameRecordRules.checkInstallFolder(file) }
    }

    @Test func installFolderRejectsLeafSymlinksAndFiles() throws {
        let temp = try TempDir()
        let empty = temp.url.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let dangling = temp.url.appendingPathComponent("dangling")
        let link = temp.url.appendingPathComponent("link")
        let file = temp.url.appendingPathComponent("file")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: temp.url.appendingPathComponent("missing"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: empty)
        try Data().write(to: file)
        for folder in [dangling, link, file] {
            #expect(throws: LauncherError.unsafePath("install location")) { try GameRecordRules.checkInstallFolder(folder) }
        }
    }

    @Test func dotAndDotDotFolderComponentsAreRejected() throws {
        let temp = try TempDir()
        let folders = ["/./new", "/new/../new", "/new/.", "/new/.."].map {
            URL(fileURLWithPath: temp.url.path + $0)
        } + [URL(fileURLWithPath: "/Volumes/Task16MissingVolume/Sub/.."), URL(string: "file:relative")!]
        for folder in folders {
            #expect(throws: LauncherError.unsafePath("install location")) {
                try GameRecordRules.checkLocation(folder, others: [], reserved: [])
            }
            #expect(throws: LauncherError.unsafePath("install location")) {
                try GameRecordRules.checkInstallFolder(folder)
            }
        }
    }

    @Test func symlinkDotComponentsAreRejectedBeforeInspection() throws {
        let temp = try TempDir()
        let safe = temp.url.appendingPathComponent("safe")
        let games = temp.url.appendingPathComponent("games")
        let installed = games.appendingPathComponent("Existing")
        for directory in [safe.appendingPathComponent("Existing"), games.appendingPathComponent("Container"), installed] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let control = installed.appendingPathComponent("control")
        let bytes = Data("installed game".utf8); try bytes.write(to: control)
        try FileManager.default.createSymbolicLink(at: safe.appendingPathComponent("link"), withDestinationURL: games.appendingPathComponent("Container"))
        // Lexical normalization would inspect safe/Existing; the kernel reaches
        // games/Existing after following link and then evaluating dot-dot.
        for suffix in ["/link/../Existing", "/link/./Child"] {
            let folder = URL(fileURLWithPath: safe.path + suffix)
            #expect(throws: LauncherError.unsafePath("install location")) {
                try GameRecordRules.checkLocation(folder, others: [sampleRecord(at: installed)], reserved: [])
            }
            #expect(throws: LauncherError.unsafePath("install location")) {
                try GameRecordRules.checkInstallFolder(folder)
            }
        }
        #expect(try Data(contentsOf: control) == bytes)
    }

    @Test func unreadableInstallParentIsAnIOError() throws {
        let temp = try TempDir()
        let parent = temp.url.appendingPathComponent("unreadable")
        let folder = parent.appendingPathComponent("Game")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { _ = chmod(parent.path, 0o700) }
        #expect(chmod(parent.path, 0) == 0)
        #expect(throws: LauncherError.io("cannot inspect install folder")) {
            try GameRecordRules.checkInstallFolder(folder)
        }
    }

    @Test func invalidInstallAncestorsAreUnsafePaths() throws {
        let temp = try TempDir()
        let loop = temp.url.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(at: loop, withDestinationURL: loop)
        let file = temp.url.appendingPathComponent("file")
        try Data().write(to: file)
        for parent in [loop, file] {
            #expect(throws: LauncherError.unsafePath("install location")) {
                try GameRecordRules.checkInstallFolder(parent.appendingPathComponent("Game"))
            }
        }
    }

    @Test func nestedAndEqualRootsRefused() throws {
        let temp = try TempDir(); let path = temp.url.appendingPathComponent("Game")
        let record = sampleRecord(at: path)
        for url in [path, path.appendingPathComponent("child"), temp.url, temp.url.appendingPathComponent("gAME")] {
            #expect(throws: LauncherError.unsafePath("install location")) { try GameRecordRules.checkLocation(url, others: [record], reserved: []) }
        }
        try GameRecordRules.checkLocation(temp.url.appendingPathComponent("Game2"), others: [record], reserved: [])
    }

    @Test func symlinkAncestorsAndMissingTailsAreResolved() throws {
        let temp = try TempDir(); let real = temp.url.appendingPathComponent("real")
        let game = real.appendingPathComponent("Game")
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        let alias = temp.url.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        #expect(throws: LauncherError.unsafePath("install location")) {
            try GameRecordRules.checkLocation(alias.appendingPathComponent("Game/missing/deep"), others: [sampleRecord(at: game)], reserved: [])
        }
        #expect(throws: LauncherError.unsafePath("install location")) {
            try GameRecordRules.checkLocation(alias, others: [sampleRecord(at: game)], reserved: [])
        }
    }

    @Test func symlinkLoopsAreRejected() throws {
        let temp = try TempDir()
        let a = temp.url.appendingPathComponent("a"); let b = temp.url.appendingPathComponent("b")
        try FileManager.default.createSymbolicLink(at: a, withDestinationURL: b)
        try FileManager.default.createSymbolicLink(at: b, withDestinationURL: a)
        #expect(throws: LauncherError.unsafePath("install location")) {
            try GameRecordRules.checkLocation(a, others: [], reserved: [])
        }
    }

    @Test func firmlinkAliasesCannotBypassLocationProtection() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let alias = URL(fileURLWithPath: "/System/Volumes/Data" + home.path)
        var originalInfo = stat(); var aliasInfo = stat()
        guard stat(home.path, &originalInfo) == 0, stat(alias.path, &aliasInfo) == 0,
            originalInfo.st_dev == aliasInfo.st_dev, originalInfo.st_ino == aliasInfo.st_ino else { return }
        for folder in [alias, alias.appendingPathComponent("Library/Application Support/MacGacha/NewGame")] {
            #expect(throws: LauncherError.unsafePath("install location")) {
                try GameRecordRules.checkLocation(folder, others: [], reserved: [])
            }
        }
        let game = home.appendingPathComponent("Games/FirmlinkTestMissing")
        let aliasedGame = alias.appendingPathComponent("Games/FirmlinkTestMissing")
        for folder in [aliasedGame, aliasedGame.appendingPathComponent("child"), alias.appendingPathComponent("Games")] {
            #expect(throws: LauncherError.unsafePath("install location")) {
                try GameRecordRules.checkLocation(folder, others: [sampleRecord(at: game)], reserved: [])
            }
        }
        try GameRecordRules.checkLocation(alias.appendingPathComponent("Games/FirmlinkTestSibling"),
            others: [sampleRecord(at: game)], reserved: [])
    }

    @Test func firmlinkVolumeAnchorsAreReserved() throws {
        let volumes = URL(fileURLWithPath: "/Volumes")
        let alias = URL(fileURLWithPath: "/System/Volumes/Data/Volumes")
        var originalInfo = stat(); var aliasInfo = stat()
        guard stat(volumes.path, &originalInfo) == 0, stat(alias.path, &aliasInfo) == 0,
            originalInfo.st_dev == aliasInfo.st_dev, originalInfo.st_ino == aliasInfo.st_ino else { return }
        // Include a missing child: its existing ancestor still identifies /Volumes.
        for folder in [alias, alias.appendingPathComponent("Task16MissingVolume")] {
            #expect(throws: LauncherError.unsafePath("install location")) {
                try GameRecordRules.checkLocation(folder, others: [], reserved: [])
            }
        }
        let recovery = alias.appendingPathComponent("Recovery")
        if FileManager.default.fileExists(atPath: recovery.path) {
            #expect(throws: LauncherError.unsafePath("install location")) {
                try GameRecordRules.checkLocation(recovery, others: [], reserved: [])
            }
        }
        try GameRecordRules.checkLocation(alias.appendingPathComponent("Task16MissingVolume/Games/Test"), others: [], reserved: [])
    }

    @Test func reservedRootsRefused() throws {
        let temp = try TempDir()
        let support = temp.url.appendingPathComponent("Support")
        let runtimes = temp.url.appendingPathComponent("Runtimes")
        for url in [support, support.appendingPathComponent("Games"), runtimes, temp.url] {
            #expect(throws: LauncherError.unsafePath("install location")) {
                try GameRecordRules.checkLocation(url, others: [], reserved: [support, runtimes])
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for url in [URL(fileURLWithPath: "/"), home, URL(fileURLWithPath: "/Volumes"), URL(fileURLWithPath: "/Volumes/UnattachedTestVolume")] {
            #expect(throws: LauncherError.unsafePath("install location")) { try GameRecordRules.checkLocation(url, others: [], reserved: []) }
        }
        // Root/home/volume anchors forbid selecting the anchor, not all descendants.
        try GameRecordRules.checkLocation(home.appendingPathComponent("Games/Test"), others: [], reserved: [home, URL(fileURLWithPath: "/")])
        try GameRecordRules.checkLocation(URL(fileURLWithPath: "/Volumes/UnattachedTestVolume/Games/Test"), others: [], reserved: [URL(fileURLWithPath: "/Volumes/UnattachedTestVolume")])
    }

    @Test func invalidURLLocationsAreRejected() {
        let url = URL(string: "https://example.invalid/game")!
        #expect(throws: LauncherError.unsafePath("install location")) { try GameRecordRules.checkLocation(url, others: [], reserved: []) }
        #expect(throws: LauncherError.unsafePath("install location")) { try GameRecordRules.checkInstallFolder(url) }
    }

    @Test func storeRoundTripsRecordAndPlan() async throws {
        let temp = try TempDir(); let directory = temp.url.appendingPathComponent("Games")
        let store = GameRecordStore(directory: directory)
        #expect(try await store.load("genshin") == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        var record = sampleRecord(); record.pending = samplePending(); record.ownership = .adopted
        try await store.save(record, for: "genshin")
        #expect(try await store.load("genshin") == record)
        let plan = try samplePlan()
        try await store.savePlan(plan, for: "genshin")
        let restored = try #require(try await store.loadPlan(for: "genshin"))
        #expect(restored.planDigest == plan.planDigest)
        try restored.validate()
        let cache = try await store.manifestCache(for: "genshin")
        #expect(cache.path == directory.appendingPathComponent("genshin/manifests").path)
        #expect(FileManager.default.fileExists(atPath: cache.path))
        try await store.delete("genshin")
        #expect(try await store.load("genshin") == nil)
        #expect(try await store.loadPlan(for: "genshin") != nil)
        try await store.deletePlan(for: "genshin")
        #expect(try await store.loadPlan(for: "genshin") == nil)
        try await store.delete("genshin"); try await store.deletePlan(for: "genshin")
    }

    @Test func planFileOverLimitRefused() async throws {
        let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
        let path = try SafeRelativePath("genshin/pending-plan.json")
        let handle = try fs.openForWriting(at: path, truncate: true)
        try handle.truncate(atOffset: UInt64(InstallPlan.maximumEncodedBytes) + 1); try handle.close()
        let store = GameRecordStore(directory: temp.url)
        await #expect(throws: LauncherError.fileTooLarge(path: path.resolved(against: temp.url).path, limit: InstallPlan.maximumEncodedBytes)) {
            try await store.loadPlan(for: "genshin")
        }
    }

    @Test func corruptRecordSurfacesJournalCorrupt() async throws {
        let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
        let path = try SafeRelativePath("genshin/record.json"); let broken = Data("{broken".utf8)
        try fs.writeAtomically(broken, to: path)
        let store = GameRecordStore(directory: temp.url)
        await #expect(throws: LauncherError.journalCorrupt("invalid game record")) { try await store.load("genshin") }
        #expect(try fs.readFile(at: path, maxBytes: 100) == broken)
    }

    @Test func oversizedRecordIsCorruptAndNotReset() async throws {
        let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
        let path = try SafeRelativePath("genshin/record.json")
        let handle = try fs.openForWriting(at: path, truncate: true)
        try handle.truncate(atOffset: UInt64(GameRecordStore.maximumRecordBytes) + 1); try handle.close()
        let store = GameRecordStore(directory: temp.url)
        await #expect(throws: LauncherError.journalCorrupt("game record exceeds size limit")) { try await store.load("genshin") }
        #expect(try fs.size(at: path) == Int64(GameRecordStore.maximumRecordBytes) + 1)
    }

    @Test func invalidRecordInvariantsFailOnDecodeAndSave() async throws {
        let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
        let store = GameRecordStore(directory: temp.url)
        var invalid = sampleRecord(); invalid.installPath = URL(string: "https://example.invalid/game")!
        await #expect(throws: LauncherError.io("invalid game record")) { try await store.save(invalid, for: "genshin") }
        let bytes = try JSONEncoder().encode(invalid)
        #expect(throws: LauncherError.io("invalid game record")) { try JSONDecoder().decode(GameRecord.self, from: bytes) }
        try fs.writeAtomically(bytes, to: SafeRelativePath("genshin/record.json"))
        await #expect(throws: LauncherError.journalCorrupt("invalid game record")) { try await store.load("genshin") }
        var pending = sampleRecord()
        pending.pending = PendingOperation(kind: .update, planID: try SafeIdentifier("plan"), planDigest: recordDigest("not-sha256", algorithm: .md5), target: sampleBuild())
        await #expect(throws: LauncherError.io("invalid game record")) { try await store.save(pending, for: "starrail") }
    }

    @Test func invalidPlansAreNeverStoredOrLoaded() async throws {
        let temp = try TempDir(); let store = GameRecordStore(directory: temp.url)
        let object = ChunkObject(id: "unused", urls: [URL(string: "https://cdn.hoyoverse.com/c")!], transferSize: 1,
            decodedSize: 1, decodedDigest: recordDigest("a"), codec: .identity)
        let plan = InstallPlan(id: try SafeIdentifier("invalid"), objects: ["unused": object], files: [])
        await #expect(throws: LauncherError.io("invalid plan: orphan object")) { try await store.savePlan(plan, for: "genshin") }
        let fs = try ContainedFileSystem(root: temp.url)
        try fs.writeAtomically(JSONEncoder().encode(plan), to: SafeRelativePath("genshin/pending-plan.json"))
        await #expect(throws: LauncherError.journalCorrupt("invalid pending plan")) { try await store.loadPlan(for: "genshin") }
    }

    @Test func invalidGameIDsAreRefused() async throws {
        let temp = try TempDir(); let store = GameRecordStore(directory: temp.url)
        for game in ["../escape", "a/b", "", ".hidden"] {
            await #expect(throws: LauncherError.unsafePath(game)) { try await store.save(sampleRecord(), for: game) }
            await #expect(throws: LauncherError.unsafePath(game)) { try await store.manifestCache(for: game) }
        }
    }

    @Test func symlinkedGameDirectoryCannotRedirectAnyStoreOperation() async throws {
        let temp = try TempDir(); let outside = try TempDir()
        let control = outside.url.appendingPathComponent("record.json"); let bytes = Data("outside control".utf8)
        try bytes.write(to: control)
        try FileManager.default.createSymbolicLink(at: temp.url.appendingPathComponent("genshin"), withDestinationURL: outside.url)
        let store = GameRecordStore(directory: temp.url); let record = sampleRecord(); let plan = try samplePlan()
        let calls: [@Sendable () async throws -> Void] = [
            { _ = try await store.load("genshin") }, { try await store.save(record, for: "genshin") },
            { try await store.delete("genshin") }, { _ = try await store.loadPlan(for: "genshin") },
            { try await store.savePlan(plan, for: "genshin") }, { try await store.deletePlan(for: "genshin") },
            { _ = try await store.manifestCache(for: "genshin") }]
        for call in calls {
            do { try await call(); Issue.record("Symlink should be refused") }
            catch let error as LauncherError { guard case .unsafePath = error else { Issue.record("Expected unsafePath"); continue } }
        }
        #expect(try Data(contentsOf: control) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.url.path) == ["record.json"])
    }

    @Test func atomicSaveSyncsBeforeRenameAndPreservesOldOnFailure() async throws {
        let temp = try TempDir(); let ops = RecordFileOps()
        let store = GameRecordStore(directory: temp.url, fileOps: ops)
        let old = sampleRecord(); try await store.save(old, for: "genshin")
        let events = ops.events.withLock { $0 }
        let fileSync = try #require(events.firstIndex(of: "file-sync"))
        let rename = try #require(events.firstIndex(of: "rename"))
        let directorySync = try #require(events.lastIndex(of: "directory-sync"))
        #expect(fileSync < rename && rename < directorySync)
        ops.failFileSync.withLock { $0 = true }
        var next = old; next.uninstalling = true
        await #expect(throws: LauncherError.io("injected sync failure")) { try await store.save(next, for: "genshin") }
        #expect(try await store.load("genshin") == old)
        let fs = try ContainedFileSystem(root: temp.url)
        #expect(try fs.contentsOfDirectory(at: SafeRelativePath("genshin")).map(\.description) == ["genshin/record.json"])
    }

    @Test func firstSaveSyncsParentsOfNewStoreAncestors() async throws {
        let temp = try TempDir(); let ops = RecordFileOps()
        let support = temp.url.appendingPathComponent("Support")
        let app = support.appendingPathComponent("MacGacha")
        let store = GameRecordStore(directory: app.appendingPathComponent("Games"), fileOps: ops)
        try await store.save(sampleRecord(), for: "genshin")
        let synced = ops.syncedDirectories.withLock { $0 }
        let events = ops.events.withLock { $0 }
        let fileSync = try #require(events.firstIndex(of: "file-sync"))
        for parent in [temp.url, support, app] {
            var info = stat()
            #expect(stat(parent.path, &info) == 0)
            let identity = "\(info.st_dev):\(info.st_ino)"
            #expect(synced.contains(identity))
            let parentSync = try #require(events.firstIndex(of: "directory-sync:\(identity)"))
            #expect(parentSync < fileSync)
        }
        #expect(try await store.load("genshin") == sampleRecord())
    }

    @Test func rootParentSyncFailureRefusesSaveAndRetryHealsCreation() async throws {
        let temp = try TempDir(); let ops = RecordFileOps()
        var parentInfo = stat()
        #expect(stat(temp.url.path, &parentInfo) == 0)
        let identity = "\(parentInfo.st_dev):\(parentInfo.st_ino)"
        ops.failDirectoryIdentity.withLock { $0 = identity }
        let root = temp.url.appendingPathComponent("Games")
        let store = GameRecordStore(directory: root, fileOps: ops)
        await #expect(throws: LauncherError.io("injected parent sync failure")) {
            try await store.save(sampleRecord(), for: "genshin")
        }
        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(try await store.load("genshin") == nil)
        ops.failDirectoryIdentity.withLock { $0 = nil }
        try await store.save(sampleRecord(), for: "genshin")
        #expect(try await store.load("genshin") == sampleRecord())
        #expect(ops.syncedDirectories.withLock { $0.filter { $0 == identity }.count } == 2)
    }

    @Test func cancelledStoreReadsAndCacheCreationHaveNoSideEffects() async throws {
        let temp = try TempDir()
        for operation in 0..<3 {
            let directory = temp.url.appendingPathComponent("missing-\(operation)")
            let store = GameRecordStore(directory: directory)
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                switch operation {
                case 0: _ = try await store.load("genshin")
                case 1: _ = try await store.loadPlan(for: "genshin")
                default: _ = try await store.manifestCache(for: "genshin")
                }
            }
            await #expect(throws: LauncherError.cancelled) { try await task.value }
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }

    @Test func cancelledStoreWriteDoesNotCreateARecord() async throws {
        let temp = try TempDir(); let directory = temp.url.appendingPathComponent("missing")
        let store = GameRecordStore(directory: directory)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.save(sampleRecord(), for: "genshin")
        }
        await #expect(throws: LauncherError.cancelled) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}

private let actions: [GameAction] = [.install, .adopt, .update, .repair, .voices, .resume, .uninstall]
private func recordDigest(_ text: String, algorithm: DigestAlgorithm = .sha256) -> Digest {
    var h = StreamingHasher(algorithm); h.update(Data(text.utf8)); return h.finalize()
}
private func sampleBuild() -> InstalledBuild {
    let ref = ManifestRef(id: "manifest", decodedMD5: recordDigest("", algorithm: .md5), compressedSize: 9, decodedSize: 0)
    let category = BuildCategory(id: "base", matchingField: "game", manifest: ref,
        manifestPrefix: URL(string: "https://cdn.hoyoverse.com/manifests")!, manifestSuffix: "?a=1%2F2",
        chunkPrefix: URL(string: "https://cdn.yuanshen.com/chunks")!, chunkSuffix: "?b=3", compressedSize: 100, decodedSize: 200)
    return InstalledBuild(tag: "1.2.3", buildID: "build", categories: [category], voices: ["en-us", "ja-jp"])
}
private func samplePending() -> PendingOperation {
    PendingOperation(kind: .update, planID: try! SafeIdentifier("pending"), planDigest: try! samplePlan().planDigest, target: sampleBuild())
}
private func sampleRecord(at url: URL = URL(fileURLWithPath: "/Games/Test")) -> GameRecord {
    GameRecord(installPath: url, ownership: .created, executable: try! SafeRelativePath("Test.exe"), installed: sampleBuild())
}
private func samplePlan() throws -> InstallPlan {
    InstallPlan(id: try SafeIdentifier("pending"), objects: [:], files: [FileTask(path: try SafeRelativePath("empty"), size: 0, digest: recordDigest(""), extents: [])])
}
private final class RecordFileOps: FileOps, Sendable {
    let events = Mutex<[String]>([]); let failFileSync = Mutex(false)
    let syncedDirectories = Mutex<[String]>([])
    let failDirectoryIdentity = Mutex<String?>(nil)
    private let system = SystemFileOps()
    func write(_ fd: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try system.write(fd, bytes: bytes) }
    func synchronize(_ fd: Int32, durable: Bool) throws {
        var info = stat(); guard fstat(fd, &info) == 0 else { throw LauncherError.io("fstat failed") }
        let regular = info.st_mode & S_IFMT == S_IFREG
        events.withLock { $0.append(regular ? "file-sync" : "directory-sync") }
        if !regular {
            let identity = "\(info.st_dev):\(info.st_ino)"
            syncedDirectories.withLock { $0.append(identity) }
            events.withLock { $0.append("directory-sync:\(identity)") }
            if failDirectoryIdentity.withLock({ $0 == identity }) { throw LauncherError.io("injected parent sync failure") }
        }
        if regular, failFileSync.withLock({ $0 }) { throw LauncherError.io("injected sync failure") }
        try system.synchronize(fd, durable: durable)
    }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        events.withLock { $0.append("rename") }
        try system.rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func swap(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32) throws {
        try system.swap(from: source, in: sourceDirectory, to: destination, in: destinationDirectory)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws { try system.unlink(name, in: directory, isDirectory: isDirectory) }
}
