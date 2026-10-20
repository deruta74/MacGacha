import Foundation
import Synchronization
import LauncherCore
import DownloadEngine

public final class MockCDN: HTTPClient, @unchecked Sendable {
    public enum Fault: Sendable {
        case status(Int, retryAfter: Duration? = nil)
        case dropAfter(bytes: Int)
        case corruptByte(at: Int)
        case ignoreRange
        case transportError
    }

    private struct State {
        var files: [String: Data] = [:]
        var faults: [String: [Fault]] = [:]
        var requests: [(path: String, rangeFrom: Int64?)] = []
    }

    private let state = Mutex(State())

    public init() {}

    public func serve(_ path: String, data: Data) {
        state.withLock { $0.files[Self.normalized(path)] = data }
    }

    public func enqueueFault(_ path: String, _ fault: Fault) {
        state.withLock { $0.faults[Self.normalized(path), default: []].append(fault) }
    }

    public var requestLog: [(path: String, rangeFrom: Int64?)] {
        state.withLock { $0.requests }
    }

    public func get(_ url: URL, byteRangeFrom offset: Int64?) async throws
        -> (HTTPResponseHead, HTTPBody) {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        let path = Self.normalized(url.path)
        let (data, fault) = state.withLock { state in
            state.requests.append((path, offset))
            let fault = state.faults[path]?.isEmpty == false ? state.faults[path]?.removeFirst() : nil
            return (state.files[path], fault)
        }
        if case .transportError = fault { throw LauncherError.transport("Injected transport error") }
        if case .status(let status, let retryAfter) = fault {
            return Self.response(status: status, data: Data(), retryAfter: retryAfter)
        }
        guard let data else { return Self.response(status: 404, data: Data()) }
        let ignoresRange: Bool
        if case .ignoreRange = fault { ignoresRange = true } else { ignoresRange = false }
        let start = ignoresRange ? nil : offset
        if let start, start < 0 || start >= Int64(data.count) {
            return Self.response(status: 416, data: Data(), totalLength: Int64(data.count))
        }
        var body = data.subdata(in: (data.startIndex + Int(start ?? 0))..<data.endIndex)
        if case .corruptByte(let index) = fault, index >= 0, index < body.count {
            body[body.startIndex + index] ^= 0xff
        }
        let range = start.map { $0...(Int64(data.count) - 1) }
        let dropAfter: Int?
        if case .dropAfter(let bytes) = fault { dropAfter = max(0, bytes) } else { dropAfter = nil }
        let source = MockBody(data: body, dropAfter: dropAfter)
        let stream = HTTPBody(next: { try await source.next() })
        return (HTTPResponseHead(status: start == nil ? 200 : 206, contentLength: Int64(body.count),
            contentRange: range, totalLength: Int64(data.count)), stream)
    }

    private static func normalized(_ path: String) -> String {
        String(path.drop(while: { $0 == "/" }))
    }

    private static func response(status: Int, data: Data, totalLength: Int64? = nil, retryAfter: Duration? = nil)
        -> (HTTPResponseHead, HTTPBody) {
        let source = MockBody(data: data, dropAfter: nil)
        return (HTTPResponseHead(status: status, contentLength: Int64(data.count), totalLength: totalLength,
            retryAfter: retryAfter), HTTPBody(next: { try await source.next() }))
    }
}

private actor MockBody {
    let data: Data
    let dropAfter: Int?
    var offset = 0

    init(data: Data, dropAfter: Int?) {
        self.data = data
        self.dropAfter = dropAfter
    }

    func next() throws -> Data? {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        if let dropAfter, offset >= dropAfter { throw LauncherError.transport("Injected dropped transfer") }
        guard offset < data.count else { return nil }
        let end = min(data.count, offset + 65_536)
        defer { offset = end }
        return data.subdata(in: offset..<end)
    }
}

public final class InstantSleeper: Sleeper, Sendable {
    private let recorded = Mutex([Duration]())

    public init() {}

    public var delays: [Duration] { recorded.withLock { $0 } }

    public func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        recorded.withLock { $0.append(duration) }
    }
}
