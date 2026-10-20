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

}

final class InjectedFileOps: FileOps {
    enum Fault: String, CaseIterable, Sendable {
        case noSpaceWrite, noSpaceTransferWrite, shortWrite, sync, renameEXDEV, unlink, deleteUnlink, renameSync
    }
    private struct State { var injected = false; var renamed = false }
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
        let staged = atomic ? location.contains("/.macgacha-write-") : location.contains("/files/")
        if take(staged && fault == .noSpaceWrite) { throw failure }
        if take(fault == .noSpaceTransferWrite && location.hasSuffix(".part")) { throw failure }
        if take(staged && fault == .shortWrite && bytes.count > 1) {
            return try SystemFileOps().write(descriptor, bytes: UnsafeRawBufferPointer(rebasing: bytes[..<(bytes.count / 2)]))
        }
        return try SystemFileOps().write(descriptor, bytes: bytes)
    }
    func synchronize(_ descriptor: Int32, durable: Bool) throws {
        if take(fault == .sync && (atomic ? path(descriptor).contains("/.macgacha-write-") : path(descriptor).contains("/files/") && durable)) {
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
