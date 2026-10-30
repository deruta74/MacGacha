// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import HoYoPlayAPI

protocol GameEventsProviding: Sendable {
    func cached() -> [String: GameEventsSnapshot]
    func loadCached() async -> [String: GameEventsSnapshot]
    func refresh() async -> [String: GameEventsSnapshot]
}

extension GameEventsService: GameEventsProviding { }

struct EmptyGameEventsProvider: GameEventsProviding {
    func cached() -> [String: GameEventsSnapshot] { [:] }
    func loadCached() async -> [String: GameEventsSnapshot] { [:] }
    func refresh() async -> [String: GameEventsSnapshot] { [:] }
}
