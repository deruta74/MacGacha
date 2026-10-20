// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).

import Darwin
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

    /// The caller supplies a contained part URL and creates its parent through ContainedFileSystem.
    /// Progress is the current number of transfer bytes on disk; a restart may reset it to zero.
    public func fetch(_ object: ChunkObject, to part: URL, progress: @Sendable (Int64) -> Void) async throws {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        try object.validate()
        guard part.isFileURL, !part.path.utf8.contains(0) else { throw LauncherError.unsafePath(part.absoluteString) }
        let key = part.standardizedFileURL.path
        guard activeParts.insert(key).inserted else { throw LauncherError.io("Chunk part is already being fetched") }
        defer { activeParts.remove(key) }
        for attempt in 1...retry.maxAttempts {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            let url = object.urls[(attempt - 1) % object.urls.count]
            do {
                try await fetchAttempt(object, from: url, to: part, progress: progress)
                return
            } catch {
                if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
                let failure = error as? StatusFailure
                let cause = failure?.error ?? (error as? LauncherError) ?? .io("Cannot access chunk part")
                if case .cancelled = cause { throw cause }
                switch cause {
                case .sizeMismatch, .digestMismatch: try removePart(part)
                default: break
                }
                guard attempt < retry.maxAttempts, retry.isRetryable(cause) else { throw cause }
                do { try await sleeper.sleep(for: retry.delay(forAttempt: attempt, retryAfter: failure?.retryAfter)) }
                catch {
                    if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
                    throw error
                }
            }
        }
    }

    private struct StatusFailure: Error {
        let error: LauncherError
        let retryAfter: Duration?
    }

    private func fetchAttempt(_ object: ChunkObject, from url: URL, to part: URL,
        progress: @Sendable (Int64) -> Void) async throws {
        let handle = try openPart(part)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, info.st_size >= 0 else { throw LauncherError.io("Cannot inspect chunk part") }
        var offset = Int64(info.st_size)
        guard offset <= object.transferSize else {
            throw LauncherError.sizeMismatch(path: object.id, expected: object.transferSize, actual: offset)
        }
        progress(offset)
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        let (head, body) = try await http.get(url, byteRangeFrom: offset > 0 ? offset : nil)
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        switch head.status {
        case 200:
            try handle.truncate(atOffset: 0)
            offset = 0
            progress(0)
            if let length = head.contentLength, length != object.transferSize {
                throw LauncherError.sizeMismatch(path: object.id, expected: object.transferSize, actual: length)
            }
        case 206:
            guard let range = head.contentRange, range.lowerBound == offset, object.transferSize > 0,
                  range.upperBound == object.transferSize - 1 else {
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
            try await verify(object, handle: handle, part: part)
            progress(object.transferSize)
            return
        default:
            throw StatusFailure(error: .http(status: head.status, url: url), retryAfter: head.retryAfter)
        }
        try handle.seek(toOffset: UInt64(offset))
        try await consume(body, object: object, handle: handle, offset: offset, progress: progress)
        try await verify(object, handle: handle, part: part)
    }

    private func consume(_ body: HTTPBody, object: ChunkObject, handle: FileHandle, offset: Int64,
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
            try handle.write(contentsOf: piece)
            received += Int64(piece.count)
            progress(received)
        }
        // Releasing the iterator cancels any remaining body instead of waiting for an unbounded EOF.
    }

    private func verify(_ object: ChunkObject, handle: FileHandle, part: URL) async throws {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { throw LauncherError.io("Cannot inspect completed part") }
        guard info.st_size == object.transferSize else {
            throw LauncherError.sizeMismatch(path: object.id, expected: object.transferSize, actual: info.st_size)
        }
        if let expected = object.transferDigest {
            let actual = try await FileHasher.digest(of: part, algorithm: expected.algorithm, bufferSize: 65_536)
            guard expected == actual else {
                throw LauncherError.digestMismatch(path: object.id, expected: expected.hex, actual: actual.hex)
            }
        }
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        try handle.synchronize()
    }

    private func openPart(_ part: URL) throws -> FileHandle {
        let fd = open(part.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            if errno == ELOOP || errno == EISDIR { throw LauncherError.unsafePath(part.path) }
            throw LauncherError.io("Cannot open chunk part")
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            close(fd)
            throw LauncherError.unsafePath(part.path)
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private func removePart(_ part: URL) throws {
        guard unlink(part.path) == 0 || errno == ENOENT else { throw LauncherError.io("Cannot discard invalid chunk part") }
    }
}
