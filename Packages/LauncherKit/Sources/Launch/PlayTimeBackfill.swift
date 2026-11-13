// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

/// Reads only the bounded current JSONL log. Rotation gaps deliberately lose
/// unmatched history. Ambiguous overlapping starts invalidate the entire pair.
enum PlayTimeBackfill {
    private enum Pending {
        case running(Date, String?)
        case overlapping
    }
    static func parse(_ data: Data, add: (String, String, Date, Double) -> Bool) -> Int {
        let decoder = JSONDecoder()
        let whole = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var pending: [String: Pending] = [:]
        var lastTimestamp: [String: Date] = [:]
        var count = 0
        for line in data.split(separator: 10) {
            guard line.count <= 64 << 10,
                let event = try? decoder.decode(EventLog.Record.self, from: Data(line)), event.category == "launch",
                let game = event.metadata["game"], GameDefinition.find(game) != nil,
                ["Game running", "Session ended"].contains(event.message) else { continue }
            guard let date = whole.date(from: event.ts) ?? fractional.date(from: event.ts) else {
                pending[game] = .overlapping
                continue
            }
            if let previous = lastTimestamp[game], date < previous {
                pending[game] = .overlapping
                continue
            }
            lastTimestamp[game] = date
            let id = event.metadata["sessionID"].flatMap(UUID.init(uuidString:))?.uuidString
            if event.message == "Game running" {
                pending[game] = pending[game] == nil ? .running(date, id) : .overlapping
            } else {
                defer { pending[game] = nil }
                guard case .running(let start, let startID) = pending[game], startID == id else { continue }
                let seconds = date.timeIntervalSince(start)
                guard seconds.isFinite, seconds > 0 else { continue }
                // Stable legacy identity also makes retries after uncertain writes safe.
                let key = id ?? "backfill-\(game)-\(start.timeIntervalSince1970)-\(date.timeIntervalSince1970)"
                if add(key, game, start, min(seconds, 86_400)) { count += 1 }
            }
        }
        return count
    }
}
