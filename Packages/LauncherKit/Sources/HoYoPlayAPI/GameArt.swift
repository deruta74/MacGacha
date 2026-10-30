// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation

public struct GameArt: Sendable, Equatable, Codable {
    public let backgrounds: [GameBackground]
    public let background: URL?
    public let video: URL?
    public let theme: URL?
    public let icon: URL?
    public let logo: URL?

    public init(background: URL? = nil, video: URL? = nil,
        theme: URL? = nil, icon: URL? = nil, logo: URL? = nil, backgrounds: [GameBackground] = []) {
        self.backgrounds = backgrounds
        self.background = background; self.video = video
        self.theme = theme; self.icon = icon; self.logo = logo
    }

    private enum CodingKeys: String, CodingKey { case backgrounds, background, video, theme, icon, logo }

    // Values encoded before background lists existed decode with an empty list.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(background: try container.decodeIfPresent(URL.self, forKey: .background),
            video: try container.decodeIfPresent(URL.self, forKey: .video),
            theme: try container.decodeIfPresent(URL.self, forKey: .theme),
            icon: try container.decodeIfPresent(URL.self, forKey: .icon),
            logo: try container.decodeIfPresent(URL.self, forKey: .logo),
            backgrounds: try container.decodeIfPresent([GameBackground].self, forKey: .backgrounds) ?? [])
    }
}
