// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
@testable import RuntimeManager

@Suite struct RuntimeCatalogFetcherTests {
    @Test func readsBoundedMetadataAndRejectsStatusOrOversize() async throws {
        let ok = CatalogHTTP(status: 200, chunks: [Data("abc".utf8), Data("def".utf8)])
        #expect(try await RuntimeCatalogFetcher(client: ok).fetch() == Data("abcdef".utf8))
        for client in [CatalogHTTP(status: 404, chunks: []),
            CatalogHTTP(status: 200, length: (1 << 20) + 1, chunks: []),
            CatalogHTTP(status: 200, chunks: [Data(repeating: 1, count: (1 << 20) + 1)])] {
            await #expect(throws: (any Error).self) { try await RuntimeCatalogFetcher(client: client).fetch() }
            #expect(client.cancelled.withLock { $0 })
        }
    }
    @Test func redirectPolicyRestrictsMetadataOrigin() throws {
        #expect(RuntimeCatalogFetcher.allows(RuntimeCatalogFetcher.url))
        #expect(RuntimeCatalogFetcher.allows(URL(string: "https://release-assets.githubusercontent.com/asset")!))
        for value in ["http://github.com/deruta74/MacGacha/releases/download/runtime-catalog-v1/runtime-catalog.json",
            "https://github.com/other/repository/releases/download/catalog.json",
            "https://github.com.evil.example/asset", "https://user@release-assets.githubusercontent.com/asset",
            "https://release-assets.githubusercontent.com:8443/asset"] {
            #expect(!RuntimeCatalogFetcher.allows(URL(string: value)!))
        }
    }
    @Test func stalledMetadataHitsDeadline() async throws {
        let client = CatalogHTTP(status: 200, chunks: [], stall: true)
        await #expect(throws: (any Error).self) {
            try await RuntimeCatalogFetcher(client: client, timeout: .milliseconds(20)).fetch()
        }
        #expect(client.cancelled.withLock { $0 })
    }
}
private final class CatalogHTTP: HTTPClient, Sendable {
    let status: Int
    let length: Int64?
    let chunks: Mutex<[Data]>
    let cancelled = Mutex(false)
    let stall: Bool
    init(status: Int, length: Int64? = nil, chunks: [Data], stall: Bool = false) {
        self.status = status; self.length = length; self.chunks = Mutex(chunks); self.stall = stall
    }
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        #expect(url == RuntimeCatalogFetcher.url && offset == nil)
        return (HTTPResponseHead(status: status, contentLength: length), HTTPBody(next: {
            if self.stall { try await Task.sleep(for: .seconds(60)) }
            return self.chunks.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        }, onCancel: { self.cancelled.withLock { $0 = true } }))
    }
    func post(_ url: URL) async throws -> (HTTPResponseHead, HTTPBody) { throw LauncherError.io("Unexpected POST") }
}

@Test func runtimeArchiveDestinationsAreRestricted() throws {
    for host in ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "codeberg.org"] {
        #expect(RuntimeArchivePolicy.allows(try #require(URL(string: "https://\(host)/asset"))))
    }
    for value in ["http://github.com/asset", "https://github.com:444/asset", "https://user@github.com/asset", "https://github.com/asset#fragment", "https://127.0.0.1/asset", "https://[::1]/asset", "https://example.com/asset", "https://github.com.evil.invalid/asset"] {
        #expect(!RuntimeArchivePolicy.allows(try #require(URL(string: value))))
    }
}
