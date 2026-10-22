// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).

import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import TestSupport

@Test
func fetchWholeObject() async throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let cdn = MockCDN()
    let bytes = fetchBlob()
    cdn.serve("object", data: bytes)
    let progress = Mutex([Int64]())
    let object = fetchObject(bytes, codec: .zstd, decodedSize: Int64(bytes.count * 2))
    let part = directory.url.appendingPathComponent(object.partFileName)
    try await testFetcher(cdn).fetch(object, fs: fs, part: try SafeRelativePath(part.lastPathComponent), progress: { n in progress.withLock { $0.append(n) } })
    #expect(try Data(contentsOf: part) == bytes)
    #expect(progress.withLock { $0.last } == Int64(bytes.count))
    #expect(progress.withLock { $0.allSatisfy { $0 >= 0 && $0 <= Int64(bytes.count) } })
    #expect(cdn.requestLog.count == 1)
}

@Test
func resumeFromPart() async throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let cdn = MockCDN()
    let bytes = fetchBlob()
    cdn.serve("object", data: bytes)
    let part = directory.url.appendingPathComponent("object.part")
    try Data(bytes.prefix(60_000)).write(to: part)
    try await testFetcher(cdn).fetch(fetchObject(bytes), fs: fs, part: try SafeRelativePath(part.lastPathComponent), progress: { _ in })
    #expect(cdn.requestLog.map(\.rangeFrom) == [60_000])
    #expect(try Data(contentsOf: part) == bytes)
}

@Test
func restartWhenRangeIgnored() async throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let cdn = MockCDN()
    let bytes = fetchBlob()
    cdn.serve("object", data: bytes)
    cdn.enqueueFault("object", .ignoreRange)
    let part = directory.url.appendingPathComponent("object.part")
    try Data(bytes.prefix(60_000)).write(to: part)
    let progress = Mutex([Int64]())
    try await testFetcher(cdn).fetch(fetchObject(bytes), fs: fs, part: try SafeRelativePath(part.lastPathComponent), progress: { n in progress.withLock { $0.append(n) } })
    #expect(cdn.requestLog.map(\.rangeFrom) == [60_000])
    #expect(progress.withLock { $0.contains(0) })
    #expect(try Data(contentsOf: part) == bytes)
}

@Test
func retryAfterDropAndCorruption() async throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let cdn = MockCDN()
    let bytes = fetchBlob()
    cdn.serve("object", data: bytes)
    cdn.enqueueFault("object", .dropAfter(bytes: 70_000))
    cdn.enqueueFault("object", .corruptByte(at: 0))
    let sleeper = InstantSleeper()
    let part = directory.url.appendingPathComponent("object.part")
    try await testFetcher(cdn, sleeper: sleeper).fetch(fetchObject(bytes), fs: fs, part: try SafeRelativePath(part.lastPathComponent), progress: { _ in })
    #expect(cdn.requestLog.map(\.rangeFrom) == [nil, 70_000, nil])
    #expect(sleeper.delays.count == 2)
    #expect(try Data(contentsOf: part) == bytes)
}

@Test
func mirrorFallback() async throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let cdn = MockCDN()
    let bytes = fetchBlob()
    cdn.serve("primary", data: bytes)
    cdn.serve("mirror", data: bytes)
    cdn.enqueueFault("primary", .status(503, retryAfter: .seconds(7)))
    let object = fetchObject(bytes, paths: ["primary", "mirror"])
    let sleeper = InstantSleeper()
    let part = directory.url.appendingPathComponent("object.part")
    try await testFetcher(cdn, sleeper: sleeper).fetch(object, fs: fs, part: try SafeRelativePath(part.lastPathComponent), progress: { _ in })
    #expect(cdn.requestLog.map(\.path) == ["primary", "mirror"])
    #expect(sleeper.delays == [.seconds(7)])
    #expect(try Data(contentsOf: part) == bytes)
}

