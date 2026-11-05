// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine

/// Metadata only. Archive downloads still use the existing verified installer.
public struct RuntimeCatalogFetcher: Sendable {
    public static let url = URL(string: "https://github.com/deruta74/MacGacha/releases/download/runtime-catalog-v1/runtime-catalog.json")!
    public static let byteLimit = 1 << 20
    private let client: any HTTPClient
    private let timeout: Duration
    public init(client: any HTTPClient, timeout: Duration = .seconds(20)) {
        self.client = client; self.timeout = timeout
    }
    public static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
            url.port == nil || url.port == 443, url.fragment == nil else { return false }
        switch url.host?.lowercased() {
        case "github.com": return url.path == Self.url.path
        case "release-assets.githubusercontent.com": return true
        default: return false
        }
    }
    public func fetch() async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await read() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw LauncherError.transport("Runtime catalog request timed out")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw LauncherError.cancelled }
            return result
        }
    }
    private func read() async throws -> Data {
        let (head, body) = try await client.get(Self.url, byteRangeFrom: nil)
        guard head.status == 200, head.contentLength.map({ $0 >= 0 && $0 <= Self.byteLimit }) ?? true else {
            throw LauncherError.transport("Runtime catalog response rejected")
        }
        var data = Data()
        for try await chunk in body {
            try Task.checkCancellation()
            guard chunk.count <= Self.byteLimit - data.count else { throw LauncherError.transport("Runtime catalog too large") }
            data.append(chunk)
        }
        if let length = head.contentLength, length != data.count { throw LauncherError.transport("Incomplete runtime catalog") }
        return data
    }
}
