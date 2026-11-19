// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import DownloadEngine
import Sophon
import RuntimeManager
import TestSupport
@testable import GameLibrary

@Suite(.timeLimit(.minutes(1))) struct SandboxDrainTests {
    @Test func abandonedChainedMaintenanceRetainsBothExclusionsUntilProducerDrains() async throws {
        let temp = try TempDir(), paths = AppPaths(root: temp.url.appendingPathComponent("app"))
        let root = temp.url.appendingPathComponent("game"), fs = try ContainedFileSystem(root: root)
        try fs.createDirectory(at: SafeRelativePath("BeyondAssets"))
        try fs.writeAtomically(Data(), to: SafeRelativePath("beyond_pkg_version"))
        let game = try #require(GameDefinition.all.first { $0.biz == "hk4e_global" })
        let store = GameRecordStore(directory: paths.games)
        let record = GameRecord(installPath: root, ownership: .created, executable: try SafeRelativePath("Game.exe"),
            installed: InstalledBuild(tag: "7.2", buildID: "test", categories: [], voices: []), installIdentity: try fs.rootIdentity(),
            sandbox: try SandboxInstallation(version: "1", listPath: SafeRelativePath("beyond_pkg_version")))
        try await store.save(record, for: game.id)
        try await store.prepareManagedPaths([], target: try #require(record.installed), record: record, for: game.id)
        let http = SandboxDrainHTTP(), disk = FixedDiskSpace(bytes: Int64.max)
        defer { http.release.signal() }
        let library = GameLibrary(paths: paths, api: DeliveryAPI(http: http),
            runner: OperationRunner(store: store, fetcher: ChunkFetcher(http: http, retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()), disk: disk, log: nil),
            store: store, disk: disk, log: nil, sandboxExtractor: SandboxArchiveExtractor())
        var lease: GameOperationLease? = try await claimSandboxTestLease(library, store: store, game: game.id)
        var source: AsyncThrowingStream<OperationEvent, any Error>? = await library.sandboxMaintenance(game, mode: nil, lease: try #require(lease))
        lease = nil
        var iterator: AsyncThrowingStream<OperationEvent, any Error>.Iterator? = source?.makeAsyncIterator()
        _ = try await iterator?.next()
        try await http.entered.wait()
        iterator = nil; source = nil
        // The injected HTTP call ignores cancellation until released. Ownership
        // must span that join rather than the lifetime of the outer iterator.
        await #expect(throws: LauncherError.self) { _ = try await store.acquireOperationLease() }
        #expect(throws: LauncherError.self) {
            _ = try InstallLock(fs: ContainedFileSystem(root: paths.root), path: SafeRelativePath("Games/\(game.id)/.session.lock"))
        }
        http.release.signal()
        try await library.waitUntilIdle(game.id)
        let next = try await store.acquireOperationLease()
        withExtendedLifetime(next) {}
        #expect(try fs.itemType(at: SafeRelativePath(".macgacha-staging/sandbox-work")) == nil)
        #expect(try await store.load(game.id)?.sandbox?.version == "1")
    }
}
private func claimSandboxTestLease(_ library: GameLibrary, store: GameRecordStore, game: String) async throws -> GameOperationLease {
    let lock = try await library.acquireGameLock(game)
    return try await store.acquireOperationLease(retainedGameLock: lock)
}
private final class SandboxDrainHTTP: HTTPClient, Sendable {
    let entered = TestEvent(), release = TestEvent()
    func post(_ url: URL) async throws -> (HTTPResponseHead, HTTPBody) { try await get(url, byteRangeFrom: nil) }
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        if url.lastPathComponent == "package.zip" {
            entered.signal()
            let release = release
            await Task.detached { try? await release.wait() }.value
            throw LauncherError.cancelled
        }
        let data: Data
        if url.lastPathComponent == "getGameConfigs" {
            data = Data(#"{"retcode":0,"data":{"launch_configs":[{"game":{"id":"synthetic","biz":"hk4e_global"},"installation_dir":"Game","exe_file_name":"Game.exe","wpf_exe_dir":"BeyondAssets/editor.exe","wpf_pkg_version_dir":"beyond_pkg_version"}]}}"#.utf8)
        } else {
            data = Data(#"{"retcode":0,"data":{"wpf_packages":[{"game":{"id":"synthetic","biz":"hk4e_global"},"wpf_package":{"version":"2","url":"https://autopatchhk.yuanshen.com/package.zip","md5":"9dd4e461268c8034f5c8564e155c67a6","size":"1"}}]}}"#.utf8)
        }
        let once = SandboxDrainBody(data)
        return (HTTPResponseHead(status: 200, contentLength: Int64(data.count)), HTTPBody(next: { await once.next() }))
    }
}
private actor SandboxDrainBody {
    private var data: Data?
    init(_ data: Data) { self.data = data }
    func next() -> Data? { defer { data = nil }; return data }
}
