// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import RuntimeManager
import Launch

/// Setup only extracts runtime/game files; it must return before any prefix or
/// launch starts. A partial setup can therefore be removed without running Wine.
/// Once setup returns, cleanup must use the verified prefix shutdown path.
package func withProbeTestRoot(root: URL,
    setup: @Sendable (URL) async throws -> ProbeLaunchConfiguration,
    operation: @Sendable (ProbeLaunchConfiguration) async throws -> Void) async throws {
    let fs = try await BlockingIO.run {
        let fs = try ContainedFileSystem(root: root)
        try fs.createRootDurably()
        return try fs.pinRoot()
    }
    var configuration: ProbeLaunchConfiguration?
    var failure: (any Error)?
    do {
        let installed = try await setup(root)
        configuration = installed
        try Task.checkCancellation()
        try await operation(installed)
    } catch { failure = error }
    do {
        if let configuration {
            try await configuration.cleanup(clock: ContinuousClock())
        } else {
            try await Task.detached {
                try await BlockingIO.run {
                    // Fail closed if setup ever changes to start a prefix.
                    guard try fs.itemType(at: SafeRelativePath("store/Prefixes")) == nil else {
                        throw LauncherError.io("Partial probe setup created prefixes; root retained at \(root.path)")
                    }
                    try fs.removePinnedRoot(onlyIfEmpty: false)
                }
            }.value
        }
    } catch {
        throw LauncherError.io("Probe cleanup failed; root retained at \(root.path): \(error); initial failure: \(String(describing: failure))")
    }
    if let failure { throw failure }
}

/// Manager supervision runs only in this killable child. Its process runner's
/// deadline joins termination and pipe drainage, even if supervision never ends.
package struct ProbeHarnessChild: Sendable {
    private let worker: Task<ProcessResult, any Error>
    private let finished: TestEvent
    private let label: String
    package init(executable: URL, arguments: [String], root: URL, label: String = "probe child", runner: any ProcessRunner = SystemProcessRunner(),
        timeout: Duration = .seconds(240), timeoutWait: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        let finished = TestEvent()
        self.finished = finished
        self.label = label
        worker = Task {
            defer { finished.signal() }
            return try await BlockingIO.run {
                try await runner.run(executable, arguments: arguments, environment: ProcessInfo.processInfo.environment,
                    currentDirectory: root, timeout: timeout, timeoutWait: timeoutWait)
            }
        }
    }
    /// Do not wait for a file from a child that has already failed or exited.
    /// Cancelling this observation detaches its waiters; the lifetime owner joins the child.
    package func waitUntilReady(step: String = "probe readiness", timeout: Duration = .seconds(180),
        timeoutWait: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        _ ready: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await ready() }
            group.addTask {
                try await timeoutWait(timeout)
                throw LauncherError.io("Probe handshake timed out after \(timeout): \(label) / \(step)")
            }
            group.addTask {
                try await finished.wait()
                let result = try await worker.value
                throw LauncherError.io("Probe child exited waiting for \(label) / \(step) (status \(result.exitCode)): \(String(decoding: result.stderr.suffix(4096), as: UTF8.self))")
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }
    package func result() async throws -> ProcessResult {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await worker.value
        } onCancel: { worker.cancel() }
    }
    package func stop() async {
        worker.cancel()
        // Join the bounded runner even when the caller is already cancelled.
        let worker = worker
        await Task.detached { _ = await worker.result }.value
    }
}

extension ProbeLaunchConfiguration {
    package var prefix: URL {
        get throws { try PrefixManager(paths: paths, runner: SystemProcessRunner()).prefixURL(game: "starrail", bundle: bundleID) }
    }

    /// No destructor removes this root. A failed shutdown or uncertain scan must
    /// retain the prefix and report failure, rather than erase a surviving Wine's files.
    package func cleanup<C: Clock<Duration>>(runner: any ProcessRunner = SystemProcessRunner(),
        inspector: any ProcessInspector = SystemProcessInspector(), clock: C,
        commandTimeout: Duration = .seconds(20), exitTimeout: Duration = .seconds(10),
        serverIsIdle: @escaping @Sendable (URL) throws -> Bool = {
            try WineServerProbe().isIdle(prefix: ContainedFileSystem(root: $0).pinRoot())
        }) async throws {
        try await Task.detached {
            let prefix = try self.prefix
            let fs = try await BlockingIO.run { try ContainedFileSystem(root: root).pinRoot() }
            let exists = try await BlockingIO.run {
                try fs.itemType(at: SafeRelativePath("store/Prefixes/\(prefix.lastPathComponent)")) != nil
            }
            if exists {
                let server = wine.deletingLastPathComponent().appendingPathComponent("wineserver")
                for command in ["-k", "-w"] {
                    let result = try await BlockingIO.run {
                        try await runner.run(server, arguments: [command], environment: ["WINEPREFIX": prefix.path, "WINEDEBUG": "-all"],
                            currentDirectory: nil, timeout: commandTimeout, timeoutWait: { try await clock.sleep(for: $0) })
                    }
                    // Wine 11 returns 1 without output when -k finds no server.
                    // Accept that status only with independent namespace proof;
                    // -w must still succeed and the process scan must be empty.
                    let absent = command == "-k" && result.exitCode == 1 && result.stdout.isEmpty && result.stderr.isEmpty
                    if absent {
                        guard try await BlockingIO.run({ try serverIsIdle(prefix) }) else {
                            throw LauncherError.io("Probe teardown could not confirm an idle wineserver; root retained at \(root.path)")
                        }
                    } else if result.exitCode != 0 {
                        throw LauncherError.io("Probe teardown wineserver \(command) exited \(result.exitCode); root retained at \(root.path)")
                    }
                }
            }
            let scope = try await BlockingIO.run {
                let session = try LaunchJournal(paths: paths).read(game: "starrail")
                return ProcessInspectionScope(executableRoots: [paths.runtimes, gameRoot, prefix],
                    processGroupIDs: session?.processGroupIDs ?? [], identities: Set(session?.processes ?? []),
                    bootSessionUUID: session?.bootSessionUUID, sessionStartTime: session?.sessionStartTime)
            }
            let deadline = clock.now.advanced(by: exitTimeout)
            while true {
                let processes = try await BlockingIO.run {
                    try inspector.processes(environmentContains: "WINEPREFIX", value: prefix.path, scope: scope)
                }
                if processes.isEmpty { break }
                guard clock.now < deadline else {
                    throw LauncherError.io("Probe teardown still has prefix-owned processes; root retained at \(root.path)")
                }
                try await clock.sleep(for: min(.milliseconds(100), clock.now.duration(to: deadline)))
            }
            try await BlockingIO.run { try fs.removePinnedRoot(onlyIfEmpty: false) }
        }.value
    }
}
