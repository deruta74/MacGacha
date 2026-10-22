// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
@testable import DownloadEngine

@Suite(.serialized, .timeLimit(.minutes(1)))
struct URLSessionHTTPClientTests {
    @Test(.timeLimit(.minutes(1))) func shardedSessionsDoNotSerializeDataCallbacks() async throws {
        let first = HTTPFixture(.response(200, ["Content-Length": "1"], [Data([1])]))
        let second = HTTPFixture(.response(200, ["Content-Length": "2"], [Data([2, 2])]))
        defer { first.close(); second.close() }
        let blocked = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let release = DispatchSemaphore(value: 0), timedOut = Mutex(false)
        let client = URLSessionHTTPClient(configuration: first.session.configuration, sessionCount: 2)
            .observingDataCallbacks { bytes, _ in
                if bytes == 1 { blocked.continuation.yield(()); if release.wait(timeout: .now() + 10) == .timedOut { timedOut.withLock { $0 = true } } }
            }
        defer { release.signal(); client.invalidate() }
        let firstTask = Task { let (_, body) = try await client.get(first.url, byteRangeFrom: nil); for try await _ in body {} }
        defer { firstTask.cancel() }
        var iterator = blocked.stream.makeAsyncIterator(); _ = await iterator.next()
        let (_, body) = try await client.get(second.url, byteRangeFrom: nil)
        var data = Data(); for try await bytes in body { data.append(bytes) }
        #expect(data == Data([2, 2]) && !timedOut.withLock { $0 })
        release.signal(); try await firstTask.value
    }

    @Test(.timeLimit(.minutes(1))) func shardedInvalidationCancelsEverySessionAndAllCopies() async throws {
        let fixtures = (0..<4).map { _ in HTTPFixture(.stallAfterResponse) }
        defer { for fixture in fixtures { fixture.close() } }
        let client = URLSessionHTTPClient(configuration: fixtures[0].session.configuration, sessionCount: 4)
        let copy = client
        let tasks = fixtures.map { fixture in Task { let (_, body) = try await client.get(fixture.url, byteRangeFrom: nil); for try await _ in body {} } }
        defer { client.invalidate(); for task in tasks { task.cancel() } }
        for fixture in fixtures { try await waitForHTTPCondition { fixture.control.started } }
        copy.invalidate(); client.invalidate()
        for task in tasks { await #expect(throws: LauncherError.cancelled) { try await task.value } }
        await #expect(throws: LauncherError.cancelled) { _ = try await copy.get(fixtures[0].url, byteRangeFrom: nil) }
        for fixture in fixtures { try await waitForHTTPCondition { fixture.control.stopped } }
    }

    @Test(.timeLimit(.minutes(1)))
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
        #expect(fixture.control.request?.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
        #expect(fixture.control.request?.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test(.timeLimit(.minutes(1)))
    func negativeResumeOffsetIsRejected() async throws {
        let fixture = HTTPFixture(.response(206, [:], []))
        defer { fixture.close() }
        do {
            _ = try await fixture.client.get(fixture.url, byteRangeFrom: -1)
            Issue.record("A negative resume offset must be rejected")
        } catch LauncherError.io("Invalid resume offset -1") {}
        #expect(fixture.control.request == nil)
    }

    @Test(.timeLimit(.minutes(1)))
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

    @Test(.timeLimit(.minutes(1)))
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

    @Test(.timeLimit(.minutes(1)))
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
        #expect(cancelledAt.duration(to: clock.now) < .seconds(3))
    }

