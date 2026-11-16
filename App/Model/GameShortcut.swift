// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import LauncherCore
import RuntimeManager

/// A per-game app in ~/Applications that starts the game through MacGacha without
/// showing the launcher. The bundle holds only a shell script, a plist and an icon:
/// files created on this Mac carry no quarantine, so no signature is needed to run it.
enum GameShortcut {
    static let scheme = "macgacha"
    /// Passed only when the shortcut launches MacGacha. A running MacGacha ignores it.
    static let launchArgument = "--macgacha-shortcut"
    static let bundlePrefix = "com.lo7ted.macgacha.shortcut."
    static let gameIDKey = "MacGachaGameID"

    static func playURL(_ id: String) -> URL? { URL(string: "\(scheme)://play/\(id)") }

    /// Only `macgacha://play/<known game ID>` is accepted. Anything else is ignored.
    static func gameID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host()?.lowercased() == "play", url.query() == nil, url.fragment() == nil
        else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 1, let game = GameDefinition.find(parts[0]) else { return nil }
        return game.id
    }

    /// Finder shows a POSIX colon as a slash, so "Honkai: Star Rail" becomes "Honkai Star Rail".
    static func appName(for name: String) -> String {
        let cleaned = name.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "/", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return cleaned.isEmpty ? "MacGacha Game" : cleaned
    }

    /// MacGacha is activated (no `-g`), so it can hand focus to the game it starts.
    /// Opens the exact MacGacha that made the shortcut, so an older copy elsewhere can't take
    /// the request. If that copy was moved or deleted, any MacGacha with the bundle ID is used.
    static func script(gameID: String, hostBundleID: String, hostPath: String) -> String {
        let path = hostPath.replacingOccurrences(of: "'", with: "'\\''")
        return """
        #!/bin/sh
        # Created by MacGacha. Starts this game through MacGacha without opening its window.
        # Delete this app to remove the shortcut.
        url='macgacha://play/\(gameID)'
        if [ -d '\(path)' ]; then
            exec /usr/bin/open -a '\(path)' "$url" --args \(launchArgument)
        fi
        exec /usr/bin/open -b '\(hostBundleID)' "$url" --args \(launchArgument)

        """
    }

    static func infoPlist(gameID: String, name: String, hasIcon: Bool) throws -> Data {
        var plist: [String: Any] = [
            "CFBundleExecutable": "launch", "CFBundleIdentifier": bundlePrefix + gameID,
            "CFBundleName": name, "CFBundleDisplayName": name, "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1", "CFBundleInfoDictionaryVersion": "6.0",
            "LSUIElement": true, gameIDKey: gameID,
        ]
        if hasIcon { plist["CFBundleIconFile"] = "AppIcon" }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// Writes `<name>.app` into `directory` through a temporary sibling and returns its URL.
    /// An earlier shortcut for the same game is replaced. Another app with that name is
    /// never touched: the shortcut then gets a "(MacGacha)" suffix. Call on BlockingIO.
    static func write(gameID: String, name: String, icns: Data?, hostBundleID: String, hostPath: String, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fs = try ContainedFileSystem(root: directory)
        let base = appName(for: name)
        var destination = try SafeRelativePath("\(base).app")
        if try fs.itemType(at: destination) != nil, try !isShortcut(destination, gameID: gameID, fs: fs) {
            destination = try SafeRelativePath("\(base) (MacGacha).app")
            if try fs.itemType(at: destination) != nil, try !isShortcut(destination, gameID: gameID, fs: fs) {
                throw LauncherError.busy("Shortcut name in use")
            }
        }
        let temporary = try SafeRelativePath(".\(base).macgacha-shortcut-\(UUID().uuidString)")
        do {
            try fs.createDirectory(at: SafeRelativePath("\(temporary)/Contents/MacOS"))
            try fs.writeAtomically(infoPlist(gameID: gameID, name: base, hasIcon: icns != nil),
                to: SafeRelativePath("\(temporary)/Contents/Info.plist"))
            if let icns {
                try fs.createDirectory(at: SafeRelativePath("\(temporary)/Contents/Resources"))
                try fs.writeAtomically(icns, to: SafeRelativePath("\(temporary)/Contents/Resources/AppIcon.icns"))
            }
            let executable = try fs.openForWriting(at: SafeRelativePath("\(temporary)/Contents/MacOS/launch"), truncate: true)
            defer { try? executable.close() }
            try executable.write(contentsOf: Data(script(gameID: gameID, hostBundleID: hostBundleID, hostPath: hostPath).utf8))
            guard fchmod(executable.fileDescriptor, 0o755) == 0 else { throw LauncherError.io("Cannot make the shortcut executable") }
            // Swapped in atomically. An earlier shortcut ends up at the temporary name and is removed.
            if try fs.publishDirectory(at: temporary, to: destination) { try? fs.removeItem(at: temporary) }
        } catch {
            try? fs.removeItem(at: temporary)
            throw error
        }
        return destination.resolved(against: directory)
    }

    /// Our earlier shortcut for this game, recognized by its bundle identifier.
    private static func isShortcut(_ app: SafeRelativePath, gameID: String, fs: ContainedFileSystem) throws -> Bool {
        guard let data = try? fs.readFile(at: SafeRelativePath("\(app)/Contents/Info.plist"), maxBytes: 64 << 10),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return plist["CFBundleIdentifier"] as? String == bundlePrefix + gameID
    }
}

protocol GameShortcutWriting: Sendable {
    func write(gameID: String, name: String) async throws -> URL
}

struct LiveGameShortcutWriter: GameShortcutWriting {
    let directory: URL
    let hostBundleID: String
    let hostPath: String
    let icons: any GameModeIconProviding

    func write(gameID: String, name: String) async throws -> URL {
        guard let game = GameDefinition.find(gameID) else { throw LauncherError.io("Unknown game") }
        // The cached HoYoPlay icon, or MacGacha's own icon when none is cached yet.
        let icns = try? await icons.icon(for: game).icns
        let directory = directory, host = hostBundleID, path = hostPath
        return try await BlockingIO.run {
            try GameShortcut.write(gameID: gameID, name: name, icns: icns, hostBundleID: host, hostPath: path, in: directory)
        }
    }
}

struct UnavailableGameShortcutWriter: GameShortcutWriting {
    func write(gameID: String, name: String) async throws -> URL { throw LauncherError.io("Shortcuts unavailable") }
}
