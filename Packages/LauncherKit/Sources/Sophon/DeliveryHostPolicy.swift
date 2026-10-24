// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import DownloadEngine
import LauncherCore

public enum DeliveryHostPolicy {
    public static func allows(_ url: URL) -> Bool {
        allows(url, region: .global)
    }
    public static func allows(_ url: URL, region: Region) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased() else { return false }
        return region.deliveryDomains.contains {
            host == $0 || host.hasSuffix("." + $0)
        }
    }

    /// Create once and share with the delivery API and ChunkFetcher; invalidate when done.
    public static func makeHTTPClient(region: Region = .global, sessionCount: Int = 8) -> URLSessionHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        precondition(sessionCount > 0)
        configuration.httpMaximumConnectionsPerHost = SpaceBudget.defaultMaxConcurrentObjects
        return URLSessionHTTPClient(configuration: configuration, sessionCount: sessionCount,
            highWaterMark: 4 << 20, lowWaterMark: 1 << 20, redirectPolicy: { allows($0, region: region) })
    }
}

func deliveryURL(prefix: URL, id: String, suffix: String, region: Region = .global) throws -> URL {
    guard DeliveryHostPolicy.allows(prefix, region: region) else { throw LauncherError.io("untrusted delivery host") }
    // The wire suffix and existing percent encoding must survive byte for byte.
    guard !id.isEmpty, let url = URL(string: prefix.absoluteString + "/" + id + suffix, encodingInvalidCharacters: false),
          DeliveryHostPolicy.allows(url, region: region) else { throw LauncherError.io("invalid delivery URL") }
    return url
}
