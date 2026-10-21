// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import LauncherCore
import DownloadEngine
import TestSupport
import GameLibrary
import Sophon

@main
struct CrashHarness {
    static func main() async {
        do {
            let args = CommandLine.arguments
            if args.count == 3, args[1] == "crash-cache-write" {
                let store = GameRecordStore(directory: URL(fileURLWithPath: args[2]), fileOps: CacheWriteCrashOps())
                try await store.writeCacheState(Data("{\"interrupted\":true}".utf8), named: "branch.json", for: "genshin")
                _exit(1) // The rename seam must terminate the process first.
            }
            if args.count == 5, args[1] == "hold-game-store" {
                let store = GameRecordStore(directory: URL(fileURLWithPath: args[2]))
                let lease = try await store.acquireOperationLease()
                defer { withExtendedLifetime(lease) {} }
                try Data().write(to: URL(fileURLWithPath: args[3]))
                waitForRelease(args[4])
                return
            }
            guard (args.count == 4 || args.count == 6), let point = CrashPoint(rawValue: args[3]) else {
                throw LauncherError.io("Usage: CrashHarness <fixtureDir> <installRoot> <crashPoint>")
            }
            let fixtures = URL(fileURLWithPath: args[1], isDirectory: true)
            let root = URL(fileURLWithPath: args[2], isDirectory: true)
            let fileOps: any FileOps = [.duringCompletionReceiptWrite, .duringGamePlanWrite].contains(point)
                ? ReceiptWriteCrashOps(gameMetadata: point == .duringGamePlanWrite) : SystemFileOps()
            let fs = try ContainedFileSystem(root: fixtures)
            if args.count == 6, args[5] == "uninstall" {
                let storeURL = URL(fileURLWithPath: args[4])
                let store = GameRecordStore(directory: storeURL)
                let http = try FileBackedHTTPClient(root: fixtures)
                let runner = OperationRunner(store: store, fetcher: ChunkFetcher(http: http,
                    retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()), disk: FixedDiskSpace(bytes: Int64.max), log: nil)
                let library = GameLibrary(paths: AppPaths(root: storeURL.deletingLastPathComponent()), api: DeliveryAPI(http: http),
                    runner: runner, store: store, disk: FixedDiskSpace(bytes: Int64.max), log: nil,
                    crashHooks: CrashHooks(at: point, action: { _exit(137) }))
                try await library.uninstall(GameDefinition.all[0]); _exit(1)
            }
            let plan = try JSONDecoder().decode(InstallPlan.self,
                from: fs.readFile(at: SafeRelativePath("plan.json"), maxBytes: InstallPlan.maximumEncodedBytes))
            if args.count == 6 {
                guard let kind = PendingOperation.Kind(rawValue: args[5]) else { throw LauncherError.io("Invalid game operation kind") }
                let record = try JSONDecoder().decode(GameRecord.self,
                    from: fs.readFile(at: SafeRelativePath("record.json"), maxBytes: GameRecordStore.maximumRecordBytes))
                let target = try JSONDecoder().decode(InstalledBuild.self,
                    from: fs.readFile(at: SafeRelativePath("target.json"), maxBytes: GameRecordStore.maximumRecordBytes))
                let runner = OperationRunner(store: GameRecordStore(directory: URL(fileURLWithPath: args[4]), fileOps: fileOps),
                    fetcher: ChunkFetcher(http: try FileBackedHTTPClient(root: fixtures), retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()),
                    disk: FixedDiskSpace(bytes: Int64.max), log: nil, crashHooks: CrashHooks(at: point, action: { _exit(137) }), fileOps: fileOps)
                for try await _ in await runner.start("genshin", record: record, plan: plan, kind: kind, target: target, approved: true, managedPaths: Set(plan.files.map(\.path))) {}
                _exit(1)
            }
            let operation = try InstallOperation(plan: plan, installRoot: root,
                fetcher: ChunkFetcher(http: FileBackedHTTPClient(root: fixtures),
                    retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()),
                fileOps: fileOps, crashHooks: CrashHooks(at: point, action: { _exit(137) }),
                writesCompletionReceipt: [.afterOperationCompleted, .duringCompletionReceiptWrite, .afterCompletionReceipt, .afterEngineCleanup].contains(point))
            for try await _ in operation.run() {}
            // A missing hook must fail the parent test rather than masquerade as a crash.
            _exit(1)
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("CrashHarness: \(error)\n".utf8))
            _exit(2)
        }
    }

    private static func waitForRelease(_ path: String) {
        for _ in 0..<1500 {
            if FileManager.default.fileExists(atPath: path) { return }
            usleep(10_000)
        }
        _exit(3)
    }
}

/// A real process death after writing/syncing the cache sibling, before rename.
private struct CacheWriteCrashOps: FileOps {
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try SystemFileOps().write(descriptor, bytes: bytes) }
    func synchronize(_ descriptor: Int32, durable: Bool) throws { try SystemFileOps().synchronize(descriptor, durable: durable) }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        if destination == "branch.json", source.hasPrefix(".macgacha-cache-write-") { _exit(137) }
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws { try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory) }
}

/// Kill after the receipt's temporary file is flushed, before its atomic rename.
/// This process-termination seam exists only in the test executable.
private struct ReceiptWriteCrashOps: FileOps {
    var gameMetadata = false
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try SystemFileOps().write(descriptor, bytes: bytes) }
    func synchronize(_ descriptor: Int32, durable: Bool) throws {
        try SystemFileOps().synchronize(descriptor, durable: durable)
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let status = buffer.withUnsafeMutableBytes { fcntl(descriptor, F_GETPATH, $0.baseAddress!) }
        guard status == 0 else { throw LauncherError.io("Cannot inspect crash-injection descriptor") }
        let path = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        if path.contains("/.macgacha-receipts/.macgacha-write-") { _exit(137) }
        if gameMetadata, path.contains("/genshin/.macgacha-write-") { _exit(137) }
    }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws { try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory) }
}
