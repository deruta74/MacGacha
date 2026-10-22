// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import DownloadEngine
import TestSupport

@Test(.timeLimit(.minutes(1)))
func fileBackedClientStreamsBoundedRangesAndHandlesCancellation() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let bytes = Data((0..<200_000).map { UInt8($0 % 251) })
    try fs.writeAtomically(bytes, to: SafeRelativePath("object"))
    let client = try FileBackedHTTPClient(root: temp.url)
    let url = try #require(URL(string: "https://fixtures.test/object"))
    for offset: Int64? in [nil, 17, 200_000, 200_001] {
        let (head, body) = try await client.get(url, byteRangeFrom: offset)
        #expect(head.status == (offset == nil ? 200 : offset! < 200_000 ? 206 : 416))
        var received = Data()
        for try await piece in body { #expect(piece.count <= 65_536); received.append(piece) }
        #expect(received == bytes.dropFirst(Int(min(offset ?? 0, 200_000))))
        if head.status == 206 {
            #expect(head.contentRange == 17...199_999)
            #expect(head.totalLength == 200_000)
            #expect(head.contentLength == 199_983)
        }
    }
    await #expect(throws: LauncherError.transport("negative range offset")) {
        _ = try await client.get(url, byteRangeFrom: -1)
    }
    let (_, body) = try await client.get(url, byteRangeFrom: nil)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        var iterator = body.makeAsyncIterator()
        await #expect(throws: LauncherError.cancelled) { _ = try await iterator.next() }
    }
    await task.value
    let (missing, empty) = try await client.get(URL(string: "https://fixtures.test/missing")!, byteRangeFrom: nil)
    #expect(missing.status == 404)
    var missingIterator = empty.makeAsyncIterator(); #expect(try await missingIterator.next() == nil)
}

@Test(.timeLimit(.minutes(1)))
func fileBackedClientRejectsSymlinkAncestorsAndEscapedSeparators() async throws {
    let temp = try TempDir(); let outside = try TempDir()
    let fs = try ContainedFileSystem(root: outside.url)
    try fs.writeAtomically(Data("private".utf8), to: SafeRelativePath("secret"))
    try FileManager.default.createSymbolicLink(at: temp.url.appendingPathComponent("link"), withDestinationURL: outside.url)
    let client = try FileBackedHTTPClient(root: temp.url)
    await #expect(throws: LauncherError.unsafePath(temp.url.appendingPathComponent("link").path)) {
        _ = try await client.get(URL(string: "https://fixtures.test/link/secret")!, byteRangeFrom: nil)
    }
    await #expect(throws: LauncherError.unsafePath("bad\\name")) {
        _ = try await client.get(URL(string: "https://fixtures.test/bad%5Cname")!, byteRangeFrom: nil)
    }
}
