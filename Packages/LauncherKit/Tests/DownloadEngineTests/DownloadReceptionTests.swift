// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Network
import Synchronization
import Testing
import TestSupport
@testable import DownloadEngine

@Suite(.serialized, .timeLimit(.minutes(1))) struct DownloadReceptionTests {
    @Test(arguments: [false, true]) func sharedBudgetBoundsNativeReceptionAcrossSmallAndLargeBodies(initiallyLimited: Bool) async throws {
        let server = try ReceptionServer()
        defer { server.close() }
        let base = try await server.start()
        let clock = RateClock(), rate: Int64 = 5_000_000
        let limiter = DownloadRateLimiter(bytesPerSecond: initiallyLimited ? rate : nil, clock: clock)
        let receipts = ReceptionReceipts(), counts = NativeReceptionCounts(clock: clock)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 32
        configuration.timeoutIntervalForRequest = 30
        let client = URLSessionHTTPClient(configuration: configuration, sessionCount: 4)
            .limitingReception(using: limiter)
            .observingTaskTransitions { task, _ in counts.register(task) }
            .observingDataCallbacks { task, bytes, _ in
                let path = task.currentRequest?.url?.path ?? ""
                let acknowledgments = receipts.record(bytes, path: path)
                counts.record()
                for _ in 0..<acknowledgments { server.acknowledge(path) }
            }
        defer { client.invalidate() }
        if initiallyLimited {
            // Start with no credit so every native request is registered before
            // the first clock tick, independently of connection scheduling.
            var exhausted = 0
            while exhausted < 500_000 { exhausted += try await limiter.acquire(upTo: 500_000 - exhausted) }
            counts.begin()
        }
        let completed = Mutex(0)
        let tasks = (0..<32).map { index in Task {
            defer { completed.withLock { $0 += 1 } }
            let size = index.isMultiple(of: 2) ? ReceptionServer.smallSize : ReceptionServer.largeSize
            let url = base.appendingPathComponent(index.isMultiple(of: 2) ? "small/\(index)" : "large/\(index)")
            let (_, body) = try await client.get(url, byteRangeFrom: nil)
            var count = 0
            for try await bytes in body { count += bytes.count }
            #expect(count == size)
        } }
        defer { tasks.forEach { $0.cancel() } }
        do {
            if !initiallyLimited {
                // Enable the limit from the first real data callback while all
                // requests are live. Reception, rather than consumer progress,
                // determines when this transition occurs.
                try await receipts.prefixes.wait()
                let changed = TestEvent()
                receipts.arm {
                    limiter.setBytesPerSecond(rate)
                    Task {
                        while limiter.isTransitioning { await Task.yield() }
                        counts.begin()
                        changed.signal()
                    }
                }
                server.flow.signal()
                try await changed.wait()
            } else { server.flow.signal() }
            var waits = clock.waits.makeAsyncIterator()
            for _ in 0..<10 {
                guard try await quiescentWait(limiter, remaining: { 32 - completed.withLock { $0 } }, counts: counts, waits: &waits) != nil else { break }
                counts.record()
                clock.advance(to: clock.now.advanced(by: .milliseconds(100)), wakingSleepers: true)
            }
            _ = try await quiescentWait(limiter, remaining: { 32 - completed.withLock { $0 } }, counts: counts, waits: &waits)
            counts.record()
            let samples = counts.end()
            let burst = 500_000 + (4 << 20) // 100 ms credit plus a 4 MiB native transition/read-ahead bound
            #expect(samples.last?.bytes ?? 0 > 0)
            var largestExcess = 0.0
            for lower in samples.indices {
                for upper in lower..<samples.count {
                    let received = samples[upper].bytes - samples[lower].bytes
                    let duration = samples[lower].time.duration(to: samples[upper].time).components
                    let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                    largestExcess = max(largestExcess, Double(received) - Double(rate) * seconds)
                }
            }
            #expect(largestExcess <= Double(burst))
            limiter.setBytesPerSecond(nil)
            // No clock advancement is needed to release every suspended producer.
            for task in tasks { try await task.value }
            #expect(limiter.pendingAcquisitions == 0)
        } catch {
            client.invalidate(); tasks.forEach { $0.cancel() }; server.close()
            for task in tasks { _ = try? await task.value }
            throw error
        }
    }
}

private func quiescentWait(_ limiter: DownloadRateLimiter, remaining: @Sendable () -> Int, counts: NativeReceptionCounts, waits: inout AsyncStream<RateClock.Wait>.Iterator) async throws -> RateClock.Wait? {
    while remaining() > 0 {
        let wait = try #require(await waits.next())
        if !wait.active { continue }
        while limiter.pendingAcquisitions != remaining() || limiter.isReceiving || !counts.allPaused { try Task.checkCancellation(); await Task.yield() }
        if wait.active { return wait }
    }
    return nil
}

private final class ReceptionReceipts: Sendable {
    private struct State { var total = 0; var received: [String: Int] = [:]; var transition: (@Sendable () -> Void)? }
    private let state = Mutex(State())
    let prefixes = TestEvent()
    func arm(_ transition: @escaping @Sendable () -> Void) { state.withLock { $0.transition = transition } }
    func record(_ bytes: Int, path: String) -> Int {
        let result = state.withLock { state in
            state.total += bytes
            let prior = state.received[path] ?? 0
            state.received[path] = prior + bytes
            let transition = state.transition; state.transition = nil
            return (state.total >= 32 * 65_536, transition, (prior + bytes) / 65_536 - prior / 65_536)
        }
        result.1?()
        if result.0 { prefixes.signal() }
        return result.2
    }
}

