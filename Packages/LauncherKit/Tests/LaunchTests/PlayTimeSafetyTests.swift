// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
@testable import Launch

struct PlayTimeSafetyTests {
    @Test func uncertainPublicationIsResyncedWithoutDoubleCounting() throws {
        let temp = try ManagerTemporaryDirectory(), paths = AppPaths(root: temp.url)
        let ops = PlayTimeFaultOps(), id = UUID(), store = PlayTimeStore(paths: paths, fileOps: ops)
        ops.arm()
        #expect(throws: LauncherError.self) {
            try store.record(sessionID: id, game: "genshin", runningSince: Date(timeIntervalSince1970: 100),
                endedAt: Date(timeIntervalSince1970: 400), recovered: false)
        }
        let successfulSyncs = ops.publicationSyncs
        try store.record(sessionID: id, game: "genshin", runningSince: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 400), recovered: false)
        #expect(ops.publicationSyncs > successfulSyncs)
        #expect(try store.load()["genshin"]?.totalSeconds == 300)
    }

    @Test func refusesCompetingWriterAndDoesNotLosePreviousTotal() throws {
        let temp = try ManagerTemporaryDirectory(), paths = AppPaths(root: temp.url), store = PlayTimeStore(paths: paths)
        try store.record(sessionID: UUID(), game: "genshin", runningSince: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 400), recovered: false)
        let fs = try ContainedFileSystem(root: temp.url)
        let lock = try InstallLock(fs: fs, path: SafeRelativePath("PlayTime/.play-time.lock"))
        defer { withExtendedLifetime(lock) {} }
        #expect(throws: LauncherError.self) {
            try store.record(sessionID: UUID(), game: "genshin", runningSince: Date(timeIntervalSince1970: 500),
                endedAt: Date(timeIntervalSince1970: 600), recovered: false)
        }
        #expect(try store.load()["genshin"]?.totalSeconds == 300)
    }

    @Test func unsafeLogAndStoreCannotEscapeContainment() throws {
        let temp = try ManagerTemporaryDirectory(), outside = try ManagerTemporaryDirectory()
        let fs = try ContainedFileSystem(root: temp.url), store = PlayTimeStore(paths: AppPaths(root: temp.url))
        try FileManager.default.createSymbolicLink(atPath: temp.url.appendingPathComponent("Logs").path, withDestinationPath: outside.url.path)
        #expect(try store.backfill()?.sessions == 0)
        try fs.removeFile(at: SafeRelativePath("PlayTime/play-time.json"))
        try FileManager.default.createSymbolicLink(atPath: temp.url.appendingPathComponent("PlayTime/play-time.json").path,
            withDestinationPath: outside.url.appendingPathComponent("untouched.json").path)
        #expect(throws: LauncherError.self) {
            try store.record(sessionID: UUID(), game: "genshin", runningSince: Date(timeIntervalSince1970: 100),
                endedAt: Date(timeIntervalSince1970: 400), recovered: false)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.url.path).isEmpty)
    }

    @Test func corruptMetadataIsNeverReplacedWithEmptyTotals() throws {
        let temp = try ManagerTemporaryDirectory(), fs = try ContainedFileSystem(root: temp.url)
        let path = try SafeRelativePath("PlayTime/play-time.json"), bytes = Data("broken json".utf8)
        try fs.writeAtomically(bytes, to: path)
        let store = PlayTimeStore(paths: AppPaths(root: temp.url))
        #expect(throws: LauncherError.self) { try store.backfill() }
        #expect(try fs.readFile(at: path, maxBytes: 100) == bytes)
    }
}

private final class PlayTimeFaultOps: FileOps, Sendable {
    private struct State { var fail = false; var published = false; var syncs = 0 }
    private let state = Mutex(State())
    var publicationSyncs: Int { state.withLock { $0.syncs } }
    func arm() { state.withLock { $0.fail = true } }
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        try SystemFileOps().write(descriptor, bytes: bytes)
    }
    func synchronize(_ descriptor: Int32, durable: Bool) throws {
        let fail = state.withLock { state in
            guard state.published else { return false }
            state.published = false
            if state.fail { state.fail = false; return true }
            state.syncs += 1
            return false
        }
        if fail { throw LauncherError.io("injected play time publication sync failure") }
        try SystemFileOps().synchronize(descriptor, durable: durable)
    }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
        if destination == "play-time.json" { state.withLock { $0.published = true } }
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws {
        try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory)
    }
}
