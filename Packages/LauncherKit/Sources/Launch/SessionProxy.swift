// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Network
import LauncherCore

/// Session-owned, loopback-only HTTP proxy. stop() acknowledges native
/// cancellation of the listener and all accepted transports, including tunnels.
public final class SessionProxy: Sendable {
    public let port: UInt16
    private let core: ProxyCore
    private init(port: UInt16, core: ProxyCore) { self.port = port; self.core = core }
    public static func start(blockedHosts: [String], log: @escaping @Sendable (String) -> Void) async throws -> SessionProxy {
        try await start(blockedHosts: blockedHosts, log: log, options: SessionProxyOptions())
    }
    package static func start(blockedHosts: [String], log: @escaping @Sendable (String) -> Void,
        options: SessionProxyOptions) async throws -> SessionProxy {
        let core = ProxyCore(blocked: Set(blockedHosts.map(normalize)), log: log, options: options)
        let port: UInt16 = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { c in core.queue.async { core.start(c) } }
        } onCancel: { core.queue.async { core.stop {} } }
        let proxy = SessionProxy(port: port, core: core)
        if Task.isCancelled { await proxy.stop(); throw LauncherError.cancelled }
        return proxy
    }
    public func stop() async {
        await withCheckedContinuation { c in core.queue.async { self.core.stop { c.resume() } } }
    }
    public static func normalize(host: String) -> String {
        if let address = IPv6Address(host) { return address.debugDescription.lowercased() }
        if let authority = try? HTTPAuthority(host, defaultPort: 80) { return authority.host }
        var value = host.lowercased()
        if value.hasSuffix(".") { value.removeLast() }
        return value
    }
    deinit { let core = core; core.queue.async { core.stop {} } }
}

package enum ProxyDeadline: Sendable { case connect, idle }
package enum SessionProxyEvent: Sendable { case accepted(Int), refused }
package struct ProxyCancellation: Sendable {
    private let action: @Sendable () -> Void
    private let rearm: (@Sendable (@escaping @Sendable () -> Void) -> Void)?
    package init(_ action: @escaping @Sendable () -> Void,
        rearm: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil) { self.action = action; self.rearm = rearm }
    package func cancel() { action() }
    package func reschedule(_ action: @escaping @Sendable () -> Void) -> Bool {
        guard let rearm else { return false }; rearm(action); return true
    }
}
package struct SessionProxyOptions: Sendable {
    // NWConnection TCP does not consult URLSession/system HTTP proxy settings.
    package var connector: @Sendable (String, UInt16) -> NWConnection = { host, port in
        NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }
    package var schedule: @Sendable (ProxyDeadline, DispatchQueue, @escaping @Sendable () -> Void) -> ProxyCancellation = { kind, queue, action in
        let timer = ProxyDeadlineTimer(seconds: kind == .connect ? 30 : 600, queue: queue, action: action)
        return ProxyCancellation({ timer.cancel() }, rearm: { timer.reschedule($0) })
    }
    package var observe: @Sendable (SessionProxyEvent) -> Void = { _ in }
    package init() {}
}
private final class ProxyDeadlineTimer: @unchecked Sendable {
    // All state, including rescheduling/cancellation, belongs to the proxy queue.
    // One source is rearmed in place; cancelled asyncAfter work would accumulate
    // ten minutes of timer allocations during sustained tunnel traffic.
    private let source: any DispatchSourceTimer
    private let seconds: Double
    private var deadline: DispatchTime = .now()
    private var action: @Sendable () -> Void
    init(seconds: Double, queue: DispatchQueue, action: @escaping @Sendable () -> Void) {
        self.seconds = seconds; self.action = action
        source = DispatchSource.makeTimerSource(queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, DispatchTime.now() >= self.deadline else { return }
            self.action()
        }
        reschedule(action); source.resume()
    }
    func reschedule(_ action: @escaping @Sendable () -> Void) {
        self.action = action; deadline = .now() + seconds
        source.schedule(deadline: deadline)
    }
    func cancel() { action = {}; source.cancel() }
}

