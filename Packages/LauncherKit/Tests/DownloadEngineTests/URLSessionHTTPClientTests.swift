import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine

@Test
func urlSessionStreamsAndParsesResponseHeaders() async throws {
    let fixture = HTTPFixture(.response(206, [
        "Content-Length": "6", "Content-Range": "bytes 10-15/100", "Retry-After": "7",
    ], [Data("abc".utf8), Data("def".utf8)]))
    defer { fixture.close() }
    let (head, stream) = try await fixture.client.get(fixture.url, byteRangeFrom: 10)
    #expect(head.status == 206)
    #expect(head.contentLength == 6)
    #expect(head.contentRange == 10...15)
    #expect(head.totalLength == 100)
    #expect(head.retryAfter == .seconds(7))
    var body = Data()
    for try await chunk in stream { body.append(chunk) }
    #expect(body == Data("abcdef".utf8))
    #expect(fixture.control.request?.value(forHTTPHeaderField: "Range") == "bytes=10-")
}

@Test
func urlSessionReturnsHTTPStatusesAndRejectsMalformedRanges() async throws {
    let fixture = HTTPFixture(.response(404, ["Content-Range": "bytes 9-2/10"], []))
    defer { fixture.close() }
    let (head, stream) = try await fixture.client.get(fixture.url, byteRangeFrom: nil)
    #expect(head.status == 404)
    #expect(head.contentRange == nil)
    #expect(head.contentLength == nil)
    #expect(fixture.control.request?.value(forHTTPHeaderField: "Range") == nil)
    for try await _ in stream { Issue.record("An empty response must have no body") }
}

@Test
func urlSessionMapsTransportFailures() async throws {
    for mode in [HTTPStubMode.failBeforeResponse, .failAfterResponse] {
        let fixture = HTTPFixture(mode)
        defer { fixture.close() }
        do {
            let (_, stream) = try await fixture.client.get(fixture.url, byteRangeFrom: nil)
            for try await _ in stream {}
            Issue.record("An injected transport error must throw")
        } catch LauncherError.transport {}
    }
}

@Test
func urlSessionCancellationBeforeHeadersCancelsTask() async throws {
    let fixture = HTTPFixture(.stallBeforeResponse)
    defer { fixture.close() }
    let fallback = stallWatchdog(fixture.control)
    defer { fallback.cancel() }
    let task = Task { try await fixture.client.get(fixture.url, byteRangeFrom: nil) }
    defer { task.cancel() }
    try await waitForHTTPCondition { fixture.control.started }
    let clock = ContinuousClock()
    let cancelledAt = clock.now
    task.cancel()
    await #expect(throws: LauncherError.cancelled) { try await task.value }
    try await waitForHTTPCondition { fixture.control.stopped }
    #expect(cancelledAt.duration(to: clock.now) < .seconds(1))
}

@Test
func urlSessionConsumerCancellationStopsStalledStream() async throws {
    let fixture = HTTPFixture(.stallAfterResponse)
    defer { fixture.close() }
    let fallback = stallWatchdog(fixture.control)
    defer { fallback.cancel() }
    let (_, stream) = try await fixture.client.get(fixture.url, byteRangeFrom: nil)
    let received = Mutex(false)
    let task = Task {
        do {
            for try await _ in stream { received.withLock { $0 = true } }
        } catch LauncherError.cancelled {}
    }
    defer { task.cancel() }
    try await waitForHTTPCondition { received.withLock { $0 } }
    let clock = ContinuousClock()
    let cancelledAt = clock.now
    task.cancel()
    try await task.value
    try await waitForHTTPCondition { fixture.control.stopped }
    #expect(cancelledAt.duration(to: clock.now) < .seconds(1))
}

@Test
func urlSessionDiscardedStreamCancelsTask() async throws {
    let fixture = HTTPFixture(.stallAfterResponse)
    defer { fixture.close() }
    let fallback = stallWatchdog(fixture.control)
    defer { fallback.cancel() }
    do {
        let (head, _) = try await fixture.client.get(fixture.url, byteRangeFrom: nil)
        #expect(head.status == 200)
    }
    try await waitForHTTPCondition { fixture.control.stopped }
}

@Test
func urlSessionImmediateCompletionAndCancellationRaces() async throws {
    for iteration in 0..<20 {
        let fixture = HTTPFixture(.response(200, ["Content-Length": "0"], []))
        defer { fixture.close() }
        let task = Task {
            let (_, stream) = try await fixture.client.get(fixture.url, byteRangeFrom: nil)
            for try await _ in stream {}
        }
        if iteration.isMultiple(of: 2) { task.cancel() }
        do { try await task.value } catch LauncherError.cancelled {}
    }
}

@Test
func urlSessionRejectsNonHTTPResponse() async throws {
    let fixture = HTTPFixture(.nonHTTP)
    defer { fixture.close() }
    do {
        _ = try await fixture.client.get(fixture.url, byteRangeFrom: nil)
        Issue.record("A non-HTTP response must fail")
    } catch LauncherError.transport {}
}

