// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import TestSupport

struct FaultInjectionTests {
    @Test(arguments: [EDQUOT, ENOSPC], ["part", "output", "rename", "sync", "journal"])
    func allocationFailurePausesAndResumes(code: Int32, point: String) async throws {
        let root = try TempDir(), fs = try ContainedFileSystem(root: root.url), cdn = MockCDN()
        let body = String(repeating: "Q", count: 160_000)
        let plan = try opPlan("quota-resume", [("out", body)])
        opServe(cdn, plan, [body])
        let ops = AllocationFailureOps(code: code, point: point)
        let engine = try InstallOperation(plan: plan, installRoot: root.url, fetcher: stagingFetcher(cdn),
            disk: FixedDiskSpace(bytes: Int64.max), fileOps: ops)
        do {
            _ = try await opCollect(engine.run())
            Issue.record("Expected allocation failure")
        } catch let error as LauncherError {
            if case .insufficientSpace = error {} else { Issue.record("Unexpected error: \(error)") }
        }
        #expect(ops.injected)
        let state = try OperationJournal.replay(fs: fs, path: opJournal(plan))
        #expect(!state.completed)
        if point == "part" {
            #expect(state.verifiedObjects.isEmpty)
            #expect(try fs.size(at: objectPath(plan, plan.objects.values.first!)) == nil)
        }
        #expect(try await opCollect(engine.run()).last == .phase(.completed))
        #expect(try fs.readFile(at: plan.files[0].path, maxBytes: body.utf8.count) == Data(body.utf8))
    }

