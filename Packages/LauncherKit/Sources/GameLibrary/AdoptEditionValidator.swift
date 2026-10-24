// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

/// Read-only, contained edition checks before adoption creates records or plans.
/// A version number alone cannot distinguish editions sharing the same image name.
enum AdoptEditionValidator {
    static func validate(_ game: GameDefinition, in fs: ContainedFileSystem) throws {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        var entries: [(String, String)] = []
        for name in ["config.ini", "game_version"] {
            let path = try SafeRelativePath(name)
            guard let type = try fs.itemType(at: path) else { continue }
            guard type == .regularFile else { throw LauncherError.unsafePath("Unsafe game metadata") }
            let data = try fs.readFile(at: path, maxBytes: 64 << 10)
            guard let text = String(data: data, encoding: .utf8) else { throw LauncherError.gameEditionUnknown }
            entries += try metadata(text)
        }
        let uapcEntries = entries.filter { $0.0 == "uapc" }.flatMap { uapcBusinesses($0.1).map { ("biz", $0) } }
        entries += uapcEntries
        for (key, value) in entries {
            if ["channel", "channel_id"].contains(key), value == "14" {
                throw LauncherError.gameDistributionUnsupported
            }
            // Bilibili builds use cps=bilibili, bilibili_PC and similar variants.
            if key == "cps", value.lowercased().hasPrefix("bilibili") { throw LauncherError.gameDistributionUnsupported }
            if ["game_biz", "biz"].contains(key), bilibiliBusinesses.contains(value) {
                throw LauncherError.gameDistributionUnsupported
            }
        }
        let executable = try SafeRelativePath(game.executableName)
        let present = try fs.itemType(at: executable) == .regularFile
        for other in Set(GameDefinition.all.map(\.executableName)) where other != game.executableName {
            if try fs.itemType(at: SafeRelativePath(other)) != nil { throw LauncherError.gameEditionMismatch }
        }
        guard present else { throw LauncherError.gameEditionUnknown }
        for (key, value) in entries where !value.isEmpty {
            let conflicts: Bool
            switch key {
            case "game_biz", "biz":
                conflicts = GameDefinition.all.contains { $0.biz == value && $0.id != game.id }
            case "game_id":
                conflicts = GameDefinition.all.contains { $0.gameID == value && $0.id != game.id }
            case "launcher_id":
                conflicts = Region.allCases.contains { $0.launcherID == value && $0 != game.region }
            default: continue
            }
            if conflicts { throw LauncherError.gameEditionMismatch }
        }
        // Sophon installs need not have launcher metadata. With no positive conflict,
        // accept the selected edition; normal Sophon verification still checks its files.
        // No reliable region-specific manifest sample is currently known for shared images.
    }

    private static let bilibiliBusinesses = Set(GameDefinition.all.map {
        String($0.biz.split(separator: "_")[0]) + "_bilibili"
    })

    private static func uapcBusinesses(_ text: String) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [] }
        // HoYoPlay's uapc is a map keyed by business ID. Device IDs and arbitrary
        // string contents aren't edition evidence; only known, exact map keys count.
        return Set(GameDefinition.all.map(\.biz)).union(bilibiliBusinesses).filter { object[$0] is [String: Any] }
    }

    private static func metadata(_ text: String) throws -> [(String, String)] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
        if text.first == "{" {
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw LauncherError.gameEditionUnknown
            }
            func fields(_ object: [String: Any], depth: Int) -> [(String, String)] {
                guard depth <= 4 else { return [] }
                return object.flatMap { key, value -> [(String, String)] in
                    if key.lowercased() == "uapc", let nested = value as? [String: Any],
                        let data = try? JSONSerialization.data(withJSONObject: nested),
                        let text = String(data: data, encoding: .utf8) { return [("uapc", text)] }
                    if let nested = value as? [String: Any] { return fields(nested, depth: depth + 1) }
                    if let value = value as? String { return [(key.lowercased(), value)] }
                    if let value = value as? NSNumber { return [(key.lowercased(), value.stringValue)] }
                    return []
                }
            }
            return fields(object, depth: 0)
        }
        return text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") { return nil }
            guard !line.hasPrefix(";"), !line.hasPrefix("#"),
                let separator = line.firstIndex(of: "=") else { return nil }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            return (key, value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
        }
    }
}