@Test
func urlSessionCancellationRacesWithResponseDelivery() async throws {
    for _ in 0..<20 {
        let fixture = HTTPFixture(.stallAfterResponse)
        defer { fixture.close() }
        let fallback = stallWatchdog(fixture.control)
        defer { fallback.cancel() }
        let task = Task {
            let (_, stream) = try await fixture.client.get(fixture.url, byteRangeFrom: nil)
            for try await _ in stream {}
        }
        defer { task.cancel() }
        try await waitForHTTPCondition { fixture.control.started }
        task.cancel()
        do { try await task.value } catch LauncherError.cancelled {}
        try await waitForHTTPCondition { fixture.control.stopped }
    }
}

@Test
func urlSessionParsesUnknownTotalsAndRetryAfterDates() async throws {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    let future = formatter.string(from: Date().addingTimeInterval(60))
    let fixture = HTTPFixture(.response(206, [
        "Content-Range": "bytes 0-2/*", "Retry-After": future,
    ], [Data([1, 2, 3])]))
    defer { fixture.close() }
    let (head, body) = try await fixture.client.get(fixture.url, byteRangeFrom: nil)
    #expect(head.contentRange == 0...2)
    #expect(head.totalLength == nil)
    let retryAfter = try #require(head.retryAfter)
    #expect(retryAfter > .seconds(55))
    #expect(retryAfter <= .seconds(60))
    for try await _ in body {}

    let unsatisfied = HTTPFixture(.response(416, ["Content-Range": "bytes */100"], []))
    defer { unsatisfied.close() }
    let (rangeHead, rangeBody) = try await unsatisfied.client.get(unsatisfied.url, byteRangeFrom: 100)
    #expect(rangeHead.contentRange == nil)
    #expect(rangeHead.totalLength == 100)
    for try await _ in rangeBody {}
}

private enum HTTPStubMode: Sendable {
    case response(Int, [String: String], [Data])
    case failBeforeResponse, failAfterResponse, stallBeforeResponse, stallAfterResponse, nonHTTP
}

private struct HTTPFixture: Sendable {
    let url: URL
    let session: URLSession
    let client: URLSessionHTTPClient
    let control: HTTPStubControl

    init(_ mode: HTTPStubMode) {
        let url = URL(string: "https://http.test/\(UUID().uuidString)")!
        let control = HTTPStubControl()
        self.url = url
        self.control = control
        HTTPStubProtocol.routes.withLock { $0[url] = (mode, control) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStubProtocol.self]
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        session = URLSession(configuration: configuration)
        client = URLSessionHTTPClient(session: session)
    }

    func close() {
        session.invalidateAndCancel()
        HTTPStubProtocol.routes.withLock { $0[url] = nil }
    }
}

private final class HTTPStubControl: Sendable {
    struct State {
        var started = false
        var stopped = false
        var request: URLRequest?
        var loader: HTTPStubProtocol?
    }
    let state = Mutex(State())
    var started: Bool { state.withLock { $0.started } }
    var stopped: Bool { state.withLock { $0.stopped } }
    var request: URLRequest? { state.withLock { $0.request } }

    func expire() {
        let loader = state.withLock { $0.stopped ? nil : $0.loader }
        if let loader { loader.client?.urlProtocol(loader, didFailWithError: URLError(.timedOut)) }
    }
}

private final class HTTPStubProtocol: URLProtocol, @unchecked Sendable {
    static let routes = Mutex([URL: (HTTPStubMode, HTTPStubControl)]())

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "http.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let (mode, control) = Self.routes.withLock({ $0[url] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        control.state.withLock { $0.started = true; $0.request = request; $0.loader = self }
        switch mode {
        case .response(let status, let headers, let chunks):
            respond(status, headers: headers)
            for data in chunks { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        case .failBeforeResponse:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case .failAfterResponse:
            respond(200)
            client?.urlProtocol(self, didLoad: Data("partial".utf8))
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case .stallBeforeResponse: break
        case .stallAfterResponse:
            respond(200, headers: ["Content-Type": "application/octet-stream", "Content-Length": "1000000"])
            client?.urlProtocol(self, didLoad: Data("first".utf8))
        case .nonHTTP:
            client?.urlProtocol(self, didReceive: URLResponse(url: url, mimeType: nil,
                expectedContentLength: 0, textEncodingName: nil), cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        guard let url = request.url, let (_, control) = Self.routes.withLock({ $0[url] }) else { return }
        control.state.withLock { $0.stopped = true; $0.loader = nil }
    }

    private func respond(_ status: Int, headers: [String: String] = [:]) {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
}

private func waitForHTTPCondition(_ condition: @Sendable () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while !condition() {
        guard clock.now < deadline else { throw LauncherError.io("Timed out waiting for HTTP test condition") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private func stallWatchdog(_ control: HTTPStubControl) -> Task<Void, any Error> {
    Task {
        try await Task.sleep(for: .seconds(2))
        control.expire()
    }
}
