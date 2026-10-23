// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation

/// Plain log locations shared by recipe data and diagnostics callers. All enumeration
/// is blocking I/O: async callers use BlockingIO.run. Recovery metadata is not a log.
public enum LaunchLogFiles {
    public static let games = ["genshin", "starrail", "zzz"]
    public static func gameLogPaths(for game: String) -> [SafeRelativePath] {
        let products = ["genshin": "Genshin Impact", "starrail": "Star Rail", "zzz": "ZenlessZoneZero"]
        guard let product = products[game] else { return [] }
        return ["miHoYo", "Cognosphere"].flatMap { company in
            ["Player.log", "output_log.txt"].map { try! SafeRelativePath("AppData/LocalLow/\(company)/\(product)/\($0)") }
        }
    }

    public static func latestSessionLogURLs(in directory: URL) throws -> [URL] {
        let parent = try ContainedFileSystem(root: directory.deletingLastPathComponent())
        guard try parent.itemType(at: SafeRelativePath(directory.lastPathComponent)) == .directory else { return [] }
        let fs = try ContainedFileSystem(root: directory)
        var newest: [String: String] = [:]
        for path in try fs.contentsOfRootDirectory() {
            let name = path.description
            guard let parsed = parseName(name), games.contains(parsed.game),
                try fs.itemType(at: path, allowingLeafSymlink: true) == .regularFile else { continue }
            if newest[parsed.game].map({ precedes(name, $0) }) ?? true { newest[parsed.game] = name }
        }
        return newest.keys.sorted().map { directory.appendingPathComponent(newest[$0]!) }
    }

    /// Candidate paths stay relative to a single trusted prefix root. Callers pass
    /// these plain paths into Diagnostics; the exporter never imports recipes.
    public static func gameLogCandidates(in prefixes: URL) throws -> [String: [SafeRelativePath]] {
        let parent = try ContainedFileSystem(root: prefixes.deletingLastPathComponent())
        guard try parent.itemType(at: SafeRelativePath(prefixes.lastPathComponent)) == .directory else { return [:] }
        let fs = try ContainedFileSystem(root: prefixes)
        let roots = try fs.contentsOfRootDirectory()
        var result: [String: [SafeRelativePath]] = [:]
        for game in games {
            for root in roots.filter({ $0.description.hasPrefix(game + "-") }).prefix(128) {
                guard try fs.itemType(at: root, allowingLeafSymlink: true) == .directory else { continue }
                let users = try SafeRelativePath("\(root)/drive_c/users")
                guard (try? fs.itemType(at: users, allowingLeafSymlink: true)) == .directory else { continue }
                for user in try fs.contentsOfDirectory(at: users).prefix(32) {
                    guard try fs.itemType(at: user, allowingLeafSymlink: true) == .directory else { continue }
                    for path in gameLogPaths(for: game) {
                        result[game, default: []].append(try SafeRelativePath("\(user)/\(path)"))
                    }
                }
            }
        }
        return result
    }

    public static func parseName(_ name: String) -> (game: String, stamp: String, ordinal: String)? {
        guard name.hasSuffix(".log") else { return nil }
        var parts = name.dropLast(4).split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        var ordinal = "1"
        if let last = parts.last, last.count != 6 || parts.count >= 3 && parts[parts.count - 2].count == 6 {
            guard last.first != "0", last != "1", !last.isEmpty, last.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            ordinal = parts.removeLast()
        }
        guard parts.count >= 3 else { return nil }
        let time = parts.removeLast(), date = parts.removeLast(), game = parts.joined(separator: "-")
        guard time.utf8.count == 6, date.utf8.count == 8, (date + time).utf8.allSatisfy({ (48...57).contains($0) }), (try? SafeIdentifier(game)) != nil else { return nil }
        return (game, date + "-" + time, ordinal)
    }
    public static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        guard let l = parseName(lhs), let r = parseName(rhs) else { return lhs < rhs }
        if l.stamp != r.stamp { return l.stamp > r.stamp }
        if l.ordinal.count != r.ordinal.count { return l.ordinal.count > r.ordinal.count }
        return l.ordinal > r.ordinal
    }
}
