// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

/// HoYoverse games write `driverError.log` beside their executable when the
/// anti-cheat driver fails to start. Under Wine the driver normally is never
/// loaded; the game falls back to it when it can't reach its servers at
/// startup, for example on a network that blocks HoYoverse domains.
enum AntiCheatDriverError {
    static let path = try! SafeRelativePath("driverError.log")
    static let maxBytes = 16_384
    /// The game's own clock and ours can disagree by a moment.
    static let tolerance: TimeInterval = 2

    /// True only for an `initDriver Failed` entry stamped during this session.
    /// Every read failure means "no evidence".
    static func occurred(installRoot: URL, identity: FileSystemIdentity, since start: Date) -> Bool {
        guard let fs = try? ContainedFileSystem(root: installRoot, expectedRootIdentity: identity).pinRoot(),
              let data = try? fs.readFile(at: path, maxBytes: maxBytes) else { return false }
        return matches(String(decoding: data, as: UTF8.self), since: start)
    }

    static func matches(_ text: String, since start: Date) -> Bool {
        guard text.contains("initDriver Failed") else { return false }
        // A stale log from an earlier launch must not explain this one.
        guard let stamp = utcStamp(in: text) else { return false }
        return stamp >= start.addingTimeInterval(-tolerance)
    }

    private static func utcStamp(in text: String) -> Date? {
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("[UTC_Time]") }) else { return nil }
        let value = line.dropFirst("[UTC_Time]".count).trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.date(from: value)
    }
}
