// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Testing
@testable import LauncherCore

struct AllocatedStorageTests {
    @Test func sparseFilesHardLinksAndOutsideSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fs = try ContainedFileSystem(root: root)
        let file = try SafeRelativePath("sparse")
        try fs.writeAtomically(Data(repeating: 1, count: 4096), to: file)
        let handle = try fs.openForWriting(at: file, truncate: false)
        try handle.truncate(atOffset: 1 << 30)
        try handle.close()
        try fs.createHardLink(at: SafeRelativePath("alias"), to: file)
        try fs.createSymbolicLink(at: SafeRelativePath("outside"), target: "/Users")
        var info = stat()
        #expect(lstat(file.resolved(against: root).path, &info) == 0)
        #expect(try fs.allocatedBytes(at: file) == Int64(info.st_blocks) * 512)
        #expect(try fs.reclaimableAllocatedBytes(at: [file]) == 0)
        #expect(try fs.reclaimableAllocatedBytes(at: [file, SafeRelativePath("alias")]) == Int64(info.st_blocks) * 512)
        #expect(try fs.allocatedBytes(at: [file, SafeRelativePath("alias")]) == Int64(info.st_blocks) * 512)
        let total = try fs.allocatedBytes()
        #expect(total < 1 << 20)
        try fs.removeFile(at: SafeRelativePath("alias"))
        #expect(try fs.allocatedBytes() == total)
        #expect(try fs.allocatedBytes(at: SafeRelativePath("missing")) == 0)
        #expect(throws: (any Error).self) { try fs.allocatedBytes(at: SafeRelativePath("outside/secret")) }
    }

    @Test func boundedAndCancellable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fs = try ContainedFileSystem(root: root)
        try fs.writeAtomically(Data([1]), to: SafeRelativePath("a/b/file"))
        #expect(throws: (any Error).self) { try fs.allocatedBytes(maximumEntries: 1) }
        #expect(throws: (any Error).self) { try fs.allocatedBytes(maximumDepth: 0) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await BlockingIO.run { try fs.allocatedBytes() }
        }
        await #expect(throws: (any Error).self) { try await task.value }
    }
}