// All mutable transport/session state is confined to this serial queue. The
// unchecked annotations express that ownership, not concurrent mutable access.
private final class ProxyCore: @unchecked Sendable {
    let queue = DispatchQueue(label: "MacGacha.SessionProxy")
    let blocked: Set<String>
    let log: @Sendable (String) -> Void
    let options: SessionProxyOptions
    private var listener: NWListener?
    private var starting: CheckedContinuation<UInt16, any Error>?
    private var sessions: [UUID: ProxySession] = [:]
    private var active = 0
    private var stopping = false
    private var listenerCancelled = true
    private var stopWaiters: [@Sendable () -> Void] = []
    init(blocked: Set<String>, log: @escaping @Sendable (String) -> Void, options: SessionProxyOptions) {
        self.blocked = blocked; self.log = log; self.options = options
    }
    func start(_ c: CheckedContinuation<UInt16, any Error>) {
        guard !stopping else { c.resume(throwing: LauncherError.cancelled); return }
        starting = c
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener; listenerCancelled = false
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard !self.stopping, let port = self.listener?.port?.rawValue else { return }
                    let c = self.starting; self.starting = nil; c?.resume(returning: port)
                case .failed:
                    let c = self.starting; self.starting = nil
                    c?.resume(throwing: LauncherError.transport("Session proxy could not listen"))
                    self.stop {}
                case .cancelled:
                    self.listenerCancelled = true
                    self.listener?.newConnectionHandler = nil; self.listener?.stateUpdateHandler = nil
                    self.checkStopped()
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        } catch {
            starting = nil; c.resume(throwing: LauncherError.transport("Session proxy could not start"))
        }
    }
    private func accept(_ connection: NWConnection) {
        let admitted = !stopping && active < 256
        let session = ProxySession(core: self, client: connection, admitted: admitted)
        sessions[session.id] = session
        if admitted { active += 1; options.observe(.accepted(active)) }
        else { options.observe(.refused) }
        session.start()
    }
    func removed(_ session: ProxySession) {
        guard sessions.removeValue(forKey: session.id) != nil else { return }
        if session.admitted { active -= 1 }
        checkStopped()
    }
    func stop(_ completion: @escaping @Sendable () -> Void) {
        stopping = true; stopWaiters.append(completion)
        let c = starting; starting = nil; c?.resume(throwing: LauncherError.cancelled)
        listener?.cancel()
        for session in Array(sessions.values) { session.finish() }
        checkStopped()
    }
    private func checkStopped() {
        guard stopping, listenerCancelled, sessions.isEmpty else { return }
        let callbacks = stopWaiters; stopWaiters.removeAll()
        for callback in callbacks { callback() }
    }
}