    @Test(.timeLimit(.minutes(1)))
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
        #expect(cancelledAt.duration(to: clock.now) < .seconds(3))
    }

    @Test(.timeLimit(.minutes(1)))
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
        #expect(fixture.control.stopReason != .timeout)
    }

    @Test(.timeLimit(.minutes(1)))
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

    @Test(.timeLimit(.minutes(1)))
    func urlSessionRejectsNonHTTPResponse() async throws {
        let fixture = HTTPFixture(.nonHTTP)
        defer { fixture.close() }
        do {
            _ = try await fixture.client.get(fixture.url, byteRangeFrom: nil)
            Issue.record("A non-HTTP response must fail")
        } catch LauncherError.transport {}
    }

    @Test(.timeLimit(.minutes(1)))
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
            #expect(fixture.control.stopReason != .timeout)
        }
    }

    @Test(.timeLimit(.minutes(1)))
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

    @Test(.timeLimit(.minutes(1)))
    func urlSessionSlowConsumerHasLosslessBoundedBuffering() async throws {
        // Do not divide the high-water mark evenly: the producer must deliver
        // strictly more than it before native task suspension can pause delivery.
        let pieceSize = 48 * 1024
        let highWaterMark = 256 * 1024
        let lowWaterMark = 64 * 1024
        let pieces = (0..<96).map { Data(repeating: UInt8($0), count: pieceSize) }
        var expected = Data()
        for piece in pieces { expected.append(piece) }
        let metrics = HTTPBufferMetrics()
        let fixture = HTTPFixture(.pacedResponse(pieces), highWaterMark: highWaterMark, lowWaterMark: lowWaterMark,
            bufferObserver: { metrics.record(bytes: $0, suspended: $1) })
        defer { fixture.close() }
        let (head, body) = try await fixture.client.get(fixture.url, byteRangeFrom: nil)
        #expect(head.status == 200)
        // Hold the consumer until enough data has been delivered and URLSession
        // has processed it. Starting reads earlier can bypass backpressure entirely.
        try await waitForHTTPCondition(timeout: .seconds(10)) {
            fixture.control.deliveredBytes > highWaterMark
        }
        try await waitForHTTPCondition(timeout: .seconds(10)) {
            metrics.snapshot.suspensions > 0
        }
        var received = Data()
        var largestPiece = 0
        for try await piece in body {
            received.append(piece)
            largestPiece = max(largestPiece, piece.count)
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(received == expected)
        #expect(metrics.snapshot.peak <= highWaterMark + largestPiece)
        #expect(metrics.snapshot.suspensions > 0)
        #expect(metrics.snapshot.resumptions > 0)
        #expect(metrics.snapshot.bytes == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func urlSessionCancellationWhileBackpressuredStopsTask() async throws {
        let pieces = (0..<64).map { Data(repeating: UInt8($0), count: 65_536) }
        let metrics = HTTPBufferMetrics()
        let fixture = HTTPFixture(.pacedResponse(pieces), highWaterMark: 262_144, lowWaterMark: 65_536,
            bufferObserver: { metrics.record(bytes: $0, suspended: $1) })
        defer { fixture.close() }
        let (_, body) = try await fixture.client.get(fixture.url, byteRangeFrom: nil)
        let task = Task {
            for try await _ in body { try await Task.sleep(for: .seconds(30)) }
        }
        defer { task.cancel() }
        try await waitForHTTPCondition { metrics.snapshot.suspended }
        task.cancel()
        do {
            try await task.value
            Issue.record("The cancelled consumer must throw")
        } catch is CancellationError {
        } catch LauncherError.cancelled {}
        try await waitForHTTPCondition { metrics.snapshot.bytes == 0 }
        try await waitForHTTPCondition { fixture.control.stopped }
    }

    @Test(.timeLimit(.minutes(1)))
    func urlSessionBackpressureHandlesAnOversizedCallback() async throws {
        let data = Data((0..<(1 << 20)).map { UInt8($0 % 251) })
        let metrics = HTTPBufferMetrics()
        let fixture = HTTPFixture(.response(200, [
            "Content-Type": "application/octet-stream", "Content-Length": "\(data.count)",
        ], [data]), highWaterMark: 65_536, lowWaterMark: 16_384,
            bufferObserver: { metrics.record(bytes: $0, suspended: $1) })
        defer { fixture.close() }
        let (_, body) = try await fixture.client.get(fixture.url, byteRangeFrom: nil)
        var received = Data()
        var largestPiece = 0
        for try await piece in body {
            largestPiece = max(largestPiece, piece.count)
            received.append(piece)
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(received == data)
        #expect(metrics.snapshot.peak <= 65_536 + largestPiece)
        if metrics.snapshot.peak >= 65_536 { #expect(metrics.snapshot.suspensions > 0) }
    }

    @Test(.timeLimit(.minutes(1)))
    func backpressuredBodyDoesNotBlockOtherRequests() async throws {
        let data = Data((0..<(4 << 20)).map { UInt8($0 % 251) })
        let metrics = HTTPBufferMetrics()
        let fixture = HTTPFixture(.response(200, [
            "Content-Type": "application/octet-stream", "Content-Length": "\(data.count)",
        ], [data]), highWaterMark: 262_144, lowWaterMark: 65_536,
            bufferObserver: { metrics.record(bytes: $0, suspended: $1) })
        defer { fixture.close() }
        let secondURL = URL(string: "https://http.test/\(UUID().uuidString)")!
        let secondControl = HTTPStubControl()
        let smallBody = Data("second response".utf8)
        HTTPStubProtocol.routes.withLock {
            $0[secondURL] = (.response(200, ["Content-Length": "\(smallBody.count)"], [smallBody]), secondControl)
        }
        defer { HTTPStubProtocol.routes.withLock { $0[secondURL] = nil } }

        let (_, firstBody) = try await fixture.client.get(fixture.url, byteRangeFrom: nil)
        try await waitForHTTPCondition { metrics.snapshot.suspensions > 0 }
        #expect(metrics.snapshot.bytes >= 262_144)
        let clock = ContinuousClock()
        let startedAt = clock.now
        let second = Task {
            let (head, body) = try await fixture.client.get(secondURL, byteRangeFrom: nil)
            var received = Data()
            for try await piece in body { received.append(piece) }
            return (head.status, received)
        }
        defer { second.cancel() }
        // Cancellation completes the pending get even if the old delegate is blocked.
        let watchdog = Task {
            try await Task.sleep(for: .milliseconds(5_500))
            second.cancel()
        }
        defer { watchdog.cancel() }
        do {
            let (status, received) = try await second.value
            #expect(startedAt.duration(to: clock.now) < .seconds(5))
            #expect(status == 200)
            #expect(received == smallBody)
        } catch {
            Issue.record("Request B must finish before request A is consumed: \(error)")
        }
        watchdog.cancel()
        var received = Data()
        for try await piece in firstBody { received.append(piece) }
        #expect(received == data)
    }

    @Test(.timeLimit(.minutes(1)))
    func urlSessionExternalCancellationIsRetryableTransport() async throws {
        for mode in [HTTPStubMode.externallyCancelled, .externallyCancelledAfterResponse] {
            let fixture = HTTPFixture(mode)
            defer { fixture.close() }
            do {
                let (_, body) = try await fixture.client.get(fixture.url, byteRangeFrom: nil)
                for try await _ in body {}
                Issue.record("External cancellation must throw")
            } catch let error as LauncherError {
                guard case .transport = error else {
                    Issue.record("External cancellation must be transport, got \(error)")
                    continue
                }
                #expect(RetryPolicy().isRetryable(error))
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func bufferObserverCanCancelBodyReentrantly() async throws {
        let iterator = Mutex<HTTPBody.Iterator?>(nil)
        let fixture = HTTPFixture(.stallAfterResponse, highWaterMark: 1024, lowWaterMark: 256,
            bufferObserver: { bytes, _ in
                guard bytes >= 1024 else { return }
                // Releasing the iterator synchronously calls back into the delegate's cancel().
                let discarded = iterator.withLock { iterator in
                    let discarded = iterator
                    iterator = nil
                    return discarded
                }
                withExtendedLifetime(discarded) {}
            })
        defer { fixture.close() }
        let fallback = stallWatchdog(fixture.control)
        defer { fallback.cancel() }
        let (_, body) = try await fixture.client.get(fixture.url, byteRangeFrom: nil)
        iterator.withLock { $0 = body.makeAsyncIterator() }
        fixture.control.send(Data(repeating: 42, count: 65_536))
        try await waitForHTTPCondition { fixture.control.stopped }
        #expect(iterator.withLock { $0 == nil })
    }

    @Test(.timeLimit(.minutes(1)))
    func getAfterInvalidateThrowsCancelled() async throws {
        let fixture = HTTPFixture(.response(200, ["Content-Length": "0"], []))
        defer { fixture.close() }
        let copy = fixture.client
        fixture.client.invalidate()
        await #expect(throws: LauncherError.cancelled) {
            _ = try await copy.get(fixture.url, byteRangeFrom: nil)
        }
        #expect(!fixture.control.started)
    }

    @Test(.timeLimit(.minutes(1)))
    func urlSessionInvalidationStopsPendingRequests() async throws {
        let fixture = HTTPFixture(.stallBeforeResponse)
        defer { fixture.close() }
        let fallback = stallWatchdog(fixture.control)
        defer { fallback.cancel() }
        let task = Task { try await fixture.client.get(fixture.url, byteRangeFrom: nil) }
        defer { task.cancel() }
        try await waitForHTTPCondition { fixture.control.started }
        fixture.client.invalidate()
        await #expect(throws: LauncherError.cancelled) { try await task.value }
        try await waitForHTTPCondition { fixture.control.stopped }
        #expect(fixture.control.stopReason != .timeout)
    }

    @Test(.timeLimit(.minutes(1)))
    func httpStubRecordsTimeoutStopReason() async throws {
        let fixture = HTTPFixture(.stallBeforeResponse)
        defer { fixture.close() }
        let task = Task { try await fixture.client.get(fixture.url, byteRangeFrom: nil) }
        defer { task.cancel() }
        try await waitForHTTPCondition { fixture.control.started }
        fixture.control.expire()
        do {
            _ = try await task.value
            Issue.record("The watchdog must fail the request")
        } catch LauncherError.transport {}
        #expect(fixture.control.stopReason == .timeout)
    }
}

private final class HTTPBufferMetrics: Sendable {
    struct Snapshot {
        var bytes = 0
        var peak = 0
        var suspended = false
        var suspensions = 0
        var resumptions = 0
    }
    private let state = Mutex(Snapshot())
    var snapshot: Snapshot { state.withLock { $0 } }
    func record(bytes: Int, suspended: Bool) {
        state.withLock {
            $0.bytes = bytes
            $0.peak = max($0.peak, bytes)
            if suspended && !$0.suspended { $0.suspensions += 1 }
            if !suspended && $0.suspended { $0.resumptions += 1 }
            $0.suspended = suspended
        }
    }
}

private enum HTTPStubMode: Sendable {
    case response(Int, [String: String], [Data])
    case pacedResponse([Data])
    case failBeforeResponse, failAfterResponse, externallyCancelled, externallyCancelledAfterResponse
    case stallBeforeResponse, stallAfterResponse, nonHTTP
}

private struct HTTPFixture: Sendable {
    let url: URL
    let session: URLSession
    let client: URLSessionHTTPClient
    let control: HTTPStubControl

    init(
        _ mode: HTTPStubMode,
        highWaterMark: Int = 16 << 20,
        lowWaterMark: Int = 4 << 20,
        timeout: TimeInterval = 15,
        bufferObserver: (@Sendable (Int, Bool) -> Void)? = nil
    ) {
        let url = URL(string: "https://http.test/\(UUID().uuidString)")!
        let control = HTTPStubControl()
        self.url = url
        self.control = control
        HTTPStubProtocol.routes.withLock { $0[url] = (mode, control) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStubProtocol.self]
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        session = URLSession(configuration: configuration)
        client = URLSessionHTTPClient(session: session, highWaterMark: highWaterMark,
            lowWaterMark: lowWaterMark, bufferObserver: bufferObserver)
    }

    func close() {
        session.invalidateAndCancel()
        HTTPStubProtocol.routes.withLock { $0[url] = nil }
    }
}

private final class HTTPStubControl: Sendable {
    enum StopReason {
        case cancelled, timeout
    }

    struct State {
        var started = false
        var stopped = false
        var deliveredBytes = 0
        var request: URLRequest?
        var loader: HTTPStubProtocol?
        var stopReason: StopReason?
    }
    let state = Mutex(State())
    var started: Bool { state.withLock { $0.started } }
    var stopped: Bool { state.withLock { $0.stopped } }
    var deliveredBytes: Int { state.withLock { $0.deliveredBytes } }
    var stopReason: StopReason? { state.withLock { $0.stopReason } }
    var request: URLRequest? { state.withLock { $0.request } }

    func send(_ data: Data) {
        let loader = state.withLock { $0.stopped ? nil : $0.loader }
        if let loader { loader.client?.urlProtocol(loader, didLoad: data) }
    }

    func expire() {
        let loader = state.withLock { state -> HTTPStubProtocol? in
            guard !state.stopped, let loader = state.loader else { return nil }
            state.stopReason = .timeout
            return loader
        }
        if let loader { loader.client?.urlProtocol(loader, didFailWithError: URLError(.timedOut)) }
    }
}

private final class HTTPStubProtocol: URLProtocol, @unchecked Sendable {
    static let routes = Mutex([URL: (HTTPStubMode, HTTPStubControl)]())

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "http.test" }
    override class func canInit(with task: URLSessionTask) -> Bool { task.currentRequest?.url?.host == "http.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let (mode, control) = Self.routes.withLock({ $0[url] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        control.state.withLock { $0.started = true; $0.request = request; $0.loader = self }
        switch mode {
        case .pacedResponse(let chunks):
            respond(200, headers: ["Content-Type": "application/octet-stream",
                "Content-Length": "\(chunks.reduce(0) { $0 + $1.count })"])
            DispatchQueue.global(qos: .utility).async { [self] in
                for chunk in chunks {
                    // A custom URLProtocol producer must honor native task suspension itself.
                    while task?.state == .suspended && !control.stopped {
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                    guard !control.stopped else { return }
                    client?.urlProtocol(self, didLoad: chunk)
                    control.state.withLock { $0.deliveredBytes += chunk.count }
                    Thread.sleep(forTimeInterval: 0.001)
                }
                if !control.stopped { client?.urlProtocolDidFinishLoading(self) }
            }
        case .response(let status, let headers, let chunks):
            respond(status, headers: headers)
            for data in chunks { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        case .externallyCancelled:
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
        case .externallyCancelledAfterResponse:
            respond(200, headers: ["Content-Type": "application/octet-stream", "Content-Length": "1000000"])
            client?.urlProtocol(self, didLoad: Data("partial".utf8))
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
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
        let error = task?.error as NSError?
        let timedOut = error?.domain == NSURLErrorDomain && error?.code == NSURLErrorTimedOut
        control.state.withLock {
            $0.stopped = true
            $0.loader = nil
            if timedOut { $0.stopReason = .timeout }
            else if $0.stopReason == nil { $0.stopReason = .cancelled }
        }
    }

    private func respond(_ status: Int, headers: [String: String] = [:]) {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
}

private func waitForHTTPCondition(timeout: Duration = .seconds(3), _ condition: @Sendable () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { throw LauncherError.io("Timed out waiting for HTTP test condition") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private func stallWatchdog(_ control: HTTPStubControl, timeout: Duration = .seconds(10)) -> Task<Void, any Error> {
    Task {
        try await Task.sleep(for: timeout)
        control.expire()
    }
}
