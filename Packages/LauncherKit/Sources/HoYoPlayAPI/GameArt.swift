// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation

public struct GameArt: Sendable, Equatable, Codable {
    public let background: URL?
    public let video: URL?
    public let theme: URL?
    public let icon: URL?
    public let logo: URL?

    public init(background: URL? = nil, video: URL? = nil,
        theme: URL? = nil, icon: URL? = nil, logo: URL? = nil) {
        self.background = background; self.video = video
        self.theme = theme; self.icon = icon; self.logo = logo
    }
}
