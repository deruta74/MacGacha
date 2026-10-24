// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Synchronization
import LauncherCore

/// Erases the instant type without replacing the injected monotonic clock.
struct AnyLaunchClock: Sendable {
    private let read: @Sendable () -> Duration
    private let wait: @Sendable (Duration) async throws -> Void

    init(_ clock: some Clock<Duration>) {
        let origin = clock.now
        read = { origin.duration(to: clock.now) }
        wait = { try await clock.sleep(for: $0) }
    }

    var now: Duration { read() }
    func sleep(for duration: Duration) async throws { try await wait(duration) }
}

enum SessionWatchError: Error { case startup }

/// An absent wineserver is never proof that a wrapper failed to start the game.
/// Once running, a completed wineserver wait and delayed process recheck together
/// establish session end; inspection errors propagate instead of guessing.
struct SessionWatcher: Sendable {
    private let inspector: any ProcessInspector
    private let runner: any ProcessRunner
    private let clock: AnyLaunchClock

    init(inspector: any ProcessInspector, runner: any ProcessRunner, clock: any Clock<Duration>) {
        self.inspector = inspector; self.runner = runner; self.clock = AnyLaunchClock(clock)
    }

    func watch(session: LaunchSession, executable: String, ownedWrapper: ProcessIdentity? = nil,
        ownedReaper: OwnedWrapperReaper? = nil, observed: @escaping @Sendable ([ProcessIdentity]) async throws -> Void) async throws {
        // Only a fresh spawn belongs to this process. Reattached processes
        // are not our children, so they are never waited on or signalled.
        let reaper = ownedReaper ?? ownedWrapper.map { OwnedWrapperReaper(identity: $0) }
        // The manager retains one reaper across uncertainty retries and starts
        // detached cleanup only after the entire supervision lifetime ends.
        defer { if ownedReaper == nil { reaper?.continueReaping(clock: clock) } }
        let gameName = Self.basename(executable)
        if session.state != .running {
            var absentSince: Duration?
            while true {
                try Task.checkCancellation()
                _ = try await reaper?.poll()
                let scan = try await inspect(session: session, gameName: gameName)
                if !scan.games.isEmpty {
                    try await observed(scan.games)
                    break
                }
                if !scan.wrapperAlive && !scan.serverAlive {
                    let beginning = absentSince ?? clock.now
                    absentSince = beginning
                    if clock.now - beginning >= .seconds(60) { throw SessionWatchError.startup }
                } else { absentSince = nil }
                try await clock.sleep(for: .seconds(1))
            }
        }
        while true {
            try Task.checkCancellation()
            _ = try await reaper?.poll()
            // ProcessRunner starts Process synchronously before its first
            // suspension. Keep slow executable/storage startup off cooperative
            // workers; BlockingIO forwards cancellation and joins the runner.
            let result = try await BlockingIO.run {
                try await runner.run(session.wineserver, arguments: ["-w"],
                    environment: ["WINEPREFIX": session.prefix.path, "WINEDEBUG": "-all"], currentDirectory: nil)
            }
            guard result.exitCode == 0 else {
                // Do not expose arbitrary wineserver stderr (paths/account data).
                throw LauncherError.processFailed(executable: "wineserver", exitCode: result.exitCode, stderrTail: "")
            }
            try await clock.sleep(for: .seconds(3))
            _ = try await reaper?.poll()
            let scan = try await inspect(session: session, gameName: gameName)
            try await observed(scan.games)
            if scan.games.isEmpty && !scan.serverAlive { return }
        }
    }

    private func inspect(session: LaunchSession, gameName: String) async throws
        -> (games: [ProcessIdentity], serverAlive: Bool, wrapperAlive: Bool) {
        try await BlockingIO.run {
            let processes = try inspector.processes(environmentContains: "WINEPREFIX", value: session.prefix.path)
            let games = processes.filter { Self.isGame($0, name: gameName) }.map(\.identity)
            let server = processes.contains { ["wineserver", "wineserver64"].contains(Self.basename($0.executablePath)) }
            let wrapper = session.processes.first.map { inspector.isAlive($0) } ?? false
            return (games, server, wrapper)
        }
    }

    private static func isGame(_ process: InspectedProcess, name: String) -> Bool {
        let executable = basename(process.executablePath)
        if executable == name { return true }
        // Wine's kernel executable is its Mach-O loader; its argv[0] can name
        // the Windows image. Never search arbitrary command arguments, which
        // could merely mention the game while belonging to a helper.
        let loaders = ["wine", "wine64", "wine-preloader", "wine64-preloader"]
        return loaders.contains(executable) && process.arguments.first.map { basename($0) == name } == true
    }

    private static func basename(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init)?.lowercased() ?? ""
    }
}

/// Owns only the direct wrapper handed off by our spawner. After it has been
/// reaped (or another owner already reaped it), its PID is permanently retired.
/// Reaping may outlive the game session if a compatibility wrapper lingers.
final class OwnedWrapperReaper: Sendable {
    private let identity: Mutex<ProcessIdentity?>
    private let wait: @Sendable (Int32) -> Bool

    init(identity: ProcessIdentity, wait: @escaping @Sendable (Int32) -> Bool = OwnedWrapperReaper.waitForExit) {
        self.identity = Mutex(identity); self.wait = wait
    }

    func poll() async throws -> Bool {
        try await BlockingIO.run {
            self.identity.withLock { identity in
                guard let current = identity else { return true }
                if self.wait(current.pid) { identity = nil }
                return identity == nil
            }
        }
    }

    func continueReaping(clock: AnyLaunchClock) {
        // Consumer cancellation must not strand a child zombie. A detached
        // cleanup task inherits neither the consumer's cancellation nor pipes.
        Task.detached {
            do {
                while try await !self.poll() { try await clock.sleep(for: .seconds(1)) }
            } catch { /* The detached reaper is never cancelled by session callers. */ }
        }
    }

    private static func waitForExit(_ pid: Int32) -> Bool {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { return true }
            if result == 0 { return false }
            if errno == EINTR { continue }
            return errno == ECHILD
        }
    }
}
