// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

/// A validated, edition-region-bound Miliastra Sandbox archive descriptor.
public struct SandboxPackage: Sendable, Codable, Hashable {
    public let version: String
    public let url: URL
    public let md5: Digest
    public let size: Int64
    public let region: Region

    public init(version: String, url: URL, md5: Digest, size: Int64, region: Region = .global) throws {
        self.version = version; self.url = url; self.md5 = md5; self.size = size; self.region = region
        try validate()
    }

    public static func isValidVersion(_ version: String) -> Bool {
        let bytes = version.utf8
        return !bytes.isEmpty && bytes.count <= 64 && bytes.allSatisfy {
            $0 >= 48 && $0 <= 57 || $0 >= 65 && $0 <= 90 || $0 >= 97 && $0 <= 122 || $0 == 46 || $0 == 95 || $0 == 45
        }
    }

    func validate() throws {
        guard Self.isValidVersion(version), size > 0, size <= 4 << 30, md5.algorithm == .md5,
              DeliveryHostPolicy.allows(url, region: region), url.port == nil || url.port == 443,
              url.fragment == nil else { throw LauncherError.io("invalid sandbox package") }
    }

    private enum CodingKeys: String, CodingKey { case version, url, md5, size, region }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(version: c.decode(String.self, forKey: .version), url: c.decode(URL.self, forKey: .url),
            md5: c.decode(Digest.self, forKey: .md5), size: c.decode(Int64.self, forKey: .size),
            region: c.decodeIfPresent(Region.self, forKey: .region) ?? .global)
    }
}
