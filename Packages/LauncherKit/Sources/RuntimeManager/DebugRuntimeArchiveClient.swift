// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
#if DEBUG
import Foundation
import LauncherCore
import DownloadEngine

/// An install captures one regular file. The ordinary fetch/install pipeline
/// still verifies the descriptor size and SHA-256 before archive extraction.
actor DebugRuntimeArchiveClient: HTTPClient {
    private let handle: FileHandle
    private let length: Int64

    private init(handle: FileHandle, length: Int64) { self.handle = handle; self.length = length }
    deinit { try? handle.close() }

    /// Called on ComponentInstallSession's blocking-I/O executor. A missing
    /// regular leaf keeps the normal fetcher. Selected local bytes never retry
    /// through the network, even if the file disappears or verification fails.
    static func fetcher(directory: URL, archiveURL: URL) throws -> ChunkFetcher? {
        let fs = try ContainedFileSystem(root: directory)
        let name = try SafeRelativePath(archiveURL.lastPathComponent)
        guard name.components.count == 1, try fs.itemType(at: name, allowingLeafSymlink: true) == .regularFile else { return nil }
        let handle = try fs.openForReading(at: name)
        do {
            let size = try handle.seekToEnd()
            guard let length = Int64(exactly: size) else { throw LauncherError.io("Debug archive exceeds size limit") }
            try handle.seek(toOffset: 0)
            let client = Self(handle: handle, length: length)
            return ChunkFetcher(http: client, retry: RetryPolicy(maxAttempts: 1), sleeper: ContinuousSleeper())
        } catch { try? handle.close(); throw error }
    }

    func post(_ url: URL) async throws -> (HTTPResponseHead, HTTPBody) {
        throw LauncherError.io("Debug archive requires GET")
    }

    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        // A full 200 response makes the existing fetcher discard any partial
        // download and verify this file independently of previous network bytes.
        let handle = handle
        try await BlockingIO.run { try handle.seek(toOffset: 0) }
        return (HTTPResponseHead(status: 200, contentLength: length), HTTPBody(next: { try await self.next() }))
    }

    private func next() async throws -> Data? {
        let handle = handle
        return try await BlockingIO.run {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 65_536) ?? Data()
            return data.isEmpty ? nil : data
        }
    }
}
#endif
