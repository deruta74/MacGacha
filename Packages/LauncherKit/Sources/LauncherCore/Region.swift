// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation

/// Public launcher endpoints and trust boundaries for one edition of the games.
public enum Region: String, Sendable, Codable, CaseIterable {
    case global, mainlandChina

    public var hypAPIHost: String {
        switch self {
        case .global: "sg-hyp-api.hoyoverse.com"
        case .mainlandChina: "hyp-api.mihoyo.com"
        }
    }
    public var launcherID: String {
        switch self {
        case .global: "VYTpXlbWo8"
        case .mainlandChina: "jGHBHlcOq1"
        }
    }
    public var sophonBuildHost: String {
        switch self {
        case .global: "sg-public-api.hoyoverse.com"
        case .mainlandChina: "downloader-api.mihoyo.com"
        }
    }
    /// Exact domains and their subdomains. yuanshen.com serves both editions.
    public var deliveryDomains: [String] {
        switch self {
        case .global: ["hoyoverse.com", "yuanshen.com", "starrails.com", "zenlesszonezero.com"]
        case .mainlandChina: ["mihoyo.com", "yuanshen.com", "bhsr.com", "juequling.com"]
        }
    }
    /// Global art uses *.hoyoverse.com; CN art uses these two exact CDN hosts.
    public var artDomains: [String] {
        switch self {
        case .global: ["hoyoverse.com"]
        case .mainlandChina: ["launcher-webstatic.mihoyo.com", "fastcdn.mihoyo.com"]
        }
    }
    public func hypAPIURL(_ endpoint: String) -> URL {
        var components = URLComponents(string: "https://\(hypAPIHost)/hyp/hyp-connect/api/")!
        components.path += endpoint
        components.queryItems = [URLQueryItem(name: "launcher_id", value: launcherID)]
        return components.url!
    }
    public var sophonBuildURL: URL { URL(string: "https://\(sophonBuildHost)/downloader/sophon_chunk/api/getBuild")! }
}