/// Samples URLSession's native byte counters, including bytes it has already
/// received ahead of delegate callbacks. Consumer reads never enter this probe.
private final class NativeReceptionCounts: Sendable {
    struct Sample: Sendable { let time: ContinuousClock.Instant; let bytes: Int64 }
    private struct State { var active = false; var baseline: Int64 = 0; var high: Int64 = 0; var samples: [Sample] = [] }
    private let tasks = Mutex<[ObjectIdentifier: URLSessionTask]>([:])
    private let state = Mutex(State())
    private let clock: RateClock
    init(clock: RateClock) { self.clock = clock }
    func register(_ task: URLSessionTask) { tasks.withLock { $0[ObjectIdentifier(task)] = task } }
    var allPaused: Bool { tasks.withLock { $0.values.allSatisfy { $0.state != .running } } }
    private var total: Int64 { tasks.withLock { $0.values.reduce(0) { $0 + $1.countOfBytesReceived } } }
    func begin() {
        let baseline = total
        state.withLock { $0 = State(active: true, baseline: baseline, samples: [Sample(time: clock.now, bytes: 0)]) }
    }
    func end() -> [Sample] { state.withLock { $0.active = false; return $0.samples } }
    func record() {
        let total = total
        state.withLock { state in
            guard state.active else { return }
            state.high = max(state.high, total - state.baseline)
            state.samples.append(Sample(time: clock.now, bytes: state.high))
        }
    }
}

/// Real loopback TCP with a bounded packet window and receipt handshakes.
/// This keeps native overshoot deterministic under CPU pressure, without using
/// consumer pulls or native task state to decide which packets may be sent.
private final class ReceptionServer: Sendable {
    static let smallSize = 1 << 20, largeSize = 8 << 20
    private let listener: NWListener
    private let queue = DispatchQueue(label: "MacGacha.Test.ReceptionServer")
    private struct State {
        var closed = false
        var connections: [ObjectIdentifier: NWConnection] = [:]
        var acknowledgments: [String: Int] = [:]
        var next: [String: @Sendable () -> Void] = [:]
    }
    private let connections = Mutex(State())
    private let ready = TestEvent()
    let flow = TestEvent()
    private let payload = Data(repeating: 7, count: 65_536)
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> URL {
        listener.stateUpdateHandler = { [ready] state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        try await ready.wait()
        let port = try #require(listener.port)
        return try #require(URL(string: "http://127.0.0.1:\(port.rawValue)"))
    }
    func close() {
        listener.cancel()
        flow.signal()
        let active = connections.withLock { state in state.closed = true; let active = Array(state.connections.values); state.connections.removeAll(); state.next.removeAll(); return active }
        active.forEach { $0.cancel() }
    }
    // One 64 KiB packet per connection can be in flight. Client receipt
    // handshakes, rather than wall-clock delays or scheduler speed, advance
    // the sender. A consumer-only limiter still receives up to every watermark.
    func acknowledge(_ path: String) {
        let next: (@Sendable () -> Void)? = connections.withLock { state in
            if let next = state.next.removeValue(forKey: path) { return next }
            state.acknowledgments[path, default: 0] += 1
            return nil
        }
        if let next { queue.async(execute: next) }
    }
    private func awaitAcknowledgment(_ path: String, next: @escaping @Sendable () -> Void) {
        let ready = connections.withLock { state in
            guard !state.closed else { return false }
            if state.acknowledgments[path, default: 0] > 0 {
                state.acknowledgments[path, default: 0] -= 1; return true
            }
            state.next[path] = next; return false
        }
        if ready { queue.async(execute: next) }
    }
    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let accepted = connections.withLock { state in
            guard !state.closed else { return false }
            state.connections[id] = connection; return true
        }
        guard accepted else { connection.cancel(); return }
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { _ = self?.connections.withLock { $0.connections.removeValue(forKey: id) } }
        }
        connection.start(queue: queue)
        readRequest(connection, prefix: Data())
    }
    private func readRequest(_ connection: NWConnection, prefix: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] bytes, _, complete, error in
            guard let self, error == nil, let bytes, !bytes.isEmpty, prefix.count < 8192 else { connection.cancel(); return }
            var request = prefix; request.append(bytes)
            guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if !complete { self.readRequest(connection, prefix: request) } else { connection.cancel() }
                return
            }
            let text = String(decoding: request, as: UTF8.self)
            let path = text.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let size = path.contains("/small") ? Self.smallSize : Self.largeSize
            let header = Data("HTTP/1.1 200 OK\r\nContent-Length: \(size)\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: header, completion: .contentProcessed { [weak self] error in
                if error == nil { self?.sendBody(connection, path: path, remaining: size, pauseAfterPrefix: true) } else { connection.cancel() }
            })
        }
    }
    private func sendBody(_ connection: NWConnection, path: String, remaining: Int, pauseAfterPrefix: Bool = false) {
        guard remaining > 0, !connections.withLock({ $0.closed }) else { connection.cancel(); return }
        let count = min(remaining, payload.count)
        connection.send(content: payload.prefix(count), completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { connection.cancel(); return }
            if pauseAfterPrefix {
                Task { [weak self, flow] in
                    do {
                        try await flow.wait()
                        self?.awaitAcknowledgment(path) { [weak self] in self?.sendBody(connection, path: path, remaining: remaining - count) }
                    }
                    catch { connection.cancel() }
                }
            } else {
                self.awaitAcknowledgment(path) { [weak self] in self?.sendBody(connection, path: path, remaining: remaining - count) }
            }
        })
    }
}