@Test(arguments: [404, 410])
func missingMirrorFallsBackWithoutDelay(status: Int) async throws {
    let directory = try TempDir(); let fs = try ContainedFileSystem(root: directory.url)
    let cdn = MockCDN(); let bytes = fetchBlob()
    let object = fetchObject(bytes, paths: ["missing", "mirror"])
    cdn.enqueueFault("missing", .status(status)); cdn.serve("mirror", data: bytes)
    let sleeper = InstantSleeper()
    try await testFetcher(cdn, sleeper: sleeper, attempts: 1).fetch(object, fs: fs, part: SafeRelativePath("object.part"), progress: { _ in })
    #expect(cdn.requestLog.map(\.path) == ["missing", "mirror"])
    #expect(sleeper.delays.isEmpty)
    #expect(try fs.readFile(at: SafeRelativePath("object.part"), maxBytes: bytes.count) == bytes)
}

@Test
func allMissingMirrorsFailWithoutDelay() async throws {
    let directory = try TempDir(); let fs = try ContainedFileSystem(root: directory.url)
    let cdn = MockCDN(); let object = fetchObject(fetchBlob(), paths: ["missing", "mirror"])
    let sleeper = InstantSleeper()
    await #expect(throws: LauncherError.http(status: 404, url: object.urls[1])) {
        try await testFetcher(cdn, sleeper: sleeper).fetch(object, fs: fs, part: SafeRelativePath("object.part"), progress: { _ in })
    }
    #expect(cdn.requestLog.map(\.path) == ["missing", "mirror"])
    #expect(sleeper.delays.isEmpty)
}

@Test
func cleanTruncatedBodyResumesFromWrittenBytes() async throws {
    let directory = try TempDir(); let fs = try ContainedFileSystem(root: directory.url)
    let client = RecoveringFetchClient(malformedRange: false)
    try await testFetcher(client).fetch(fetchObject(Data("abcdef".utf8)), fs: fs, part: SafeRelativePath("part"), progress: { _ in })
    #expect(client.ranges.withLock { $0 } == [nil, 3])
    #expect(try fs.readFile(at: SafeRelativePath("part"), maxBytes: 6) == Data("abcdef".utf8))
}

@Test
func malformedContentRangeRestartsWithoutRange() async throws {
    let directory = try TempDir(); let fs = try ContainedFileSystem(root: directory.url)
    try fs.writeAtomically(Data("abc".utf8), to: SafeRelativePath("part"))
    let client = RecoveringFetchClient(malformedRange: true)
    try await testFetcher(client).fetch(fetchObject(Data("abcdef".utf8)), fs: fs, part: SafeRelativePath("part"), progress: { _ in })
    #expect(client.ranges.withLock { $0 } == [3, nil])
    #expect(try fs.readFile(at: SafeRelativePath("part"), maxBytes: 6) == Data("abcdef".utf8))
}

@Test
func blockedChunkWriteDoesNotSerializeOtherFetches() async throws {
    let directory = try TempDir(); let blocker = FetchBlockingWrite()
    let blockedFS = try ContainedFileSystem(root: directory.url, fileOps: blocker)
    let otherFS = try ContainedFileSystem(root: directory.url)
    let cdn = MockCDN(); let bytes = Data("abc".utf8); cdn.serve("object", data: bytes)
    let fetcher = testFetcher(cdn); let finished = Mutex(false)
    let first = Task { try await fetcher.fetch(fetchObject(bytes), fs: blockedFS, part: SafeRelativePath("first"), progress: { _ in }) }
    defer { blocker.release.signal(); first.cancel() }
    let clock = ContinuousClock(); let deadline = clock.now.advanced(by: .seconds(3))
    while !blocker.entered.withLock({ $0 }) && clock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    try #require(blocker.entered.withLock { $0 })
    let second = Task {
        try await fetcher.fetch(fetchObject(bytes), fs: otherFS, part: SafeRelativePath("second"), progress: { _ in })
        finished.withLock { $0 = true }
    }
    defer { second.cancel() }
    let otherDeadline = clock.now.advanced(by: .seconds(2))
    while !finished.withLock({ $0 }) && clock.now < otherDeadline { try await Task.sleep(for: .milliseconds(1)) }
    #expect(finished.withLock { $0 })
    blocker.release.signal()
    try await first.value; try await second.value
}

