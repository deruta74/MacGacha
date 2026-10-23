// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Darwin
import Network
import Synchronization
import TestSupport
import LauncherCore

final class ProxyTestPeer: Sendable {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "ProxyTest.peer")
    private let ready = TestEvent(), ended = TestEvent()
    private let failure = ProxyTestBox<NWError?>(nil)
    private let eof = ProxyTestBox(false)
    init(_ connection: NWConnection) {
        self.connection = connection
        connection.stateUpdateHandler = { [ready, ended, failure] state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error), .waiting(let error): failure.withLock { $0 = error }; ready.signal(); connection.cancel()
            case .cancelled: ready.signal(); ended.signal()
            default: break
            }
        }
    }
    static func connect(_ port: UInt16, host: String = "127.0.0.1") async throws -> ProxyTestPeer {
        let peer = ProxyTestPeer(NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp))
        try await peer.start(); return peer
    }
    func start() async throws {
        connection.start(queue: queue); try await ready.wait()
        if let error = failure.withLock({ $0 }) { throw error }
    }
    func cancel() { connection.cancel() }
    func stop() async { cancel(); try? await ended.wait() }
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }
    func send(_ text: String) async throws { try await send(Data(text.utf8)) }
    func finishWrite() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }
    func read(_ maximum: Int = 65_536) async throws -> Data {
        if eof.withLock({ $0 }) { return Data() }
        return try await withCheckedThrowingContinuation { c in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { [eof] data, _, done, error in
                if done { eof.withLock { $0 = true } }
                if let error { c.resume(throwing: error) } else { c.resume(returning: data ?? Data()) }
            }
        }
    }
    func exactly(_ count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            let part = try await read(count - result.count)
            guard !part.isEmpty else { throw LauncherError.io("Unexpected test EOF") }
            result.append(part)
        }
        return result
    }
    func head() async throws -> String {
        var result = Data()
        while !result.suffix(4).elementsEqual([13, 10, 13, 10]) {
            let part = try await read(1)
            guard !part.isEmpty, result.count < 70_000 else { throw LauncherError.io("Missing test response head") }
            result.append(part)
        }
        return String(decoding: result, as: UTF8.self)
    }
    func all() async throws -> Data {
        var result = Data()
        while true { let data = try await read(); if data.isEmpty { return result }; result.append(data) }
    }
}

final class ProxyTestOrigin: @unchecked Sendable {
    let port: UInt16
    private let listener: NWListener
    private let cancelled: TestEvent
    private let peers: ProxyTestBox<[(ProxyTestPeer, Task<Void, Never>)]>
    private init(port: UInt16, listener: NWListener, cancelled: TestEvent, peers: ProxyTestBox<[(ProxyTestPeer, Task<Void, Never>)]>) {
        self.port = port; self.listener = listener; self.cancelled = cancelled; self.peers = peers
    }
    static func start(_ handle: @escaping @Sendable (ProxyTestPeer) async throws -> Void) async throws -> ProxyTestOrigin {
        let queue = DispatchQueue(label: "ProxyTest.origin"), ready = TestEvent(), cancelled = TestEvent()
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        let peers = ProxyTestBox<[(ProxyTestPeer, Task<Void, Never>)]>([])
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .cancelled = state { cancelled.signal() }
        }
        listener.newConnectionHandler = { connection in
            let peer = ProxyTestPeer(connection)
            let task = Task {
                do { try await peer.start(); try await handle(peer) } catch {}
                await peer.stop()
            }
            peers.withLock { $0.append((peer, task)) }
        }
        listener.start(queue: queue); try await ready.wait()
        return ProxyTestOrigin(port: listener.port!.rawValue, listener: listener, cancelled: cancelled, peers: peers)
    }
    func stop() async {
        listener.cancel(); try? await cancelled.wait()
        let active = peers.withLock { $0 }
        for (peer, _) in active { peer.cancel() }
        for (_, task) in active { await task.value }
        listener.newConnectionHandler = nil; listener.stateUpdateHandler = nil
    }
}

final class ProxyTestBox<Value: Sendable>: Sendable {
    private let value: Mutex<Value>
    init(_ value: consuming Value) { self.value = Mutex(value) }
    func withLock<R: Sendable>(_ body: (inout Value) throws -> R) rethrows -> R { try value.withLock { try body(&$0) } }
}

// A kernel TCP half-close avoids Network.framework's client-side terminal-state
// callback cancelling buffered reads after both halves finish. Blocking syscalls
// stay on BlockingIO; the timeout is only a hang guard, never test pacing.
func rawHalfClosedRequest(port: UInt16, request: Data) async throws -> Data {
    try await BlockingIO.run {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LauncherError.io("Test TCP request failed") }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 30, tv_usec: 0), noPipe: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0,
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout.size(ofValue: noPipe))) == 0 else { throw LauncherError.io("Test TCP request failed") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw LauncherError.io("Test TCP request failed") }
        var offset = 0
        while offset < request.count {
            let count = request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset, 0) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw LauncherError.io("Test TCP request failed") }; offset += count
        }
        guard shutdown(fd, SHUT_WR) == 0 else { throw LauncherError.io("Test TCP request failed") }
        var response = Data(), bytes = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, response.count <= 8192 else { throw LauncherError.io("Test TCP request failed") }
            if count == 0 { return response }
            response.append(contentsOf: bytes.prefix(count))
        }
    }
}
