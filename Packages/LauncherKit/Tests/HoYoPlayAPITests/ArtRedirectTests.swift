// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import DownloadEngine

@Test
func artHTTPRedirectPolicyDoesNotRequestUnapprovedHosts() async throws {
    ArtRedirectStub.requests.withLock { $0 = [] }
    let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 3; config.protocolClasses = [ArtRedirectStub.self]
    let session = URLSession(configuration: config)
    let client = URLSessionHTTPClient(session: session, redirectPolicy: { $0.scheme == "https" && $0.host?.hasSuffix(".hoyoverse.com") == true })
    defer { client.invalidate() }
    let (head, _) = try await client.get(URL(string: "https://cdn.hoyoverse.com/redirect")!, byteRangeFrom: nil)
    #expect(head.status == 302)
    #expect(ArtRedirectStub.requests.withLock { $0 } == ["cdn.hoyoverse.com"])
}

private final class ArtRedirectStub: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[String]>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.requests.withLock { $0.append(url.host ?? "") }
        if url.path == "/redirect" {
            let target = URL(string: "https://evil.example/media")!
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { }
}