private final class ProxySession: @unchecked Sendable {
    let id = UUID()
    let admitted: Bool
    private let core: ProxyCore
    private let client: ProxySocket
    private var sockets: [UUID: ProxySocket] = [:]
    private var closed = false, ending = false
    private var idle: ProxyCancellation?, connecting: ProxyCancellation?
    private var idleGeneration = 0, connectGeneration = 0
    private var requestDone = false, responseDone = false, responseStarted = false, closeResponse = false, advancing = false
    private var requestBody: ProxyBodyRelay?
    init(core: ProxyCore, client: NWConnection, admitted: Bool) {
        self.core = core; self.client = ProxySocket(client, queue: core.queue); self.admitted = admitted
    }
    private func own(_ socket: ProxySocket) {
        sockets[socket.id] = socket
        socket.activity = { [weak self] in self?.touch() }
        socket.cancelled = { [weak self] in
            guard let self else { return }
            self.sockets.removeValue(forKey: socket.id)
            if self.closed && self.sockets.isEmpty { self.core.removed(self) }
        }
    }
    func start() {
        own(client)
        client.start { [weak self] ok in
            guard let self, !self.closed else { return }
            if ok && self.admitted { self.nextRequest() } else { self.finish() }
        }
        if !admitted { finish() } else { touch() }
    }
    private func touch() {
        guard !closed else { return }
        idleGeneration += 1
        let generation = idleGeneration
        let action: @Sendable () -> Void = { [weak self] in
            guard let self, generation == self.idleGeneration else { return }; self.finish()
        }
        if idle?.reschedule(action) != true {
            idle?.cancel(); idle = core.options.schedule(.idle, core.queue, action)
        }
    }
    func finish() {
        guard !closed else { return }
        closed = true; idle?.cancel(); connecting?.cancel()
        requestBody?.stop(); requestBody = nil
        for socket in Array(sockets.values) { socket.cancel() }
        if sockets.isEmpty { core.removed(self) }
    }
    private func fail(_ code: Int) {
        guard !closed, !ending else { return }
        ending = true; connecting?.cancel()
        if responseStarted { finish(); return }
        let text = code == 403 ? "Forbidden" : code == 400 ? "Bad Request" : "Bad Gateway"
        let body = "\(text)\n"
        client.send(Data("HTTP/1.1 \(code) \(text)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8), final: true) { [weak self] ok in
            guard let self, !self.closed else { return }
            guard ok else { self.finish(); return }
            self.drainThenFinish()
        }
    }
    private func closeGracefully() {
        guard !closed, !ending else { return }
        ending = true; connecting?.cancel()
        client.endWrite { [weak self] ok in
            guard let self, !self.closed else { return }
            if ok { self.drainThenFinish() } else { self.finish() }
        }
    }
    private func drainThenFinish() {
        // FIN exposes a complete response before close. Cancelling with unread
        // request bytes would reset TCP and discard it. Drain without buffering;
        // the idle deadline and explicit stop still bound this half-close.
        for socket in Array(sockets.values) where socket !== client { socket.cancel() }
        client.discardUntilEOF { [weak self] in self?.finish() }
    }
    private func nextRequest() {
        guard !closed, !ending else { return }
        requestBody = nil
        requestDone = false; responseDone = false; responseStarted = false; advancing = false
        client.head { [weak self] result in
            guard let self, !self.closed, !self.ending else { return }
            let request: HTTPRequestHead
            do { request = try HTTPRequestHead(result.get()) }
            catch is ProxyCleanEOF { self.closeGracefully(); return }
            catch { self.fail(400); return }
            let blocked = self.core.blocked.contains(request.authority.host)
            self.core.log("\(request.authority.text) \(blocked ? "block" : "allow")")
            guard !blocked else { self.fail(403); return }
            self.open(request)
        }
    }
    private func open(_ request: HTTPRequestHead) {
        let upstream = ProxySocket(core.options.connector(request.authority.host, request.authority.port), queue: core.queue)
        own(upstream); connectGeneration += 1
        let generation = connectGeneration
        connecting = core.options.schedule(.connect, core.queue) { [weak self] in
            guard let self, generation == self.connectGeneration else { return }; self.fail(502)
        }
        upstream.start { [weak self] ok in
            guard let self, !self.closed, !self.ending else { return }
            self.connecting?.cancel(); self.connectGeneration += 1
            guard ok else { self.fail(502); return }
            if request.isConnect {
                self.client.send(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)) { [weak self] ok in
                    guard let self, !self.closed else { return }
                    guard ok else { self.finish(); return }
                    self.responseStarted = true
                    let halves = ProxyTunnelEnd { [weak self] in self?.finish() }
                    self.client.tunnel(to: upstream) { halves.ended($0) }
                    upstream.tunnel(to: self.client) { halves.ended($0) }
                }
            } else {
                upstream.send(request.forwarded) { [weak self] ok in
                    guard let self, !self.closed, !self.ending else { return }
                    guard ok else { self.fail(502); return }
                    self.requestDone = HTTPBodyFrame(request.body).done
                    self.readResponse(request, upstream: upstream)
                    self.requestBody = self.client.body(request.body, to: upstream) { [weak self] ok in
                        guard let self, !self.closed, !self.ending else { return }
                        guard ok else { self.fail(400); return }
                        self.requestDone = true; self.advance(request, upstream: upstream)
                    }
                }
            }
        }
    }
    private func readResponse(_ request: HTTPRequestHead, upstream: ProxySocket) {
        upstream.head { [weak self] result in
            guard let self, !self.closed, !self.ending else { return }
            let response: HTTPResponseHead
            do { response = try HTTPResponseHead(result.get(), method: request.method) }
            catch { self.fail(502); return }
            let interim = response.status < 200
            let abandonedUpload = !interim && !self.requestDone
            if abandonedUpload {
                // Stop both pending reads and write-failure callbacks. Neither
                // may interrupt the final response, with or without Expect.
                // Graceful closure drains the client after the full response
                // has been written, bounded by the existing idle deadline.
                self.requestBody?.stop(); self.requestBody = nil
            }
            self.closeResponse = request.close || response.body == .closeDelimited || abandonedUpload
            if !interim { self.responseStarted = true }
            self.client.send(response.forwarded(close: self.closeResponse)) { [weak self] ok in
                guard let self, !self.closed, !self.ending else { return }
                guard ok else { self.finish(); return }
                if interim { self.readResponse(request, upstream: upstream); return }
                upstream.body(response.body, to: self.client) { [weak self] ok in
                    guard let self, !self.closed, !self.ending else { return }
                    guard ok else { self.finish(); return }
                    self.responseDone = true
                    if self.closeResponse { self.closeGracefully() } else { self.advance(request, upstream: upstream) }
                }
            }
        }
    }
    private func advance(_ request: HTTPRequestHead, upstream: ProxySocket) {
        guard requestDone, responseDone, !advancing, !closed else { return }
        advancing = true
        // Downstream stays persistent, but upstream is deliberately one request
        // per connection. This avoids stale authority/response bytes and makes
        // close-delimited origins safe without any pipelining or retry guesses.
        upstream.afterCancellation = { [weak self] in self?.nextRequest() }
        upstream.cancel()
    }
}

