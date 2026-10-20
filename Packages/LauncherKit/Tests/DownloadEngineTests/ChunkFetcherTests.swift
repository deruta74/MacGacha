// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).

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

@Test
func noRetryOn404() async throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let cdn = MockCDN()
    let object = fetchObject(fetchBlob(), paths: ["missing", "mirror"])
    cdn.serve("mirror", data: fetchBlob())
    let sleeper = InstantSleeper()
    await #expect(throws: LauncherError.http(status: 404, url: object.urls[0])) {
        try await testFetcher(cdn, sleeper: sleeper).fetch(object, fs: fs, part: try SafeRelativePath("object.part"), progress: { _ in })
    }
    #expect(cdn.requestLog.count == 1)
    #expect(sleeper.delays.isEmpty)
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
    #expect(try Data(contentsOf: part) == Data("abc".utf8))
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
func zstdCodecReportsUnsupported() throws {
    #expect(throws: LauncherError.io("codec unsupported: zstd")) { try ChunkCodec.zstd.decoder() }
}

@Test
func identityDecoderCopiesAtOffsetAndChecksSize() throws {
    let directory = try TempDir()
    let transferred = directory.url.appendingPathComponent("object")
    try Data("hello".utf8).write(to: transferred)
    let target = directory.url.appendingPathComponent("output")
    try Data("XX".utf8).write(to: target)
    let output = try FileHandle(forWritingTo: target)
    defer { try? output.close() }
    try ChunkCodec.identity.decoder().decode(transferred, expectedSize: 5, into: output, at: 2)
    #expect(try Data(contentsOf: target) == Data("XXhello".utf8))
    #expect(throws: LauncherError.sizeMismatch(path: transferred.path, expected: 4, actual: 5)) {
        try IdentityDecoder().decode(transferred, expectedSize: 4, into: output, at: 0)
    }
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
