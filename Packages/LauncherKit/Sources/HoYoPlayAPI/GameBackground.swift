// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation

/// The service supplies validated local cache assets; browser links have a separate HTTPS-only policy.
public struct GameBackground: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let image: URL?
    public let video: URL?
    public let theme: URL?
    public let highlights: GameHighlights?

    public init(id: String, image: URL?, video: URL? = nil, theme: URL? = nil, highlights: GameHighlights? = nil) {
        self.id = id; self.image = image; self.video = video; self.theme = theme; self.highlights = highlights
    }
}

public struct GameHighlights: Sendable, Equatable, Codable {
    public let image: URL
    public let hoverImage: URL?
    public let link: URL?

    public init(image: URL, hoverImage: URL? = nil, link: URL? = nil) {
        self.image = image; self.hoverImage = hoverImage
        self.link = link.flatMap { Self.browserLink($0) }
    }

    private enum CodingKeys: String, CodingKey { case image, hoverImage, link }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(image: try c.decode(URL.self, forKey: .image),
            hoverImage: try c.decodeIfPresent(URL.self, forKey: .hoverImage),
            link: try c.decodeIfPresent(URL.self, forKey: .link))
    }

    static func browserLink(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
            url.user == nil, url.password == nil, url.absoluteString.utf8.count <= 8192 else { return nil }
        return url
    }
}