@Test
func cancellationKeepsPart() async throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let cdn = MockCDN()
    let bytes = fetchBlob()
    cdn.serve("object", data: bytes)
    let fetcher = testFetcher(cdn)
    let part = directory.url.appendingPathComponent("object.part")
    let task = Task {
        try await fetcher.fetch(fetchObject(bytes), fs: fs, part: try SafeRelativePath(part.lastPathComponent), progress: { count in
            if count > 0 { withUnsafeCurrentTask { $0?.cancel() } }
        })
    }
    await #expect(throws: LauncherError.cancelled) { try await task.value }
    let partial = try Data(contentsOf: part)
    #expect(!partial.isEmpty && partial.count < bytes.count)
    #expect(partial == bytes.prefix(partial.count))
    #expect(cdn.requestLog.count == 1)
    try await fetcher.fetch(fetchObject(bytes), fs: fs, part: try SafeRelativePath(part.lastPathComponent), progress: { _ in })
    #expect(cdn.requestLog.last?.rangeFrom == Int64(partial.count))
    #expect(try Data(contentsOf: part) == bytes)
}

@Test
func completePartIsVerifiedAfter416() async throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let cdn = MockCDN()
    let bytes = fetchBlob()
    cdn.serve("object", data: bytes)
    let part = directory.url.appendingPathComponent("object.part")
    try bytes.write(to: part)
    try await testFetcher(cdn).fetch(fetchObject(bytes), fs: fs, part: try SafeRelativePath(part.lastPathComponent), progress: { _ in })
    #expect(cdn.requestLog.map(\.rangeFrom) == [Int64(bytes.count)])
    #expect(try Data(contentsOf: part) == bytes)
    try Data(bytes.prefix(20)).write(to: part)
    cdn.enqueueFault("object", .status(416))
    try await testFetcher(cdn).fetch(fetchObject(bytes), fs: fs, part: try SafeRelativePath(part.lastPathComponent), progress: { _ in })
    #expect(cdn.requestLog.map(\.rangeFrom) == [Int64(bytes.count), 20, nil])
    #expect(try Data(contentsOf: part) == bytes)
}

@Test
func fetchRejectsMalformedRangeAndOverlongBody() async throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let part = directory.url.appendingPathComponent("object.part")
    try Data("abc".utf8).write(to: part)
    let client = FixedFetchClient(head: HTTPResponseHead(status: 206, contentLength: 3, contentRange: 0...2, totalLength: 6),
        state: FetchTestBodyState(pieces: [Data("def".utf8)]))
    await #expect(throws: LauncherError.transport("invalid content range")) {
        try await testFetcher(client, attempts: 1).fetch(fetchObject(Data("abcdef".utf8)), fs: fs, part: try SafeRelativePath(part.lastPathComponent), progress: { _ in })
    }
    #expect(try Data(contentsOf: part).isEmpty)
    try FileManager.default.removeItem(at: part)
    let overlong = FixedFetchClient(head: HTTPResponseHead(status: 200), state: FetchTestBodyState(pieces: [Data("abcdef".utf8)]))
    await #expect(throws: LauncherError.sizeMismatch(path: "object", expected: 3, actual: 6)) {
        try await testFetcher(overlong, attempts: 1).fetch(fetchObject(Data("abc".utf8)), fs: fs, part: try SafeRelativePath(part.lastPathComponent), progress: { _ in })
    }
    #expect(!FileManager.default.fileExists(atPath: part.path))
}

@Test
func completedBytesDoNotWaitForAnUnfinishedStream() async throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let bytes = Data("abc".utf8)
    let state = FetchTestBodyState(pieces: [bytes], stall: true)
    let client = FixedFetchClient(head: HTTPResponseHead(status: 200, contentLength: 3), state: state)
    let part = directory.url.appendingPathComponent("object.part")
    let task = Task { try await testFetcher(client).fetch(fetchObject(bytes), fs: fs, part: try SafeRelativePath(part.lastPathComponent), progress: { _ in }) }
    let watchdog = Task { try await Task.sleep(for: .seconds(5)); task.cancel() }
    defer { watchdog.cancel() }
    try await task.value
    #expect(state.calls == 1)
    #expect(state.cancelled)
    #expect(try Data(contentsOf: part) == bytes)
}

