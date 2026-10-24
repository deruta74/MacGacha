// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import DownloadEngine
import LauncherCore
@testable import Sophon

@Suite(.serialized) struct DeliveryHostPolicyTests {
    @Test(arguments: ["https://hoyoverse.com/a", "https://cdn.hoyoverse.com/a", "https://yuanshen.com", "https://autopatchhk.yuanshen.com",
        "https://starrails.com", "https://cdn.starrails.com", "https://zenlesszonezero.com", "https://cdn.zenlesszonezero.com", "https://CDN.HOYOVERSE.COM:8443/a"])
    func acceptsDeliveryHosts(raw: String) {
        #expect(DeliveryHostPolicy.allows(URL(string: raw)!))
    }

    @Test(arguments: ["https://evil-hoyoverse.com", "https://hoyoverse.com.evil.test", "http://hoyoverse.com", "https://user@hoyoverse.com",
        "https://user:pass@hoyoverse.com", "https://127.0.0.1", "https://[::1]", "file:///hoyoverse.com", "https://hoyoverse.com./", "https://notyuanshen.com"])
    func rejectsForeignHTTPUserinfoAndIP(raw: String) {
        #expect(!DeliveryHostPolicy.allows(URL(string: raw)!))
    }

    @Test func factoryBuildsPolicyClient() {
        let client = DeliveryHostPolicy.makeHTTPClient()
        client.invalidate()
    }

    @Test(arguments: [Region.global, .mainlandChina]) func redirectsCannotCrossRegion(region: Region) async throws {
        let client = redirectClient(region: region); defer { client.invalidate() }
        let host = region == .global ? "cdn.hoyoverse.com" : "cdn.mihoyo.com"
        let (head, _) = try await client.get(URL(string: "https://\(host)/other-region")!, byteRangeFrom: nil)
        #expect(head.status == 302)
        #expect(DeliveryRedirectStub.requests.withLock { $0.map(\.host) } == [host])
    }

    @Test func redirectToForeignHostRejected() async throws {
        let client = redirectClient(); defer { client.invalidate() }
        let (head, _) = try await client.get(URL(string: "https://cdn.hoyoverse.com/foreign")!, byteRangeFrom: nil)
        #expect(head.status == 302)
        #expect(DeliveryRedirectStub.requests.withLock { $0.map(\.host) } == ["cdn.hoyoverse.com"])
    }

    @Test func redirectToHTTPRejected() async throws {
        let client = redirectClient(); defer { client.invalidate() }
        let (head, _) = try await client.get(URL(string: "https://cdn.hoyoverse.com/http")!, byteRangeFrom: nil)
        #expect(head.status == 302)
        #expect(DeliveryRedirectStub.requests.withLock { $0.count } == 1)
    }

    @Test func relativeRedirectAllowed() async throws {
        let client = redirectClient(); defer { client.invalidate() }
        let (head, body) = try await client.get(URL(string: "https://cdn.hoyoverse.com/relative")!, byteRangeFrom: nil)
        var bytes = Data(); for try await piece in body { bytes.append(piece) }
        #expect(head.status == 200)
        #expect(String(decoding: bytes, as: UTF8.self) == "ok")
        #expect(DeliveryRedirectStub.requests.withLock { $0.map(\.path) } == ["/relative", "/ok"])
    }

    @Test func redirectLoopFails() async {
        let client = redirectClient(); defer { client.invalidate() }
        let started = ContinuousClock.now
        do {
            _ = try await client.get(URL(string: "https://cdn.hoyoverse.com/loop")!, byteRangeFrom: nil)
            Issue.record("Redirect loop should fail")
        } catch {
            guard case LauncherError.transport = error else { Issue.record("Expected transport error"); return }
        }
        // The session timeout is 15 seconds; this must fail through the redirect limit.
        #expect(started.duration(to: .now) < .seconds(3))
        #expect(DeliveryRedirectStub.requests.withLock { $0.count } > 1)
        #expect(DeliveryRedirectStub.requests.withLock { $0.count } <= 22)
    }
}

private func redirectClient(region: Region = .global) -> URLSessionHTTPClient {
    DeliveryRedirectStub.requests.withLock { $0 = [] }
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 15
    config.protocolClasses = [DeliveryRedirectStub.self]
    return URLSessionHTTPClient(configuration: config, sessionCount: 2, redirectPolicy: { DeliveryHostPolicy.allows($0, region: region) })
}

/// URLProtocol intercepts all traffic locally; redirect targets never reach the network.
/// This follows ArtRedirectTests' standalone approach without a cross-test-target import.
private final class DeliveryRedirectStub: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[URL]>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.requests.withLock { $0.append(url) }
        let location: String?
        switch url.path {
        case "/other-region": location = url.host == "cdn.mihoyo.com" ? "https://cdn.hoyoverse.com/ok" : "https://cdn.mihoyo.com/ok"
        case "/foreign": location = "https://evil.test/target"
        case "/http": location = "http://cdn.hoyoverse.com/target"
        case "/relative": location = "/ok"
        case "/loop": location = "/loop"
        default: location = nil
        }
        if let location, let target = URL(string: location, relativeTo: url)?.absoluteURL {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": location])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("ok".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