private struct ProxyCleanEOF: Error {}

private final class ProxySocket: @unchecked Sendable {
    let id = UUID()
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data(), eof = false, isCancelled = false, reading = false
    private var drainCompletion: (@Sendable () -> Void)?
    private var started: (@Sendable (Bool) -> Void)?
    var activity: (@Sendable () -> Void)?
    var cancelled: (@Sendable () -> Void)?
    var afterCancellation: (@Sendable () -> Void)?
    init(_ connection: NWConnection, queue: DispatchQueue) { self.connection = connection; self.queue = queue }
    func start(_ ready: @escaping @Sendable (Bool) -> Void) {
        started = ready
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: let ready = self.started; self.started = nil; ready?(true)
            case .waiting, .failed:
                let ready = self.started; self.started = nil; ready?(false)
                self.cancel()
            case .cancelled:
                self.isCancelled = true
                let ready = self.started; self.started = nil; ready?(false)
                self.connection.stateUpdateHandler = nil
                let cancelled = self.cancelled; self.cancelled = nil; cancelled?()
                let next = self.afterCancellation; self.afterCancellation = nil; next?()
                self.activity = nil
                let drained = self.drainCompletion; self.drainCompletion = nil; drained?()
            default: break
            }
        }
        connection.start(queue: queue)
    }
    func cancel() { isCancelled = true; connection.cancel() }
    func endWrite(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard !isCancelled else { completion(false); return }
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { error in completion(error == nil) })
    }
    func send(_ data: Data, final: Bool = false, _ completion: @escaping @Sendable (Bool) -> Void) {
        guard !isCancelled else { completion(false); return }
        connection.send(content: data, contentContext: final ? .finalMessage : .defaultMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
            if error == nil { self?.activity?() }; completion(error == nil)
        })
    }
    private func receive(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard !isCancelled, !eof else { completion(!isCancelled); return }
        reading = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { completion(false); return }
            self.reading = false
            guard !self.isCancelled else { completion(false); return }
            let draining = self.drainCompletion != nil
            if let data, !data.isEmpty {
                if !draining { self.buffer.append(data) }
                self.activity?()
            }
            self.eof = done || error != nil
            completion(!draining && error == nil)
            if draining { self.drainStep() }
        }
    }
    func discardUntilEOF(_ completion: @escaping @Sendable () -> Void) {
        buffer.removeAll(keepingCapacity: false); drainCompletion = completion
        drainStep()
    }
    private func drainStep() {
        guard !reading, drainCompletion != nil else { return }
        if eof || isCancelled {
            let drained = drainCompletion; drainCompletion = nil; drained?()
        } else { receive { _ in } }
    }
    func head(_ completion: @escaping @Sendable (Result<Data, any Error>) -> Void) {
        if buffer.isEmpty && eof && !isCancelled { completion(.failure(ProxyCleanEOF())); return }
        if let end = buffer.range(of: Data([13, 10, 13, 10])) {
            let count = buffer.distance(from: buffer.startIndex, to: end.upperBound)
            guard count <= 65_536 else { completion(.failure(ProxyHTTPError())); return }
            completion(.success(HTTPBodyFrame.consume(count, from: &buffer))); return
        }
        do { try HTTPFields.checkLineEndings(buffer) }
        catch { completion(.failure(error)); return }
        guard buffer.count < 65_536, !eof, !isCancelled else { completion(.failure(ProxyHTTPError())); return }
        receive { [weak self] ok in
            guard let self, ok else { completion(.failure(ProxyHTTPError())); return }; self.head(completion)
        }
    }
    @discardableResult
    func body(_ kind: HTTPBodyKind, to target: ProxySocket, _ completion: @escaping @Sendable (Bool) -> Void) -> ProxyBodyRelay {
        let relay = ProxyBodyRelay(source: self, target: target, kind: kind, completion: completion)
        relay.step()
        return relay
    }
    fileprivate func bodyStep(_ frame: inout HTTPBodyFrame) throws -> Data? { try frame.take(from: &buffer, eof: eof) }
    fileprivate func more(_ completion: @escaping @Sendable (Bool) -> Void) { receive(completion) }
    func tunnel(to target: ProxySocket, _ completion: @escaping @Sendable (Bool) -> Void) {
        guard !isCancelled else { completion(false); return }
        if !buffer.isEmpty {
            let bytes = HTTPBodyFrame.consume(buffer.count, from: &buffer)
            target.send(bytes) { [weak self] ok in
                guard let self, ok else { completion(false); return }; self.tunnel(to: target, completion)
            }
        } else if eof {
            target.connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in completion(error == nil) })
        } else {
            receive { [weak self] ok in
                guard let self, ok else { completion(false); return }; self.tunnel(to: target, completion)
            }
        }
    }
}
private final class ProxyBodyRelay: @unchecked Sendable {
    let source: ProxySocket, target: ProxySocket
    var frame: HTTPBodyFrame
    // Queue-confined like the sockets. Stopping also silences an in-flight
    // upstream send failure while a final response is being relayed.
    private var completion: (@Sendable (Bool) -> Void)?
    private var stopped = false
    init(source: ProxySocket, target: ProxySocket, kind: HTTPBodyKind, completion: @escaping @Sendable (Bool) -> Void) {
        self.source = source; self.target = target; self.frame = HTTPBodyFrame(kind); self.completion = completion
    }
    func stop() { stopped = true; completion = nil }
    private func complete(_ ok: Bool) {
        let callback = completion
        stop(); callback?(ok)
    }
    func step() {
        guard !stopped else { return }
        do {
            if let bytes = try source.bodyStep(&frame) {
                target.send(bytes) { ok in if ok { self.step() } else { self.complete(false) } }
            } else if frame.done { complete(true) }
            else { source.more { ok in if ok { self.step() } else { self.complete(false) } } }
        } catch { complete(false) }
    }
}
private final class ProxyTunnelEnd: @unchecked Sendable {
    private var count = 0
    private let finish: @Sendable () -> Void
    init(_ finish: @escaping @Sendable () -> Void) { self.finish = finish }
    func ended(_ ok: Bool) { count += 1; if !ok || count == 2 { finish() } }
}
