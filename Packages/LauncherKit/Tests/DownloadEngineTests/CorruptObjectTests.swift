// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import TestSupport

@Suite struct CorruptObjectTests {
    @Test(.timeLimit(.minutes(1))) func eachObjectGetsItsOwnCorruptionRetryBudget() async throws {
        let temp = try TempDir()
        let fs = try ContainedFileSystem(root: temp.url)
        let good = try zstdVector("good")
        let objects = ["a", "b"].map {
            compressedObject(good, mirrors: ["https://cdn.test/\($0)"], id: $0)
        }
        let expected = Data(repeating: 65, count: 8192)
        let file = FileTask(path: try SafeRelativePath("Data/file.bin"), size: 8192,
            digest: zstdDigest(expected), extents: objects.enumerated().map { index, object in
                Extent(source: .chunk(id: object.id), fileOffset: Int64(index * 4096),
                    length: 4096, digest: object.decodedDigest)
            })
        let plan = try stagingPlan(objects, [file])
        let cdn = MockCDN()
        for object in objects {
            cdn.serve(object.id, data: good)
            cdn.enqueueFault(object.id, .corruptByte(at: 0))
        }
        let operation = try InstallOperation(plan: plan, installRoot: temp.url,
            fetcher: stagingFetcher(cdn), disk: FixedDiskSpace(bytes: Int64.max))
        let events = try await collectStaging(operation.run())
        #expect(events.filter { $0 == .phase(.completed) }.count == 1)
        #expect(try fs.readFile(at: file.path, maxBytes: expected.count) == expected)
        for object in objects {
            #expect(cdn.requestLog.filter { $0.path == object.id }.count == 2)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func refetchesCorruptObjectWithoutTransferDigest(validFrameWrongContent: Bool) async throws {
        let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
        let good = try zstdVector("good"); let bad = try corruptedZstd(validFrameWrongContent)
        #expect(bad.count == good.count)
        let object = compressedObject(good, mirrors: ["https://first.test/primary/object", "https://second.test/mirror/object"])
        let file = try compressedFile(object)
        let plan = try stagingPlan([object], [file])
        let cdn = MockCDN(); cdn.serve("primary/object", data: bad); cdn.serve("mirror/object", data: good)
        let operation = try InstallOperation(plan: plan, installRoot: temp.url, fetcher: stagingFetcher(cdn),
            disk: FixedDiskSpace(bytes: Int64.max))
        let events = try await collectStaging(operation.run())
        #expect(events.filter { $0 == .phase(.completed) }.count == 1)
        #expect(cdn.requestLog.map(\.path) == ["primary/object", "mirror/object"])
        #expect(cdn.requestLog.allSatisfy { $0.rangeFrom == nil })
        #expect(try fs.readFile(at: file.path, maxBytes: 4096) == Data(repeating: 65, count: 4096))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func resumeAfterCorruptionDoesNotReuseBadPart(validFrameWrongContent: Bool) async throws {
        let temp = try TempDir(); let good = try zstdVector("good")
        let object = compressedObject(good); let file = try compressedFile(object)
        let plan = try stagingPlan([object], [file])
        let http = CorruptFirstHTTP(first: try corruptedZstd(validFrameWrongContent), good: good)
        let removed = Mutex(false)
        let ops = ZstdTestFileOps(afterUnlink: { name in
            if name == object.partFileName {
                let first = removed.withLock { old in let first = !old; old = true; return first }
                if first { withUnsafeCurrentTask { $0?.cancel() } }
            }
        })
        let first = Task {
            let operation = try InstallOperation(plan: plan, installRoot: temp.url, fetcher: stagingFetcher(http),
                disk: FixedDiskSpace(bytes: Int64.max), fileOps: ops)
            return try await collectStaging(operation.run())
        }
        await #expect(throws: LauncherError.cancelled) { try await first.value }
        #expect(removed.withLock { $0 })
        let fs = try ContainedFileSystem(root: temp.url)
        #expect(try fs.size(at: objectPath(plan, object)) == nil)
        let resumed = try InstallOperation(plan: plan, installRoot: temp.url, fetcher: stagingFetcher(http),
            disk: FixedDiskSpace(bytes: Int64.max))
        #expect(try await collectStaging(resumed.run()).last == .phase(.completed))
        #expect(http.cdn.requestLog.count == 2)
        #expect(http.cdn.requestLog.allSatisfy { $0.rangeFrom == nil })
        #expect(try fs.readFile(at: file.path, maxBytes: 4096) == Data(repeating: 65, count: 4096))
    }

    @Test(.timeLimit(.minutes(1))) func refetchStartsAfterTheMirrorActuallyUsedByTransferRetries() async throws {
        let temp = try TempDir(); let good = try zstdVector("good")
        let object = compressedObject(good, mirrors: ["https://first.test/missing/object",
            "https://second.test/corrupt/object", "https://third.test/good/object"])
        let file = try compressedFile(object); let plan = try stagingPlan([object], [file])
        let cdn = MockCDN()
        cdn.enqueueFault("missing/object", .status(404))
        cdn.serve("corrupt/object", data: try corruptedZstd(false)); cdn.serve("good/object", data: good)
        let fs = try ContainedFileSystem(root: temp.url); let journal = try stagingJournal(fs, plan)
        _ = try await collectStaging(stagingEngine(plan, fs, cdn, journal).stage(files: plan.files))
        #expect(cdn.requestLog.map(\.path) == ["missing/object", "corrupt/object", "good/object"])
        let records = try fs.readFile(at: journalPath(plan), maxBytes: 16_384).split(separator: 10).map {
            try JSONDecoder().decode(JournalRecord.self, from: Data($0))
        }.filter {
            switch $0 { case .objectVerified, .fileUnstaged, .fileStaged: true; default: false }
        }
        #expect(records == [.objectVerified(id: object.id), .fileUnstaged(path: file.path),
            .objectVerified(id: object.id), .fileStaged(path: file.path)])
    }

    @Test(.timeLimit(.minutes(1))) func resumeWithVerifiedCorruptPartReachesHealthyLaterMirror() async throws {
        let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
        let good = try zstdVector("good"); let bad = try corruptedZstd(false)
        let object = compressedObject(good, mirrors: ["https://first.test/missing/object",
            "https://second.test/corrupt/object", "https://third.test/good/object"])
        let file = try compressedFile(object); let plan = try stagingPlan([object], [file])
        let journal = try stagingJournal(fs, plan)
        // Exact persistent state of a crash after objectVerified: mirror 0 was unavailable,
        // mirror 1 supplied this right-length bad part, and source identity wasn't journaled.
        try fs.writeAtomically(bad, to: objectPath(plan, object))
        try await journal.append(.objectVerified(id: object.id))
        let cdn = MockCDN()
        cdn.enqueueFault("missing/object", .status(404))
        cdn.serve("corrupt/object", data: bad); cdn.serve("good/object", data: good)
        let events = try await collectStaging(stagingEngine(plan, fs, cdn, journal).stage(files: plan.files))
        #expect(events.contains(.fileVerified(file.path)))
        #expect(cdn.requestLog.map(\.path) == ["corrupt/object", "good/object"])
        #expect(cdn.requestLog.allSatisfy { $0.rangeFrom == nil })
        #expect(try fs.readFile(at: stagedPath(plan, file.path), maxBytes: 4096) == Data(repeating: 65, count: 4096))
    }

    @Test(.timeLimit(.minutes(1))) func corruptCachedObjectExhaustionIsBoundedAndLeavesNoPart() async throws {
        let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
        let bad = try corruptedZstd(false)
        let object = compressedObject(try zstdVector("good"), mirrors: ["https://cdn.test/first",
            "https://cdn.test/second", "https://cdn.test/third"])
        let file = try compressedFile(object); let plan = try stagingPlan([object], [file])
        let journal = try stagingJournal(fs, plan)
        try fs.writeAtomically(bad, to: objectPath(plan, object))
        try await journal.append(.objectVerified(id: object.id))
        let cdn = MockCDN()
        for name in ["first", "second", "third"] { cdn.serve(name, data: bad) }
        await #expect(throws: CorruptObjectError.self) {
            try await collectStaging(stagingEngine(plan, fs, cdn, journal).stage(files: plan.files))
        }
        #expect(cdn.requestLog.map(\.path) == ["second", "third", "first"])
        #expect(try fs.size(at: objectPath(plan, object)) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func resumedUnverifiedFullPartAlsoCanReachHealthyMirror() async throws {
        let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
        let good = try zstdVector("good"); let bad = try corruptedZstd(false)
        let object = compressedObject(good, mirrors: ["https://cdn.test/first",
            "https://cdn.test/second", "https://cdn.test/third"])
        let file = try compressedFile(object); let plan = try stagingPlan([object], [file])
        let journal = try stagingJournal(fs, plan)
        // Crash before objectVerified: the full part's source is unknown. A successful
        // 416 size check at mirror 0 does not mean that mirror supplied these bad bytes.
        try fs.writeAtomically(bad, to: objectPath(plan, object))
        let cdn = MockCDN()
        cdn.serve("first", data: good); cdn.serve("second", data: bad); cdn.serve("third", data: good)
        _ = try await collectStaging(stagingEngine(plan, fs, cdn, journal).stage(files: plan.files))
        #expect(cdn.requestLog.map(\.path) == ["first", "second", "third"])
        #expect(cdn.requestLog.map(\.rangeFrom) == [Int64(bad.count), nil, nil])
        #expect(try fs.readFile(at: stagedPath(plan, file.path), maxBytes: 4096) == Data(repeating: 65, count: 4096))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [LauncherError.cancelled, LauncherError.io("No space left on device (errno 28)")])
    func cancellationAndENOSPCAreNotCorruption(failure: LauncherError) async throws {
        let temp = try TempDir(); let good = try zstdVector("good")
        let object = compressedObject(good); let file = try compressedFile(object)
        let plan = try stagingPlan([object], [file]); let cdn = MockCDN(); cdn.serve("object", data: good)
        let injected = Mutex(false)
        let ops = ZstdTestFileOps(onWrite: { descriptor, _ in
            var bytes = [CChar](repeating: 0, count: Int(PATH_MAX))
            let result = bytes.withUnsafeMutableBufferPointer { fcntl(descriptor, F_GETPATH, $0.baseAddress!) }
            let name = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if result == 0, name.contains("/files/") {
                injected.withLock { $0 = true }
                throw failure
            }
            return nil
        })
        let fs = try ContainedFileSystem(root: temp.url, fileOps: ops)
        let journal = try stagingJournal(fs, plan)
        await #expect(throws: failure) {
            try await collectStaging(stagingEngine(plan, fs, cdn, journal).stage(files: plan.files))
        }
        #expect(injected.withLock { $0 })
        #expect(cdn.requestLog.count == 1)
        #expect(try fs.readFile(at: objectPath(plan, object), maxBytes: good.count) == good)
        let records = try fs.readFile(at: journalPath(plan), maxBytes: 16_384)
        #expect(!String(decoding: records, as: UTF8.self).contains("fileUnstaged"))
    }
}

