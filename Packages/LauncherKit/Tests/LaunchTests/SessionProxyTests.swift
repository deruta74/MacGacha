// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Network
import Synchronization
import Testing
import TestSupport
import LauncherCore
import Darwin
@testable import Launch

@Suite(.timeLimit(.minutes(1))) struct SessionProxyTests {
    @Test func disabledLogsDoNotDisableHostBlocking() async throws {
        let logs = ProxyTestBox<[String]>([])
        let proxy = try await SessionProxy.start(blockedHosts: ["blocked.test"], sessionLogsEnabled: false,
            log: { line in logs.withLock { $0.append(line) } })
        do {
            let client = try await ProxyTestPeer.connect(proxy.port); defer { client.cancel() }
            try await client.send("CONNECT blocked.test:443 HTTP/1.1\r\n\r\n")
            #expect(String(decoding: try await client.all(), as: UTF8.self).hasPrefix("HTTP/1.1 403"))
            #expect(logs.withLock { $0 }.isEmpty)
        } catch { await proxy.stop(); throw error }
        await proxy.stop()
    }

    @Test(arguments: [("Blocked.Test.:443", "blocked.test"), ("[::1]:443", "::1"), ("[0:0:0:0:0:0:0:1]", "::1"), ("::1", "::1")])
    func normalizedHost(value: String, expected: String) { #expect(SessionProxy.normalize(host: value) == expected) }

    @Test func connectAllowedTunnelsBytes() async throws {
        try await withProxy(origin: { peer in
            while true { let data = try await peer.read(); if data.isEmpty { return }; try await peer.send(data) }
        }) { proxy, _, logs in
            let client = try await ProxyTestPeer.connect(proxy.port); defer { client.cancel() }
            try await client.send("CONNECT origin.test:443 HTTP/1.1\r\n\r\n")
            #expect(try await client.head().hasPrefix("HTTP/1.1 200"))
            let bytes = Data((0..<1_048_576).map { UInt8(truncatingIfNeeded: $0) })
            async let sent: Void = client.send(bytes)
            let echoed = try await client.exactly(bytes.count); try await sent
            #expect(echoed == bytes)
            #expect(logs.withLock { $0 } == ["origin.test:443 allow"])
            try await client.finishWrite()
            #expect(try await client.read().isEmpty)
        }
    }
    @Test func connectBlockedReturns403AndExactMatchingOnly() async throws {
        try await withProxy(origin: { peer in try await peer.send(try await peer.read()) }) { proxy, _, logs in
            for host in ["Blocked.Test.", "globaldp-prod-os01.starrails.com"] {
                let client = try await ProxyTestPeer.connect(proxy.port); defer { client.cancel() }
                try await client.send("CONNECT \(host):443 HTTP/1.1\r\n\r\n")
                let response = String(decoding: try await client.all(), as: UTF8.self)
                #expect(response.hasPrefix("HTTP/1.1 403") && response.contains("Connection: close"))
            }
            let client = try await ProxyTestPeer.connect(proxy.port); defer { client.cancel() }
            try await client.send("CONNECT a.blocked.test:443 HTTP/1.1\r\n\r\n")
            #expect(try await client.head().hasPrefix("HTTP/1.1 200"))
            #expect(logs.withLock { $0 } == ["blocked.test:443 block", "globaldp-prod-os01.starrails.com:443 block", "a.blocked.test:443 allow"])
        }
    }
    @Test func plainHTTPUsesAbsoluteFormAuthorityAndRechecksPersistentRequests() async throws {
        let requests = ProxyTestBox<[String]>([])
        try await withProxy(origin: { peer in
            requests.withLock { $0.append("") }
            let head = try await peer.head(); requests.withLock { $0[$0.count - 1] = head }
            try await peer.send("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
        }) { proxy, _, logs in
            let client = try await ProxyTestPeer.connect(proxy.port); defer { client.cancel() }
            try await client.send("GET http://origin.test:8080/x?q=secret HTTP/1.1\r\nHost: spoof.test\r\nProxy-Authorization: secret\r\n\r\n")
            #expect(try await client.head().contains("Content-Length: 2")); #expect(try await client.exactly(2) == Data("ok".utf8))
            try await client.send("GET http://blocked.test/y HTTP/1.1\r\n\r\n")
            #expect(String(decoding: try await client.all(), as: UTF8.self).hasPrefix("HTTP/1.1 403"))
            #expect(requests.withLock { $0 } == ["GET /x?q=secret HTTP/1.1\r\nHost: origin.test:8080\r\nConnection: close\r\n\r\n"])
            #expect(logs.withLock { $0 } == ["origin.test:8080 allow", "blocked.test:80 block"])
        }
    }
    @Test func sequentialAuthorityChangesAndResponseFraming() async throws {
        let count = ProxyTestBox(0)
        let responses = [
            "HTTP/1.1 103 Early Hints\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
            "HTTP/1.1 204 No Content\r\n\r\n", "HTTP/1.1 304 Not Modified\r\nContent-Length: 99\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: 123\r\n\r\n",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\n\r\n",
            "HTTP/1.1 200 OK\r\n\r\nclose-body",
        ]
        try await withProxy(origin: { peer in
            _ = try await peer.head()
            let n = count.withLock { value in let old = value; value += 1; return old }
            try await peer.send(responses[n])
        }) { proxy, _, logs in
            let client = try await ProxyTestPeer.connect(proxy.port); defer { client.cancel() }
            for n in 0..<responses.count {
                try await client.send("\(n == 3 ? "HEAD" : "GET") http://origin\(n).test/x HTTP/1.1\r\n\r\n")
                var head = try await client.head()
                if n == 0 { #expect(head.hasPrefix("HTTP/1.1 103")); head = try await client.head() }
                #expect(head.hasPrefix("HTTP/1.1 \([200, 204, 304, 200, 200, 200][n])"))
                if n == 0 { #expect(try await client.exactly(2) == Data("ok".utf8)) }
                if n == 4 { #expect(try await client.exactly(12) == Data("2\r\nok\r\n0\r\n\r\n".utf8)) }
                if n == 5 { #expect(try await client.all() == Data("close-body".utf8)) }
            }
            #expect(logs.withLock { $0.count } == 6)
        }
    }
    @Test func contentLengthRequestCompletesBeforeNextRequestIsProcessed() async throws {
        let release = TestEvent(), payload = Data([0, 10, 13, 255])
        try await withProxy(origin: { peer in
            _ = try await peer.head()
            #expect(try await peer.exactly(4) == payload)
            try await peer.send("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\no")
            try await release.wait(); try await peer.send("k")
        }) { proxy, _, logs in
            let client = try await ProxyTestPeer.connect(proxy.port); defer { client.cancel(); release.signal() }
            // Buffered next-request bytes must not be interpreted while the
            // current response is incomplete, regardless of a fast origin.
            try await client.send(Data("POST http://origin.test/x HTTP/1.1\r\nContent-Length: 4\r\n\r\n".utf8)
                + payload + Data("GET http://blocked.test/x HTTP/1.1\r\n\r\n".utf8))
            #expect(try await client.head().hasPrefix("HTTP/1.1 200"))
            #expect(try await client.exactly(1) == Data("o".utf8))
            #expect(logs.withLock { $0 } == ["origin.test:80 allow"])
            release.signal()
            #expect(try await client.exactly(1) == Data("k".utf8))
            #expect(String(decoding: try await client.all(), as: UTF8.self).hasPrefix("HTTP/1.1 403"))
        }
    }
    @Test func idleTimerAllocationIsConstantAcrossTraffic() async throws {
        let allocated = ProxyTestBox(0)
        try await withProxy(origin: { peer in
            while true { let data = try await peer.read(); if data.isEmpty { return }; try await peer.send(data) }
        }, configure: { options in
            let normal = options.schedule
            options.schedule = { kind, queue, action in
                if kind == .idle { allocated.withLock { $0 += 1 } }
                return normal(kind, queue, action)
            }
        }) { proxy, _, _ in
            let client = try await ProxyTestPeer.connect(proxy.port); defer { client.cancel() }
            try await client.send("CONNECT origin.test:443 HTTP/1.1\r\n\r\n"); _ = try await client.head()
            for _ in 0..<4 { try await client.send("hello"); #expect(try await client.exactly(5) == Data("hello".utf8)) }
            #expect(allocated.withLock { $0 } == 1)
        }
    }
    @Test func cleanRequestBoundaryEOFDoesNotAppend400() async throws {
        try await withProxy(origin: { peer in
            _ = try await peer.head(); try await peer.send("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        }) { proxy, _, _ in
            let result = try await rawHalfClosedRequest(port: proxy.port, request: Data("GET http://origin.test/x HTTP/1.1\r\n\r\n".utf8))
            #expect(result == Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok".utf8))
        }
    }
    @Test func earlyClosingResponseSurvivesUnreadUploadBytes() async throws {
        try await withProxy(origin: { peer in
            _ = try await peer.head(); try await peer.send("HTTP/1.1 417 Expectation Failed\r\nContent-Length: 0\r\n\r\n")
            while !(try await peer.read()).isEmpty {} // do not reset the origin side
        }) { proxy, _, _ in
            let client = try await ProxyTestPeer.connect(proxy.port)
            let upload = Data("POST http://origin.test/x HTTP/1.1\r\nContent-Length: 32000000\r\nExpect: 100-continue\r\n\r\n".utf8)
                + Data(repeating: 1, count: 16_000_000)
            let sending = Task { try? await client.send(upload) }
            do {
                #expect(try await client.head().hasPrefix("HTTP/1.1 417"))
                #expect(try await client.all().isEmpty)
            } catch { client.cancel(); await sending.value; throw error }
            client.cancel(); await sending.value
        }
    }
    @Test(arguments: [false, true])
    func early413StopsUploadAndFinishesResponse(expectContinue: Bool) async throws {
        let responsePrefix = Data(repeating: 2, count: 65_536)
        let responseSuffix = Data(repeating: 3, count: 131_072)
        let uploadSent = TestEvent(), originDrained = TestEvent()
        let receivedUpload = ProxyTestBox(Data())
        try await withProxy(origin: { peer in
            _ = try await peer.head()
            try await peer.send("HTTP/1.1 413 Content Too Large\r\nContent-Length: \(responsePrefix.count + responseSuffix.count)\r\n\r\n")
            try await peer.send(responsePrefix)
            try await uploadSent.wait()
            try await peer.send(responseSuffix)
            // The proxy must stop uploading when it sees the final head, even
            // while the response is still incomplete. Wait for its upstream
            // close and retain every byte that incorrectly escaped the drain.
            let bytes = try await peer.all()
            receivedUpload.withLock { $0 = bytes }
            originDrained.signal()
        }) { proxy, _, _ in
            let client = try await ProxyTestPeer.connect(proxy.port)
            defer { client.cancel(); uploadSent.signal() }
            let expect = expectContinue ? "Expect: 100-continue\r\n" : ""
            try await client.send("POST http://origin.test/reject HTTP/1.1\r\nContent-Length: 1000000\r\n\(expect)\r\n")
            let head = try await client.head()
            #expect(head.hasPrefix("HTTP/1.1 413"))
            try #require(head.lowercased().contains("connection: close\r\n"))
            #expect(try await client.exactly(responsePrefix.count) == responsePrefix)
            // Only part of the declared upload is sent. No EOF is sent until
            // after the full response: neither body completion nor client FIN
            // may be needed to deliver the response and half-close output.
            try await client.send(Data(repeating: 1, count: 65_536))
            uploadSent.signal()
            #expect(try await client.all() == responseSuffix)
            try await originDrained.wait()
            #expect(receivedUpload.withLock { $0.isEmpty })
            try await client.finishWrite()
        }
    }
    @Test func rejectedContinueDoesNotWaitForClientBody() async throws {
        try await withProxy(origin: { peer in
            _ = try await peer.head(); try await peer.send("HTTP/1.1 417 Expectation Failed\r\nContent-Length: 0\r\n\r\n")
        }) { proxy, _, _ in
            let client = try await ProxyTestPeer.connect(proxy.port); defer { client.cancel() }
            try await client.send("POST http://origin.test/x HTTP/1.1\r\nContent-Length: 999\r\nExpect: 100-continue\r\n\r\n")
            #expect(try await client.head().hasPrefix("HTTP/1.1 417"))
            #expect(try await client.read().isEmpty)
        }
    }
    @Test func partialHeadersChunkedBodyAndContinue() async throws {
        let body = "3\r\nabc\r\n0\r\nX-Sum: yes\r\n\r\n", received = ProxyTestBox(Data())
        try await withProxy(origin: { peer in
            let head = try await peer.head()
            #expect(head.contains("Expect: 100-continue"))
            try await peer.send("HTTP/1.1 100 Continue\r\n\r\n")
            let data = try await peer.exactly(body.utf8.count); received.withLock { $0 = data }
            try await peer.send("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        }) { proxy, _, _ in
            let client = try await ProxyTestPeer.connect(proxy.port); defer { client.cancel() }
            for byte in "POST http://origin.test/x HTTP/1.1\r\nTransfer-Encoding: chunked\r\nExpect: 100-continue\r\n\r\n".utf8 { try await client.send(Data([byte])) }
            #expect(try await client.head().hasPrefix("HTTP/1.1 100"))
            try await client.send(body)
            #expect(try await client.head().hasPrefix("HTTP/1.1 200"))
            #expect(received.withLock { $0 } == Data(body.utf8))
        }
    }
    @Test(arguments: ["GET /x HTTP/1.1\r\n\r\n", "GET http://origin.test/x HTTP/1.1\nHost: x\n\n", "GET http://origin.test/x HTTP/1.1\r\nUpgrade: websocket\r\n\r\n"])
    func malformedAndOverLimitHeadersReturn400(request: String) async throws {
        try await withProxy(origin: { _ in Issue.record("Malformed request reached origin") }) { proxy, _, _ in
            let client = try await ProxyTestPeer.connect(proxy.port); defer { client.cancel() }
            try await client.send(request)
            #expect(String(decoding: try await client.all(), as: UTF8.self).hasPrefix("HTTP/1.1 400"))
        }
    }
    @Test func headerLimit() async throws {
        try await withProxy(origin: { _ in Issue.record("Over-limit headers reached origin") }) { proxy, _, _ in
            let client = try await ProxyTestPeer.connect(proxy.port); defer { client.cancel() }
            try await client.send("GET http://origin.test/x HTTP/1.1\r\nX: " + String(repeating: "a", count: 65_536))
            #expect(try await client.head().hasPrefix("HTTP/1.1 400"))
        }
    }
    @Test func unreachableUpstream502() async throws {
        try await withProxy(origin: { _ in Issue.record("Failed connector reached origin") }, configure: { options in
            // An empty Unix-domain address fails without DNS or a released TCP
            // port that another parallel test could acquire.
            options.connector = { _, _ in NWConnection(to: .unix(path: ""), using: .tcp) }
        }) { proxy, _, _ in
            let client = try await ProxyTestPeer.connect(proxy.port); defer { client.cancel() }
            try await client.send("CONNECT origin.test:443 HTTP/1.1\r\n\r\n")
            #expect(try await client.head().hasPrefix("HTTP/1.1 502"))
        }
    }
    @Test func connectTimeoutUsesInjectedDeadline() async throws {
        try await withProxy(origin: { _ in }, configure: { options in
            let normal = options.schedule
            options.schedule = { kind, queue, action in
                if kind == .connect {
                    // Queued before upstream.start: independent of native TCP
                    // readiness speed, this deadline deterministically wins.
                    queue.async(execute: action); return ProxyCancellation {}
                }
                return normal(kind, queue, action)
            }
        }) { proxy, _, _ in
            let client = try await ProxyTestPeer.connect(proxy.port); defer { client.cancel() }
            try await client.send("CONNECT origin.test:443 HTTP/1.1\r\n\r\n")
            #expect(try await client.head().hasPrefix("HTTP/1.1 502"))
        }
    }
    @Test func idleDeadlineClosesTunnelAndStaleDeadlinesCannotCloseActiveTraffic() async throws {
        let timers = ProxyTestTimers(), originClosed = TestEvent()
        try await withProxy(origin: { peer in
            defer { originClosed.signal() }
            while true { let data = try await peer.read(); if data.isEmpty { return }; try await peer.send(data) }
        }, configure: { $0.schedule = { timers.schedule($0, queue: $1, action: $2) } }) { proxy, _, _ in
            let client = try await ProxyTestPeer.connect(proxy.port); defer { client.cancel() }
            try await client.send("CONNECT origin.test:443 HTTP/1.1\r\n\r\n"); _ = try await client.head()
            await timers.fireIdle(oldest: true)
            try await client.send("ok"); #expect(try await client.exactly(2) == Data("ok".utf8))
            await timers.fireIdle(oldest: false)
            #expect(try await client.read().isEmpty)
            try await originClosed.wait()
        }
    }
    @Test func connectionLimitRefuses257AndKeepsFirst256Usable() async throws {
        let full = TestEvent(), refused = TestEvent()
        try await withProxy(origin: { _ in Issue.record("Blocked request connected upstream") }, configure: { options in
            options.observe = { event in
                if case .accepted(256) = event { full.signal() }
                if case .refused = event { refused.signal() }
            }
        }) { proxy, _, _ in
            var clients: [ProxyTestPeer] = []
            defer { for client in clients { client.cancel() } }
            for _ in 0..<256 { clients.append(try await ProxyTestPeer.connect(proxy.port)) }
            try await full.wait()
            do {
                let extra = try await ProxyTestPeer.connect(proxy.port); defer { extra.cancel() }
                do { #expect(try await extra.read().isEmpty) } catch {} // reset also refuses the transport
            } catch {}
            try await refused.wait()
            for client in clients {
                try await client.send("CONNECT blocked.test:443 HTTP/1.1\r\n\r\n")
                #expect(try await client.head().hasPrefix("HTTP/1.1 403"))
            }
        }
    }
    @Test func listenerIsOnlyLoopbackAndStopClosesConnections() async throws {
        try await withProxy(origin: { peer in while !(try await peer.read()).isEmpty {} }) { proxy, _, _ in
            let client = try await ProxyTestPeer.connect(proxy.port); defer { client.cancel() }
            let sockets = try await BlockingIO.run {
                try await SystemProcessRunner().run(URL(fileURLWithPath: "/usr/sbin/lsof"),
                    arguments: ["-nP", "-a", "-p", String(getpid()), "-iTCP:\(proxy.port)", "-sTCP:LISTEN", "-Fn"],
                    environment: ["PATH": "/usr/bin:/bin"], currentDirectory: nil)
            }
            #expect(sockets.exitCode == 0)
            let names = String(decoding: sockets.stdout, as: UTF8.self).split(separator: "\n").filter { $0.first == "n" }
            #expect(names == ["n127.0.0.1:\(proxy.port)"])
            try await client.send("CONNECT origin.test:443 HTTP/1.1\r\n\r\n"); _ = try await client.head()
            await proxy.stop(); await proxy.stop()
            #expect(try await client.read().isEmpty)
            await #expect(throws: (any Error).self) { _ = try await ProxyTestPeer.connect(proxy.port) }
        }
    }
}

private func withProxy(origin handle: @escaping @Sendable (ProxyTestPeer) async throws -> Void,
    configure: (inout SessionProxyOptions) -> Void = { _ in },
    _ body: (SessionProxy, ProxyTestOrigin, ProxyTestBox<[String]>) async throws -> Void) async throws {
    let origin = try await ProxyTestOrigin.start(handle), logs = ProxyTestBox<[String]>([])
    var options = SessionProxyOptions()
    options.connector = { _, _ in NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: origin.port)!, using: .tcp) }
    configure(&options)
    let proxy = try await SessionProxy.start(blockedHosts: ["blocked.test", "globaldp-prod-os01.starrails.com"], log: { value in logs.withLock { $0.append(value) } }, options: options)
    do { try await body(proxy, origin, logs) }
    catch { await proxy.stop(); await origin.stop(); throw error }
    await proxy.stop(); await origin.stop()
}

private final class ProxyTestTimers: Sendable {
    final class Ticket: Sendable {
        let kind: ProxyDeadline, queue: DispatchQueue, action: @Sendable () -> Void
        let cancelled = ProxyTestBox(false)
        init(_ kind: ProxyDeadline, queue: DispatchQueue, action: @escaping @Sendable () -> Void) {
            self.kind = kind; self.queue = queue; self.action = action
        }
    }
    let tickets = ProxyTestBox<[Ticket]>([])
    func schedule(_ kind: ProxyDeadline, queue: DispatchQueue, action: @escaping @Sendable () -> Void) -> ProxyCancellation {
        let ticket = Ticket(kind, queue: queue, action: action)
        tickets.withLock { $0.append(ticket) }
        return ProxyCancellation { ticket.cancelled.withLock { $0 = true } }
    }
    func fireIdle(oldest: Bool) async {
        let queue = tickets.withLock { $0.first!.queue }
        await withCheckedContinuation { c in
            queue.async {
                let ticket = self.tickets.withLock { items in
                    oldest ? items.first { $0.kind == .idle } : items.last { $0.kind == .idle && !$0.cancelled.withLock({ $0 }) }
                }
                ticket?.action(); c.resume()
            }
        }
    }
}
