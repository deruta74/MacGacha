// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine

/// A completed recovery that needs acknowledgment, independently of live sessions.
/// The session UUID is stable across replay, so a crash cannot duplicate a notice.
public struct RecoveryNotice: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let game: String
    public let movedTo: [URL]
    public let recoveryRoot: URL?

    public init(id: UUID, game: String, movedTo: [URL], recoveryRoot: URL? = nil) {
        self.id = id; self.game = game; self.movedTo = movedTo; self.recoveryRoot = recoveryRoot
    }
}

/// Synchronous contained I/O; callers run on BlockingIO. The independent lock
/// serializes acknowledgment and restore publication across actors and processes.
struct RecoveryNoticeStore: Sendable {
    let paths: AppPaths
    private let directory = try! SafeRelativePath("RecoveryNotices")

    func load() throws -> [RecoveryNotice] {
        try withOwnership { fs in
            try Recipes.games.flatMap { try read(game: $0, in: fs) }
        }
    }

    func record(_ notice: RecoveryNotice) throws {
        guard Recipes.games.contains(notice.game), valid(notice, game: notice.game) else {
            throw LauncherError.journalCorrupt("Invalid recovery notice")
        }
        try withOwnership { fs in
            var notices = try read(game: notice.game, in: fs)
            if let prior = notices.first(where: { $0.id == notice.id }) {
                guard prior == notice else { throw LauncherError.journalCorrupt("Recovery notice identity changed") }
                return
            }
            notices.append(notice)
            try write(notices, game: notice.game, in: fs)
        }
    }

    func acknowledge(id: UUID) throws {
        try withOwnership { fs in
            for game in Recipes.games {
                var notices = try read(game: game, in: fs)
                guard let notice = notices.first(where: { $0.id == id }) else { continue }
                // A live finalizer retains this lock even if unlink succeeded.
                // A fresh manager must not acknowledge ahead of its barrier.
                let sessionLock = try SessionLock.acquire(paths: paths, game: notice.game)
                defer { withExtendedLifetime(sessionLock) {} }
                // A crashed restore can replay its journal and publish again.
                // Acknowledge only after that durable source has been removed.
                guard try LaunchJournal(paths: paths).read(game: notice.game)?.sessionID != id else {
                    throw LauncherError.busy("Launch recovery is finishing")
                }
                // Absence alone is not durable deletion after a failed fsync.
                // On restart, establish the barrier again before acknowledgment.
                try fs.synchronizeAncestors(of: SafeRelativePath("Games/\(notice.game)/launch-session.json"))
                notices.removeAll { $0.id == id }
                try write(notices, game: game, in: fs)
                return
            }
        }
    }

    private func withOwnership<T>(_ body: (ContainedFileSystem) throws -> T) throws -> T {
        let fs = try ContainedFileSystem(root: paths.root)
        try fs.createRootDurably()
        try fs.createDirectoryDurably(at: directory)
        let lock = try InstallLock(fs: fs, path: SafeRelativePath("RecoveryNotices/.lock"))
        defer { withExtendedLifetime(lock) {} }
        return try body(fs)
    }

    private func read(game: String, in fs: ContainedFileSystem) throws -> [RecoveryNotice] {
        let path = try SafeRelativePath("RecoveryNotices/\(game).json")
        guard try fs.itemType(at: path) != nil else { return [] }
        do {
            let notices = try JSONDecoder().decode([RecoveryNotice].self, from: fs.readFile(at: path, maxBytes: 1 << 20))
            guard Set(notices.map(\.id)).count == notices.count,
                notices.allSatisfy({ valid($0, game: game) }) else {
                throw LauncherError.journalCorrupt("Invalid recovery notices")
            }
            return notices
        } catch { throw LauncherError.journalCorrupt("Invalid recovery notices") }
    }

    private func valid(_ notice: RecoveryNotice, game: String) -> Bool {
        guard notice.game == game, !notice.movedTo.isEmpty else { return false }
        let root = notice.recoveryRoot ?? paths.games.appendingPathComponent(game).appendingPathComponent("recovery")
            .appendingPathComponent(notice.id.uuidString)
        if let external = notice.recoveryRoot {
            let suffix = [".macgacha-recovery", game, notice.id.uuidString]
            guard external.isFileURL, external.pathComponents.suffix(3).elementsEqual(suffix),
                external.host == nil || external.host == "" || external.host == "localhost",
                !external.path.contains("\0"), external == external.standardizedFileURL else { return false }
        }
        let recovery = root.standardizedFileURL.path + "/"
        return notice.movedTo.allSatisfy {
            $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host == "localhost")
                && !$0.path.contains("\0") && $0.standardizedFileURL.path.hasPrefix(recovery)
        }
    }

    private func write(_ notices: [RecoveryNotice], game: String, in fs: ContainedFileSystem) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(notices)
        guard data.count <= 1 << 20 else { throw LauncherError.io("Recovery notices exceed size limit") }
        try fs.writeLaunchAtomically(data, to: SafeRelativePath("RecoveryNotices/\(game).json"))
    }
}
