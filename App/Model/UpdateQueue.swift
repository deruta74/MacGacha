// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import GameLibrary

/// A local, opt-in queue. Only plans started by the queue may resume unattended.
struct UpdateQueue: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        let id: String
        var paused = false
        var planID: String? = nil
        var pending: PendingOperation? = nil
        var source: GameRecord? = nil
        var automatic = false
    }
    var entries: [Entry] = []
    var enabled = true
    var scheduled = false
    var startMinute = 22 * 60
    var endMinute = 6 * 60
    var requiresAC = false
    var requiresIdle = false
    var idleMinutes = 5
    var automatic = false
    var automaticGames: Set<String> = []
    var lastDiscovery: Date? = nil

    func permits(at date: Date, calendar: Calendar = .current, onAC: Bool?) -> Bool {
        guard enabled, !requiresAC || onAC == true else { return false }
        guard scheduled else { return true }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        guard (0..<1440).contains(startMinute), (0..<1440).contains(endMinute), startMinute != endMinute else { return false }
        if startMinute < endMinute { return minute >= startMinute && minute < endMinute }
        return minute >= startMinute || minute < endMinute
    }
}
