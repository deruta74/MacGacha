// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import LauncherCore
import DownloadEngine

/// Pull-driven fixture transport. URL paths resolve only below root; queries are ignored.
/// Each body reads a fixed-size snapshot in at most 64 KiB pieces and closes on discard/cancel.
public struct FileBackedHTTPClient: HTTPClient {
    private let fs: ContainedFileSystem
    public init(root: URL) throws { fs = try ContainedFileSystem(root: root) }

    public func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard offset == nil || offset! >= 0 else { throw LauncherError.transport("negative range offset") }
        let raw = url.path
        guard raw.utf8.first == 0x2f else { throw LauncherError.unsafePath(raw) }
        let path = try SafeRelativePath(String(decoding: raw.utf8.dropFirst(), as: UTF8.self))
        guard let size = try fs.size(at: path) else {
            return (HTTPResponseHead(status: 404, contentLength: 0), HTTPBody(next: { nil }))
        }
        if let offset, offset >= size {
            return (HTTPResponseHead(status: 416, contentLength: 0, totalLength: size), HTTPBody(next: { nil }))
        }
        let handle = try fs.openForReading(at: path)
        do { try handle.seek(toOffset: UInt64(offset ?? 0)) }
        catch { try? handle.close(); throw LauncherError.io("Cannot seek fixture") }
        let reader = FixtureReader(handle: handle, remaining: size - (offset ?? 0))
        let head = HTTPResponseHead(status: offset == nil ? 200 : 206,
            contentLength: size - (offset ?? 0), contentRange: offset.map { $0...(size - 1) }, totalLength: size)
        return (head, HTTPBody(next: { try reader.next() }, onCancel: { reader.close() }))
    }
}

private final class FixtureReader: Sendable {
    private struct State { var handle: FileHandle?; var remaining: Int64 }
    private let state: Mutex<State>
    init(handle: FileHandle, remaining: Int64) { state = Mutex(State(handle: handle, remaining: remaining)) }
    func next() throws -> Data? {
        try state.withLock { state in
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            guard let handle = state.handle else { return nil }
            guard state.remaining > 0 else { try? handle.close(); state.handle = nil; return nil }
            let data = try autoreleasepool { try handle.read(upToCount: Int(min(65_536, state.remaining))) ?? Data() }
            guard !data.isEmpty else { throw LauncherError.io("Fixture changed during read") }
            state.remaining -= Int64(data.count)
            return data
        }
    }
    func close() {
        state.withLock { try? $0.handle?.close(); $0.handle = nil }
    }
    deinit { close() }
}
