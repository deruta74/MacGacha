// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import RuntimeManager

public protocol WinePrefixResetting: Sendable {
    func reset(game: String) async throws
}

public struct WinePrefixResetter: WinePrefixResetting {
    private let paths: AppPaths
    private let prefixes: PrefixManager
    private let log: EventLog
    private let beforeReset: @Sendable () throws -> Void
    public init(paths: AppPaths, inspector: any ProcessInspector = SystemProcessInspector(), wineServerRoot: URL? = nil, log: EventLog? = nil) {
        self.paths = paths
        self.beforeReset = {}
        self.prefixes = PrefixManager(paths: paths, runner: SystemProcessRunner(), inspector: inspector, wineServerRoot: wineServerRoot)
        self.log = log ?? EventLog(directory: paths.logs)
    }

    package init(paths: AppPaths, inspector: any ProcessInspector, beforeReset: @escaping @Sendable () throws -> Void) {
        self.paths = paths; self.beforeReset = beforeReset
        self.prefixes = PrefixManager(paths: paths, runner: SystemProcessRunner(), inspector: inspector)
        self.log = EventLog(directory: paths.logs)
    }

    public func reset(game: String) async throws {
        let count = try await BlockingIO.run {
            guard GameDefinition.find(game) != nil else { throw LauncherError.io("Unknown game edition") }
            let session = try SessionLock.acquire(paths: paths, game: game)
            defer { withExtendedLifetime(session) {} }
            try LaunchMutationBarrier.requireNoJournal(paths: paths, game: game)
            let components = try RuntimeStore(paths: paths).installed().map { "\($0.kind.idPrefix)-\($0.version)" }
            let pins = try RuntimePin.pin(paths: paths, componentIDs: components)
            defer { withExtendedLifetime(pins) {} }
            try LaunchMutationBarrier.requireNoJournal(paths: paths, game: game)
            try beforeReset()
            return try prefixes.resetPrefixes(game: game)
        }
        log.post(.info, "launch", "Wine prefixes reset", metadata: ["game": game, "count": String(count)])
    }
}
