// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Dispatch
import Foundation
import Synchronization
import LauncherCore

/// Blocking file I/O: call these synchronous entry points from BlockingIO.run
/// or a dedicated Dispatch queue, like the proxy's host-only logging callback.
/// Struct copies share their append lock and truncation state.
public struct SessionLog: Sendable {
    public let url: URL
    /// Spawn through this descriptor, never by reopening url. Retain the log
    /// through finish() so its supervisor remains alive for the session.
    public var processOutput: ProcessOutput { .ownedFile(ProcessOutputFile(file: storage.file)) }
    private let storage: Storage
    private final class Storage: Sendable {
        struct State { var truncated = false; var finished = false }
        let fs: ContainedFileSystem, path: SafeRelativePath, file: ContainedFileSystem.OwnedRegularFile, limit: Int64
        let state = Mutex(State())
        let timer = Mutex<LogTickCancellation?>(nil)
        init(fs: ContainedFileSystem, path: SafeRelativePath, file: ContainedFileSystem.OwnedRegularFile, limit: Int64) {
            self.fs = fs; self.path = path; self.file = file; self.limit = limit
        }
        func start(_ ticker: any SessionLogTicker) {
            let cancellation = ticker.start { [weak self] in self?.tick() }
            timer.withLock { $0 = cancellation }
        }
        func tick() {
            state.withLock { state in
                guard !state.finished else { return }
                do { if try file.size() >= limit { try file.cap(bytes: limit, marker: SessionLog.marker); state.truncated = true } }
                catch { /* Retry on the next tick or stale-session recovery. */ }
            }
        }
        deinit {
            timer.withLock { $0?.cancel() }
            let file = file, limit = limit
            DispatchQueue.global(qos: .utility).async { try? file.cap(bytes: limit, marker: SessionLog.marker) }
        }
    }
    private struct Ownership: Codable {
        let schema: Int
        let path: SafeRelativePath
        let identity: ContainedFileSystem.OwnedFileIdentity
        let sidecarIdentity: ContainedFileSystem.OwnedFileIdentity
        let limit: Int64
    }
    package static let headerKeys = ["recipe", "recipeVersion", "gameBuild", "buildVerification", "backend", "runtimeBundle", "runtimeDigest", "componentIDs", "settings", "dateTime", "macOSVersion", "macGachaVersion"]
    private static let marker = Data("\n[log truncated]\n".utf8)

    /// A caller snapshots the global preference once per launch. Disabled logging
    /// creates no directory or file and leaves existing logs and recovery untouched.
    public static func create(paths: AppPaths, game: String, header: [String: String], sessionLogsEnabled: Bool) throws -> SessionLog? {
        guard sessionLogsEnabled else { return nil }
        return try create(paths: paths, game: game, header: header)
    }