@Test
func fetchWithoutTransferDigestChecksOnlyTransferSize() async throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let cdn = MockCDN()
    let bytes = Data("abc".utf8)
    cdn.serve("object", data: bytes)
    let reference = fetchObject(Data("different".utf8))
    let object = ChunkObject(id: "object", urls: reference.urls, transferSize: 3,
        decodedSize: 3, decodedDigest: reference.decodedDigest, codec: .identity)
    let part = directory.url.appendingPathComponent("object.part")
    try await testFetcher(cdn).fetch(object, fs: fs, part: try SafeRelativePath(part.lastPathComponent), progress: { _ in })
    #expect(try Data(contentsOf: part) == bytes)
}

@Test
func cancellingStalledFetchCancelsBody() async throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let prefix = Data("abc".utf8)
    let state = FetchTestBodyState(pieces: [prefix], stall: true)
    let client = FixedFetchClient(head: HTTPResponseHead(status: 200, contentLength: 6), state: state)
    let part = directory.url.appendingPathComponent("object.part")
    let task = Task { try await testFetcher(client).fetch(fetchObject(Data("abcdef".utf8)), fs: fs, part: try SafeRelativePath(part.lastPathComponent), progress: { _ in }) }
    defer { task.cancel() }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while state.calls < 2 && clock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    #expect(state.calls == 2)
    task.cancel()
    await #expect(throws: LauncherError.cancelled) { try await task.value }
    #expect(state.cancelled)
    #expect(try Data(contentsOf: part) == prefix)
}

@Test
func unsafePartLeavesAreRefusedWithoutChangingOutsideFiles() async throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let outside = try TempDir()
    let cdn = MockCDN()
    let bytes = Data("abc".utf8)
    cdn.serve("object", data: bytes)
    let control = outside.url.appendingPathComponent("control")
    try Data("preserved".utf8).write(to: control)
    let symlink = directory.url.appendingPathComponent("link")
    let hardlink = directory.url.appendingPathComponent("hardlink")
    let folder = directory.url.appendingPathComponent("folder")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: control)
    try FileManager.default.linkItem(at: control, to: hardlink)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let fetcher = testFetcher(cdn)
    for part in [symlink, hardlink, folder] {
        await #expect(throws: LauncherError.unsafePath(part.path)) {
            try await fetcher.fetch(fetchObject(bytes), fs: fs, part: try SafeRelativePath(part.lastPathComponent), progress: { _ in })
        }
        #expect(try Data(contentsOf: control) == Data("preserved".utf8))
    }
    #expect(cdn.requestLog.isEmpty)
}

@Test
func symlinkPartParentIsRefusedWithoutWritingOutside() async throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let outside = try TempDir()
    let cdn = MockCDN()
    let bytes = Data("abc".utf8)
    cdn.serve("object", data: bytes)
    let parent = directory.url.appendingPathComponent("parts")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    try FileManager.default.removeItem(at: parent)
    try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside.url)
    let control = outside.url.appendingPathComponent("object.part")
    try Data("preserved".utf8).write(to: control)
    await #expect(throws: LauncherError.unsafePath(parent.path)) {
        try await testFetcher(cdn).fetch(fetchObject(bytes), fs: fs, part: try SafeRelativePath("parts/object.part"), progress: { _ in })
    }
    #expect(try Data(contentsOf: control) == Data("preserved".utf8))
    await #expect(throws: LauncherError.unsafePath(parent.path)) {
        try await testFetcher(cdn).fetch(fetchObject(bytes), fs: fs, part: try SafeRelativePath("parts/new.part"), progress: { _ in })
    }
    #expect(!FileManager.default.fileExists(atPath: outside.url.appendingPathComponent("new.part").path))
    #expect(cdn.requestLog.isEmpty)
}

