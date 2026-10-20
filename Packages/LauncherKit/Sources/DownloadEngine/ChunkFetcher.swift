// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).

import Foundation
import LauncherCore

public actor ChunkFetcher {
    private let http: any HTTPClient
    private let retry: RetryPolicy
    private let sleeper: any Sleeper
    private var activeParts = Set<String>()

    public init(http: any HTTPClient, retry: RetryPolicy, sleeper: any Sleeper) {
        self.http = http
        self.retry = retry
        self.sleeper = sleeper
    }

    /// All part access traverses checked ancestors within fs; missing parents are created.
    /// Progress is the current number of transfer bytes on disk; a restart may reset it to zero.
    /// Concurrent requests for case variants of the same absolute part path throw .busy.
    public func fetch(_ object: ChunkObject, fs: ContainedFileSystem, part: SafeRelativePath,
        progress: @Sendable (Int64) -> Void) async throws {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        try object.validate()
        let key = fs.caseFoldedPathKey(for: part)
        guard activeParts.insert(key).inserted else { throw LauncherError.busy("Chunk part is already being fetched") }
        defer { activeParts.remove(key) }
        try await Self.performFetch(object, http: http, retry: retry, sleeper: sleeper, fs: fs, part: part, progress: progress)
    }

    // Only the reservation set lives on the actor. All blocking part I/O, retries and
    // synchronization run outside its executor, allowing independent parts to progress.
    @concurrent
    private static func performFetch(_ object: ChunkObject, http: any HTTPClient, retry: RetryPolicy,
        sleeper: any Sleeper, fs: ContainedFileSystem, part: SafeRelativePath,
        progress: @Sendable (Int64) -> Void) async throws {
        var attempt = 1
        var mirror = 0
        var unavailable = Set<Int>()
        while true {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            let selected = mirror
            let url = object.urls[selected]
            do {
                try await fetchAttempt(object, from: url, http: http, fs: fs, part: part, progress: progress)
                return
            } catch {
                if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
                let failure = error as? StatusFailure
                let cause = failure?.error ?? (error as? LauncherError) ?? .io("Cannot access chunk part")
                if case .cancelled = cause { throw cause }
                switch cause {
                case .sizeMismatch, .digestMismatch: try fs.removeFile(at: part)
                default: break
                }
                if case .http(let status, _) = cause, status == 404 || status == 410 {
                    unavailable.insert(selected)
                    guard unavailable.count < object.urls.count else { throw cause }
                } else {
                    guard attempt < retry.maxAttempts, retry.isRetryable(cause) else { throw cause }
                    do { try await sleeper.sleep(for: retry.delay(forAttempt: attempt, retryAfter: failure?.retryAfter)) }
                    catch {
                        if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
                        throw error
                    }
                    attempt += 1
                }
                repeat { mirror = (mirror + 1) % object.urls.count } while unavailable.contains(mirror)
            }
        }
    }

    private struct StatusFailure: Error {
        let error: LauncherError
        let retryAfter: Duration?
    }

    @concurrent
    private static func fetchAttempt(_ object: ChunkObject, from url: URL, http: any HTTPClient, fs: ContainedFileSystem, part: SafeRelativePath,
        progress: @Sendable (Int64) -> Void) async throws {
        var handle = try fs.openForWriting(at: part, truncate: false)
        defer { try? handle.close() }
        var offset = try fs.size(at: part) ?? 0
        guard offset <= object.transferSize else {
            throw LauncherError.sizeMismatch(path: object.id, expected: object.transferSize, actual: offset)
        }
        progress(offset)
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        let (head, body) = try await http.get(url, byteRangeFrom: offset > 0 ? offset : nil)
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        switch head.status {
        case 200:
            try handle.close()
            handle = try fs.openForWriting(at: part, truncate: true)
            offset = 0
            progress(0)
            if let length = head.contentLength, length != object.transferSize {
                throw LauncherError.sizeMismatch(path: object.id, expected: object.transferSize, actual: length)
            }
        case 206:
            guard let range = head.contentRange, range.lowerBound == offset, object.transferSize > 0,
                  range.upperBound == object.transferSize - 1 else {
                try handle.close()
                handle = try fs.openForWriting(at: part, truncate: true)
                throw LauncherError.transport("invalid content range")
            }
            if let total = head.totalLength, total != object.transferSize {
                throw LauncherError.sizeMismatch(path: object.id, expected: object.transferSize, actual: total)
            }
            if let length = head.contentLength, length != object.transferSize - offset {
                throw LauncherError.sizeMismatch(path: object.id, expected: object.transferSize - offset, actual: length)
            }
        case 416:
            if let total = head.totalLength, total != object.transferSize {
                throw LauncherError.sizeMismatch(path: object.id, expected: object.transferSize, actual: total)
            }
            try await verify(object, fs: fs, part: part)
            progress(object.transferSize)
            return
        default:
            throw StatusFailure(error: .http(status: head.status, url: url), retryAfter: head.retryAfter)
        }
        try handle.seek(toOffset: UInt64(offset))
        try await consume(body, object: object, handle: handle, fileOps: fs.fileOps, offset: offset, progress: progress)
        try await verify(object, fs: fs, part: part)
    }

    @concurrent
    private static func consume(_ body: HTTPBody, object: ChunkObject, handle: FileHandle, fileOps: any FileOps, offset: Int64,
        progress: @Sendable (Int64) -> Void) async throws {
        var received = offset
        var iterator = body.makeAsyncIterator()
        while received < object.transferSize {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            guard let piece = try await iterator.next() else { break }
            guard Int64(piece.count) <= object.transferSize - received else {
                let (actual, overflow) = received.addingReportingOverflow(Int64(piece.count))
                throw LauncherError.sizeMismatch(path: object.id, expected: object.transferSize, actual: overflow ? Int64.max : actual)
            }
            try fileOps.writeAll(piece, to: handle.fileDescriptor)
            received += Int64(piece.count)
            progress(received)
        }
        guard received == object.transferSize else { throw LauncherError.transport("truncated body") }
        // Releasing the iterator cancels any remaining body instead of waiting for an unbounded EOF.
    }

    @concurrent
    private static func verify(_ object: ChunkObject, fs: ContainedFileSystem, part: SafeRelativePath) async throws {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        let size = try fs.size(at: part) ?? 0
        guard size == object.transferSize else {
            throw LauncherError.sizeMismatch(path: object.id, expected: object.transferSize, actual: size)
        }
        if let expected = object.transferDigest {
            let actual = try await Self.digest(fs: fs, part: part, size: size, algorithm: expected.algorithm)
            guard expected == actual else {
                throw LauncherError.digestMismatch(path: object.id, expected: expected.hex, actual: actual.hex)
            }
        }
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        try fs.fullSync(at: part)
    }

    @concurrent
    private static func digest(fs: ContainedFileSystem, part: SafeRelativePath, size: Int64,
        algorithm: DigestAlgorithm) async throws -> Digest {
        let handle = try fs.openForReading(at: part)
        defer { try? handle.close() }
        var hasher = StreamingHasher(algorithm)
        var remaining = size
        while remaining > 0 {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            let piece = try autoreleasepool { try handle.read(upToCount: Int(min(65_536, remaining))) }
            guard let piece, !piece.isEmpty else { throw LauncherError.io("Chunk part changed while hashing") }
            hasher.update(piece)
            remaining -= Int64(piece.count)
        }
        return hasher.finalize()
    }
}