    @Test(arguments: InjectedFileOps.Fault.allCases)
    func fileFaultLeavesIntactOrRecoverableInstall(fault: InjectedFileOps.Fault) async throws {
        let fixtures = try TempDir(); let root = try TempDir()
        let plan = try crashFixture(fixtures.url, root: root.url)
        let ops = InjectedFileOps(fault)
        if fault == .shortWrite {
            try await finishFixture(plan, fixtures: fixtures.url, root: root.url, fileOps: ops)
            try assertFixture(plan, root: root.url)
        } else {
            await #expect(throws: ops.failure) {
                try await finishFixture(plan, fixtures: fixtures.url, root: root.url, fileOps: ops)
            }
            let fs = try ContainedFileSystem(root: root.url)
            if [.noSpaceWrite, .noSpaceTransferWrite, .sync, .unlink].contains(fault) {
                #expect(try fs.readFile(at: plan.files[0].path, maxBytes: 100) == Data("old-a".utf8))
                #expect(try fs.readFile(at: plan.files[1].path, maxBytes: 100) == Data("old-b".utf8))
                #expect(try InstallStateMarker.load(fs: fs) == nil)
            } else {
                #expect(try InstallStateMarker.load(fs: fs) != nil)
                #expect(try OperationJournal.replay(fs: fs, path: opJournal(plan)).commitStartedBatches == [0])
            }
            try await finishFixture(plan, fixtures: fixtures.url, root: root.url)
            try assertFixture(plan, root: root.url)
        }
        #expect(ops.injected)
    }
    @Test(arguments: [InjectedFileOps.Fault.noSpaceWrite, .shortWrite, .sync, .renameEXDEV])
    func atomicWriteFaultsPreservePublishedBytes(fault: InjectedFileOps.Fault) throws {
        let temp = try TempDir()
        let original = try ContainedFileSystem(root: temp.url)
        let path = try SafeRelativePath("dir/value")
        try original.writeAtomically(Data("old".utf8), to: path)
        let ops = InjectedFileOps(fault, atomic: true)
        let fs = try ContainedFileSystem(root: temp.url, fileOps: ops)
        let bytes = Data(repeating: 0x61, count: 160_000)
        if fault == .shortWrite {
            try fs.writeAtomically(bytes, to: path)
            #expect(try fs.readFile(at: path, maxBytes: bytes.count) == bytes)
        } else {
            #expect(throws: ops.failure) { try fs.writeAtomically(bytes, to: path) }
            #expect(try fs.readFile(at: path, maxBytes: 3) == Data("old".utf8))
            // Retrying uses the same real production operations after the one-shot fault.
            try fs.writeAtomically(bytes, to: path)
            #expect(try fs.readFile(at: path, maxBytes: bytes.count) == bytes)
        }
        #expect(ops.injected)
        #expect(try fs.contentsOfDirectory(at: SafeRelativePath("dir")) == [path])
    }

    @Test
    func partialJournalAppendRequiresReopenThenInstallResumes() async throws {
        let fixtures = try TempDir(); let root = try TempDir()
        let plan = try crashFixture(fixtures.url, root: root.url)
        let ops = InjectedFileOps(.journalWrite)
        let fs = try ContainedFileSystem(root: root.url, fileOps: ops)
        let journal = try await opSeed(fs, plan, commit: true)
        let object = try ContainedFileSystem(root: fixtures.url).readFile(at: SafeRelativePath("crash-0"), maxBytes: 160_000)
        try fs.writeAtomically(object, to: opStaged(plan, plan.files[0].path))
        try fs.writeAtomically(object + object, to: opStaged(plan, plan.files[1].path))
        try fs.rename(from: opStaged(plan, plan.files[0].path), to: plan.files[0].path)
        let before = try fs.readFile(at: opJournal(plan), maxBytes: 65_536)
        await #expect(throws: ops.failure) { try await journal.append(.fileCommitted(path: plan.files[0].path)) }
        #expect(ops.injected)
        let torn = try fs.readFile(at: opJournal(plan), maxBytes: 65_536)
        #expect(torn.starts(with: before) && torn.count > before.count)
        #expect(torn.last != 0x0a)
        #expect(try OperationJournal.replay(fs: fs, path: opJournal(plan)).committedFiles.isEmpty)
        await #expect(throws: LauncherError.journalCorrupt("Reopen journal after failed append")) {
            try await journal.append(.fileCommitted(path: plan.files[0].path))
        }
        #expect(try fs.readFile(at: opJournal(plan), maxBytes: 65_536) == torn)
        // InstallOperation reopens the journal, truncates the torn tail and recovers
        // the rename-to-journal gap by verifying the destination's size and digest.
        try await finishFixture(plan, fixtures: fixtures.url, root: root.url)
        try assertFixture(plan, root: root.url)
    }

}