func compressedObject(_ encoded: Data, mirrors: [String] = ["https://cdn.test/object"], id: String = "object", byte: UInt8 = 65) -> ChunkObject {
    ChunkObject(id: id, urls: mirrors.map { URL(string: $0)! }, transferSize: Int64(encoded.count),
        decodedSize: 4096, decodedDigest: zstdDigest(Data(repeating: byte, count: 4096)), codec: .zstd)
}
func compressedFile(_ object: ChunkObject, path: String = "Data/file.bin") throws -> FileTask {
    FileTask(path: try SafeRelativePath(path), size: object.decodedSize, digest: object.decodedDigest,
        extents: [Extent(source: .chunk(id: object.id), fileOffset: 0, length: object.decodedSize, digest: object.decodedDigest)])
}
private func corruptedZstd(_ valid: Bool) throws -> Data {
    if valid { return try zstdVector("wrong") }
    var bytes = try zstdVector("good"); bytes[0] ^= 1; return bytes
}
private final class CorruptFirstHTTP: HTTPClient, Sendable {
    let cdn = MockCDN()
    private let count = Mutex(0)
    private let first: Data; private let good: Data
    init(first: Data, good: Data) { self.first = first; self.good = good }
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        let initial = count.withLock { value in value += 1; return value == 1 }
        cdn.serve("object", data: initial ? first : good)
        return try await cdn.get(url, byteRangeFrom: offset)
    }
}
