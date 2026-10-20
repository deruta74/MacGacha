// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import HoYoPlayAPI

protocol GameArtProviding: Sendable {
    func cached() -> [String: GameArt]
    func loadCached() async -> [String: GameArt]
    func refresh() async -> [String: GameArt]
}

extension GameArtProviding {
    func loadCached() async -> [String: GameArt] { cached() }
}

extension GameArtService: GameArtProviding { }

struct EmptyGameArtProvider: GameArtProviding {
    func cached() -> [String: GameArt] { [:] }
    func refresh() async -> [String: GameArt] { [:] }
}
