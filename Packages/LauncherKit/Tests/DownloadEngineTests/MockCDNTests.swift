import Foundation
import Testing
import LauncherCore
import DownloadEngine
import TestSupport

@Test
func mockServesRangeAndFaults() async throws {
    let cdn = MockCDN()
    let blob = Data((0..<200_000).map { UInt8($0 % 251) })
    let url = URL(string: "https://mock.cdn/blob")!
    cdn.serve("blob", data: blob)
    let (head, body) = try await cdn.get(url, byteRangeFrom: 1000)
    #expect(head.status == 206)
    #expect(head.contentLength == 199_000)
    #expect(head.contentRange == 1000...199_999)
    #expect(head.totalLength == 200_000)
    #expect(try await collectMockBody(body) == blob.dropFirst(1000))

    cdn.enqueueFault("blob", .ignoreRange)
    let (ignoredHead, ignoredBody) = try await cdn.get(url, byteRangeFrom: 1000)
    #expect(ignoredHead.status == 200)
    #expect(ignoredHead.contentRange == nil)
    #expect(try await collectMockBody(ignoredBody) == blob)

    cdn.enqueueFault("blob", .dropAfter(bytes: 70_000))
    let (_, droppedBody) = try await cdn.get(url, byteRangeFrom: nil)
    var received = 0
    do {
        for try await chunk in droppedBody { received += chunk.count }
        Issue.record("An injected dropped transfer must throw")
    } catch LauncherError.transport {
        #expect(received >= 70_000)
    }
    cdn.enqueueFault("blob", .status(503, retryAfter: .seconds(7)))
    let (status, statusBody) = try await cdn.get(url, byteRangeFrom: nil)
    #expect(status.status == 503)
    #expect(status.retryAfter == .seconds(7))
    #expect(try await collectMockBody(statusBody).isEmpty)
    #expect(cdn.requestLog.map(\.path) == ["blob", "blob", "blob", "blob"])
    #expect(cdn.requestLog.map(\.rangeFrom) == [1000, 1000, nil, nil])
}

@Test
func mockFaultsAreFIFOAndBodiesAreChunked() async throws {
    let cdn = MockCDN()
    let url = URL(string: "https://mock.cdn/blob")!
    let blob = Data(repeating: 42, count: 150_000)
    cdn.serve("blob", data: blob)
    cdn.enqueueFault("blob", .transportError)
    cdn.enqueueFault("blob", .corruptByte(at: 70_000))
    do {
        _ = try await cdn.get(url, byteRangeFrom: nil)
        Issue.record("Transport fault must throw")
    } catch LauncherError.transport {}
    let (_, corrupted) = try await cdn.get(url, byteRangeFrom: nil)
    let corruptBytes = try await collectMockBody(corrupted)
    #expect(corruptBytes.count == blob.count)
    #expect(corruptBytes[70_000] != blob[70_000])
    let (_, normal) = try await cdn.get(url, byteRangeFrom: nil)
    var sizes: [Int] = []
    var normalBody = Data()
    for try await chunk in normal {
        sizes.append(chunk.count)
        normalBody.append(chunk)
    }
    #expect(sizes == [65_536, 65_536, 18_928])
    #expect(normalBody == blob)
}

@Test
func mockMissingAndUnsatisfiableRanges() async throws {
    let cdn = MockCDN()
    let url = URL(string: "https://mock.cdn/blob")!
    #expect(try await cdn.get(url, byteRangeFrom: nil).0.status == 404)
    cdn.serve("blob", data: Data([1, 2, 3]))
    let (head, body) = try await cdn.get(url, byteRangeFrom: 3)
    #expect(head.status == 416)
    #expect(head.totalLength == 3)
    #expect(try await collectMockBody(body).isEmpty)
}

@Test
func temporaryDirectoryCleansUp() throws {
    let url: URL
    do {
        let temporary = try TempDir()
        url = temporary.url
        #expect(FileManager.default.fileExists(atPath: url.path))
        try Data([1]).write(to: url.appendingPathComponent("file"))
    }
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

private func collectMockBody(_ stream: AsyncThrowingStream<Data, any Error>) async throws -> Data {
    var result = Data()
    for try await chunk in stream { result.append(chunk) }
    return result
}