    public static func create(paths: AppPaths, game: String, header: [String: String]) throws -> SessionLog {
        try create(paths: paths, game: game, header: header, now: Date(), timeZone: .current, maxBytes: 64 << 20)
    }
    package static func create(paths: AppPaths, game: String, header: [String: String], now: Date, timeZone: TimeZone, maxBytes: Int,
        ticker: any SessionLogTicker = SystemSessionLogTicker(), fileOps: any FileOps = SystemFileOps(),
        beforeRetention: @Sendable (SafeRelativePath) -> Void = { _ in }) throws -> SessionLog {
        _ = try SafeIdentifier(game)
        guard now.timeIntervalSince1970.isFinite, maxBytes >= marker.count else { throw LauncherError.io("Invalid session log configuration") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone; formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = "\(game)-\(formatter.string(from: now))"
        let unpinned = try ContainedFileSystem(root: paths.logs, fileOps: fileOps)
        try unpinned.createRootDurably()
        let fs = try unpinned.pinRoot()
        // Retention may have removed the unsuffixed name. Keep ordinals
        // increasing within this second instead of reusing that older name.
        let sameSecond = try fs.contentsOfRootDirectory().compactMap { parseName($0.description) }.filter { $0.game == game && $0.stamp == formatter.string(from: now) }
        var ordinal = sameSecond.map { min(Int($0.ordinal) ?? 100_000, 100_000) }.max().map { $0 + 1 } ?? 1
        guard ordinal <= 100_000 else { throw LauncherError.io("Too many session log collisions") }
        var path: SafeRelativePath
        var created: ContainedFileSystem.OwnedRegularFile?
        while created == nil {
            path = try SafeRelativePath(stem + (ordinal == 1 ? "" : "-\(ordinal)") + ".log")
            if try fs.itemType(at: sidecar(path), allowingLeafSymlink: true) == nil, let file = try fs.createOwnedFile(at: path) {
                if let recordFile = try fs.createOwnedFile(at: sidecar(path)) {
                    let record = Ownership(schema: 1, path: path, identity: file.identity, sidecarIdentity: recordFile.identity, limit: Int64(maxBytes))
                    _ = try recordFile.append(JSONEncoder().encode(record)); try recordFile.fullSync()
                    created = file
                    break
                }
                _ = try file.removeIfNamed()
            }
            guard ordinal < 100_000 else { throw LauncherError.io("Too many session log collisions") }
            ordinal += 1
        }
        path = try SafeRelativePath(stem + (ordinal == 1 ? "" : "-\(ordinal)") + ".log")
        guard let file = created else { throw LauncherError.io("Cannot create session log") }
        let log = SessionLog(url: path.resolved(against: paths.logs), storage: Storage(fs: fs, path: path, file: file, limit: Int64(maxBytes)))
        var fields = header
        let recipe = Recipes.recipe(for: game)
        fields["recipe"] = header["recipe"] ?? game
        fields["recipeVersion"] = header["recipeVersion"] ?? recipe.map { String($0.recipeVersion) } ?? "unknown"
        let verified = recipe?.verifiedBuilds.contains(header["gameBuild"] ?? "") == true && fields["recipeVersion"] == recipe.map { String($0.recipeVersion) }
        fields["buildVerification"] = verified ? "verified build" : "unverified build"
        let timestamp = ISO8601DateFormatter(); timestamp.timeZone = timeZone
        fields["dateTime"] = timestamp.string(from: now)
        fields["macOSVersion"] = header["macOSVersion"] ?? ProcessInfo.processInfo.operatingSystemVersionString
        fields["macGachaVersion"] = header["macGachaVersion"] ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let text = headerKeys.map { key in
            let value = Redactor.redactLog(fields[key] ?? "unknown").replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
            return "\(key): \(value)\n"
        }.joined()
        _ = try file.append(Data(text.utf8)); try file.fullSync()
        log.enforceCap()
        let owned = try matchingLogs(fs: fs, game: game).filter { $0 != path }
        for obsolete in owned.dropFirst(9) {
            guard let record = try readOwnership(fs, obsolete) else { continue }
            beforeRetention(obsolete)
            if try fs.removeOwnedFile(at: obsolete, matching: record.identity) {
                _ = try fs.removeOwnedFile(at: sidecar(obsolete), matching: record.sidecarIdentity)
            }
        }
        // Wine retains an independent O_APPEND fd and survives our exit. While
        // supervised, residual growth is output rate × the elapsed tick interval
        // (5 s nominal). With no running launcher, no ticker bounds that growth.
        // A final cap is also applied by finish() and stale-session recovery.
        log.storage.start(ticker)
        return log
    }

    public func append(line: String) {
        storage.state.withLock { state in
            guard !state.truncated, !state.finished else { return }
            do {
                if try storage.file.size() < storage.limit {
                    let oneLine = line.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n") + "\n"
                    if try storage.file.append(Data(oneLine.utf8)) < storage.limit { return }
                }
                try storage.file.cap(bytes: storage.limit, marker: Self.marker)
                state.truncated = true
            } catch { state.truncated = true }
        }
    }
    public func enforceCap() { storage.tick() }

    /// Blocking final cap; call when the session ends, before releasing its log.
    public func finish() {
        storage.timer.withLock { $0?.cancel(); $0 = nil }
        storage.state.withLock { state in
            try? storage.file.cap(bytes: storage.limit, marker: Self.marker)
            state.finished = true
        }
    }

    /// Recovery never adopts a pathname alone. A missing/mismatched sidecar or
    /// replaced inode is left untouched; a verified stale log is capped once.
    public static func recover(at url: URL) throws -> SessionLog? {
        try recover(at: url, ticker: SystemSessionLogTicker())
    }
    package static func recover(at url: URL, ticker: any SessionLogTicker) throws -> SessionLog? {
        guard LaunchLogFiles.parseName(url.lastPathComponent) != nil else { return nil }
        let fs = try ContainedFileSystem(root: url.deletingLastPathComponent()).pinRoot()
        let path = try SafeRelativePath(url.lastPathComponent)
        guard let record = try readOwnership(fs, path), let file = try fs.openOwnedFile(at: path, matching: record.identity) else { return nil }
        let log = SessionLog(url: url, storage: Storage(fs: fs, path: path, file: file, limit: record.limit))
        log.enforceCap()
        log.storage.start(ticker)
        return log
    }

    private static func sidecar(_ path: SafeRelativePath) throws -> SafeRelativePath { try SafeRelativePath(path.description + ".macgacha-owner.json") }
    private static func readOwnership(_ fs: ContainedFileSystem, _ path: SafeRelativePath) throws -> Ownership? {
        do {
            return try fs.withClaimedFile(at: sidecar(path), maximumBytes: 8192) { claim in
                let record = try JSONDecoder().decode(Ownership.self, from: claim.readData(maxBytes: 8192))
                guard record.schema == 1, record.path == path, record.limit >= marker.count,
                    record.sidecarIdentity == (try claim.ownedIdentity()) else { return nil }
                return record
            }
        } catch { if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }; return nil }
    }
    package static func matchingLogs(fs: ContainedFileSystem, game: String) throws -> [SafeRelativePath] {
        try fs.contentsOfRootDirectory().filter {
            guard parseName($0.description)?.game == game, let record = try readOwnership(fs, $0) else { return false }
            return try fs.openOwnedFile(at: $0, matching: record.identity) != nil
        }.sorted { precedes($0.description, $1.description) }
    }
    package static func parseName(_ name: String) -> (game: String, stamp: String, ordinal: String)? {
        LaunchLogFiles.parseName(name)
    }
    package static func precedes(_ lhs: String, _ rhs: String) -> Bool { LaunchLogFiles.precedes(lhs, rhs) }
}