@Test
func zstdCodecReportsSupported() throws {
    #expect(try ChunkCodec.zstd.decoder() is ZstdDecoder)
}

@Test
func identityDecoderCopiesAtOffsetAndChecksSize() throws {
    let directory = try TempDir()
    let outside = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let part = try SafeRelativePath("object")
    let target = try SafeRelativePath("output")
    try fs.writeAtomically(Data("hello".utf8), to: part)
    try fs.writeAtomically(Data("XX".utf8), to: target)
    let transferred = try fs.openForReading(at: part)
    defer { try? transferred.close() }
    // The decoder must use this descriptor even if the old pathname now points outside.
    try fs.removeFile(at: part)
    let control = outside.url.appendingPathComponent("control")
    try Data("secret".utf8).write(to: control)
    try FileManager.default.createSymbolicLink(at: part.resolved(against: directory.url), withDestinationURL: control)
    let output = try fs.openForWriting(at: target, truncate: false)
    defer { try? output.close() }
    try transferred.seek(toOffset: 3)
    try ChunkCodec.identity.decoder().decode(transferred, expectedSize: 5, into: output, at: 2)
    #expect(try fs.readFile(at: target, maxBytes: 20) == Data("XXhello".utf8))
    #expect(throws: LauncherError.sizeMismatch(path: "transferred object", expected: 4, actual: 5)) {
        try IdentityDecoder().decode(transferred, expectedSize: 4, into: output, at: 0)
    }
    try transferred.seek(toOffset: 0)
    #expect(try transferred.read(upToCount: 5) == Data("hello".utf8))
    try output.write(contentsOf: Data("!".utf8))
    #expect(try fs.readFile(at: target, maxBytes: 20) == Data("XXhello!".utf8))
    #expect(try Data(contentsOf: control) == Data("secret".utf8))
}

@Test
func identityDecoderRejectsInvalidRangesAndSameFileHandles() throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let path = try SafeRelativePath("object")
    try fs.writeAtomically(Data("hello".utf8), to: path)
    let source = try fs.openForReading(at: path)
    defer { try? source.close() }
    let output = try fs.openForWriting(at: try SafeRelativePath("output"), truncate: false)
    defer { try? output.close() }
    let decoder = IdentityDecoder()
    for (size, offset) in [(Int64(-1), Int64(0)), (5, -1), (5, Int64.max)] {
        #expect(throws: LauncherError.io("Invalid decode range")) {
            try decoder.decode(source, expectedSize: size, into: output, at: offset)
        }
    }
    let sameFile = try fs.openForWriting(at: path, truncate: false)
    defer { try? sameFile.close() }
    #expect(throws: LauncherError.io("Decoder requires distinct regular files")) {
        try decoder.decode(source, expectedSize: 5, into: sameFile, at: 0)
    }
    #expect(try fs.readFile(at: path, maxBytes: 5) == Data("hello".utf8))
}

@Test(arguments: [false, true])
func concurrentCaseVariantPartsAreBusy(varyRoot: Bool) async throws {
    let directory = try TempDir()
    let root = directory.url.appendingPathComponent("InstallRoot")
    let fs = try ContainedFileSystem(root: root)
    let otherFS = varyRoot ? try ContainedFileSystem(root: directory.url.appendingPathComponent("INSTALLROOT/./")) : fs
    let state = FetchTestBodyState(pieces: [], stall: true)
    let client = FixedFetchClient(head: HTTPResponseHead(status: 200, contentLength: 3), state: state)
    let fetcher = testFetcher(client)
    let object = fetchObject(Data("abc".utf8))
    let first = Task { try await fetcher.fetch(object, fs: fs, part: SafeRelativePath("Parts/Object.part"), progress: { _ in }) }
    defer { first.cancel() }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while state.calls == 0 && clock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    try #require(state.calls == 1)
    let second = Task { try await fetcher.fetch(object, fs: otherFS, part: SafeRelativePath("parts/OBJECT.PART"), progress: { _ in }) }
    let watchdog = Task { try await Task.sleep(for: .seconds(5)); second.cancel() }
    defer { second.cancel(); watchdog.cancel() }
    await #expect(throws: LauncherError.busy("Chunk part is already being fetched")) { try await second.value }
    #expect(state.calls == 1)
    first.cancel()
    await #expect(throws: LauncherError.cancelled) { try await first.value }
    #expect(state.cancelled)
}