final class InjectedFileOps: FileOps {
    enum Fault: String, CaseIterable, Sendable {
        case noSpaceWrite, noSpaceTransferWrite, shortWrite, sync, renameEXDEV, unlink, deleteUnlink, renameSync, journalWrite
    }
    private struct State { var injected = false; var renamed = false; var journalWritePending = false }
    private let state = Mutex(State())
    let fault: Fault
    let atomic: Bool
    init(_ fault: Fault, atomic: Bool = false) { self.fault = fault; self.atomic = atomic }
    var failure: LauncherError {
        let code = switch fault {
        case .noSpaceWrite, .noSpaceTransferWrite: ENOSPC
        case .renameEXDEV: EXDEV
        default: EIO
        }
        return .io("injected \(fault.rawValue) (errno \(code))")
    }
    var injected: Bool { state.withLock { $0.injected } }
    private func take(_ matches: Bool) -> Bool {
        state.withLock { guard matches, !$0.injected else { return false }; $0.injected = true; return true }
    }
    private func path(_ fd: Int32) -> String {
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &bytes) == 0 else { return "" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        let location = path(descriptor)
        if fault == .journalWrite, location.hasSuffix("/journal.jsonl") {
            let action = state.withLock { state -> Int in
                if state.journalWritePending {
                    state.journalWritePending = false
                    return 2
                }
                if !state.injected, bytes.count > 1,
                   String(decoding: bytes, as: UTF8.self).contains("\"type\":\"fileCommitted\"") {
                    state.injected = true; state.journalWritePending = true
                    return 1
                }
                return 0
            }
            if action == 1 {
                return try SystemFileOps().write(descriptor, bytes: UnsafeRawBufferPointer(rebasing: bytes[..<(bytes.count / 2)]))
            }
            if action == 2 { throw failure }
        }
        let staged = atomic ? location.contains("/.macgacha-write-") : location.contains("/files/")
        if take(staged && fault == .noSpaceWrite) { throw failure }
        if take(fault == .noSpaceTransferWrite && location.hasSuffix(".part")) { throw failure }
        if take(staged && fault == .shortWrite && bytes.count > 1) {
            return try SystemFileOps().write(descriptor, bytes: UnsafeRawBufferPointer(rebasing: bytes[..<(bytes.count / 2)]))
        }
        return try SystemFileOps().write(descriptor, bytes: bytes)
    }
    func synchronize(_ descriptor: Int32, durable: Bool) throws {
        if take(fault == .sync && (atomic ? path(descriptor).contains("/.macgacha-write-") : path(descriptor).contains("/files/"))) {
            throw failure
        }
        if take(fault == .renameSync && state.withLock({ $0.renamed })) {
            throw failure
        }
        try SystemFileOps().synchronize(descriptor, durable: durable)
    }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String,
        in destinationDirectory: Int32, exclusive: Bool) throws {
        let staged = atomic ? source.hasPrefix(".macgacha-write-") : path(sourceDirectory).contains("/files/")
        if take(fault == .renameEXDEV && staged) { throw failure }
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
        if staged { state.withLock { $0.renamed = true } }
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws {
        if take((fault == .unlink && name.hasSuffix(".part")) || (fault == .deleteUnlink && name == "obsolete")) {
            throw failure
        }
        try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory)
    }
}

/// Raw POSIX errors exercise the same normalization as failing filesystem syscalls.
private final class AllocationFailureOps: FileOps {
    let code: Int32
    let point: String
    private struct State { var writes = 0; var injected = false; var tornJournal = false }
    private let state = Mutex(State())
    init(code: Int32, point: String) { self.code = code; self.point = point }
    var injected: Bool { state.withLock { $0.injected } }
    private func path(_ fd: Int32) -> String {
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &bytes) == 0 else { return "" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    private func fail(_ matches: Bool) throws {
        if state.withLock({ s in guard matches, !s.injected else { return false }; s.injected = true; return true }) {
            throw POSIXError(POSIXErrorCode(rawValue: code)!)
        }
    }
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        let path = path(descriptor)
        if point == "journal", path.hasSuffix("/journal.jsonl") {
            if state.withLock({ $0.tornJournal }) { try fail(true) }
            let begin = state.withLock { s in
                guard !s.injected, !s.tornJournal,
                    String(decoding: bytes, as: UTF8.self).contains("\"type\":\"fileStaged\"") else { return false }
                s.tornJournal = true; return true
            }
            if begin {
                return try SystemFileOps().write(descriptor, bytes: UnsafeRawBufferPointer(rebasing: bytes[..<(bytes.count / 2)]))
            }
        }
        let matches = point == "part" ? path.hasSuffix(".part") : point == "output" && path.contains("/files/")
        let second = state.withLock { s in if matches { s.writes += 1 }; return s.writes >= 2 }
        try fail(matches && second)
        return try SystemFileOps().write(descriptor, bytes: bytes)
    }
    func synchronize(_ descriptor: Int32, durable: Bool) throws {
        try fail(point == "sync" && path(descriptor).contains("/files/"))
        try SystemFileOps().synchronize(descriptor, durable: durable)
    }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String,
        in destinationDirectory: Int32, exclusive: Bool) throws {
        try fail(point == "rename" && path(sourceDirectory).contains("/files"))
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws {
        try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory)
    }
}