private func fetchBlob() -> Data { Data((0..<200_000).map { UInt8($0 % 251) }) }

private func fetchObject(_ data: Data, paths: [String] = ["object"], codec: ChunkCodec = .identity, decodedSize: Int64? = nil) -> ChunkObject {
    var hasher = StreamingHasher(.md5)
    hasher.update(data)
    return ChunkObject(id: "object", urls: paths.map { URL(string: "https://cdn.test/" + $0)! },
        transferSize: Int64(data.count), transferDigest: hasher.finalize(), decodedSize: decodedSize ?? Int64(data.count),
        decodedDigest: hasher.finalize(), codec: codec)
}

private func testFetcher(_ http: any HTTPClient, sleeper: InstantSleeper = InstantSleeper(), attempts: Int = 6) -> ChunkFetcher {
    ChunkFetcher(http: http, retry: RetryPolicy(maxAttempts: attempts, baseDelay: .zero, maxDelay: .zero), sleeper: sleeper)
}

private struct FixedFetchClient: HTTPClient {
    let head: HTTPResponseHead
    let state: FetchTestBodyState
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        (head, HTTPBody(next: { try await state.next() }, onCancel: { state.cancel() }))
    }
}

private final class FetchTestBodyState: Sendable {
    private struct State { var pieces: [Data]; var calls = 0; var cancelled = false }
    private let state: Mutex<State>
    private let stall: Bool
    init(pieces: [Data], stall: Bool = false) { state = Mutex(State(pieces: pieces)); self.stall = stall }
    var calls: Int { state.withLock { $0.calls } }
    var cancelled: Bool { state.withLock { $0.cancelled } }
    func cancel() { state.withLock { $0.cancelled = true } }
    func next() async throws -> Data? {
        let data = state.withLock { value -> Data? in
            value.calls += 1
            return value.pieces.isEmpty ? nil : value.pieces.removeFirst()
        }
        if data == nil && stall { try await Task.sleep(for: .seconds(30)) }
        return data
    }
}

private final class RecoveringFetchClient: HTTPClient {
    let ranges = Mutex([Int64?]())
    let malformedRange: Bool
    init(malformedRange: Bool) { self.malformedRange = malformedRange }
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        let first = ranges.withLock { value in value.append(offset); return value.count == 1 }
        let head: HTTPResponseHead
        let data: Data
        if first {
            head = malformedRange ? HTTPResponseHead(status: 206, contentRange: 0...2, totalLength: 6) : HTTPResponseHead(status: 200)
            data = Data("abc".utf8)
        } else if let offset, offset == 3 {
            head = HTTPResponseHead(status: 206, contentLength: 3, contentRange: 3...5, totalLength: 6)
            data = Data("def".utf8)
        } else {
            head = HTTPResponseHead(status: 200, contentLength: 6)
            data = Data("abcdef".utf8)
        }
        let state = FetchTestBodyState(pieces: [data])
        return (head, HTTPBody(next: { try await state.next() }, onCancel: { state.cancel() }))
    }
}
private final class FetchBlockingWrite: FileOps {
    let entered = Mutex(false)
    let release = DispatchSemaphore(value: 0)
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        entered.withLock { $0 = true }
        guard release.wait(timeout: .now() + 30) == .success else { throw LauncherError.io("write gate timed out") }
        return try SystemFileOps().write(descriptor, bytes: bytes)
    }
    func synchronize(_ descriptor: Int32, durable: Bool) throws {
        try SystemFileOps().synchronize(descriptor, durable: durable)
    }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws { try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory) }
}
