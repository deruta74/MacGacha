// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import RuntimeManager
import TestSupport

@Suite(.timeLimit(.minutes(1))) struct ProbeTeardownTests {
    @Test func missingProbeAfterRuntimeExtractionRemovesPartialSetup() async throws {
        let temp = try TempDir(), root = temp.url.appendingPathComponent("owned")
        let extracted = Mutex(false)
        await #expect(throws: (any Error).self) {
            try await withProbeTestRoot(root: root, setup: { root in
                try await BlockingIO.run {
                    let fs = try ContainedFileSystem(root: root)
                    try fs.createDirectory(at: SafeRelativePath("store/Runtimes/extracted/bin"))
                    try fs.writeAtomically(Data("extracted Wine".utf8), to: SafeRelativePath("store/Runtimes/extracted/bin/wine"))
                    extracted.withLock { $0 = true }
                    _ = try fs.readFile(at: SafeRelativePath("missing-fixtures/d3d11waitprobe.exe"), maxBytes: 1024)
                }
                throw LauncherError.io("Missing fixture should have failed setup")
            }, operation: { _ in Issue.record("Failed setup must not launch Wine") })
        }
        #expect(extracted.withLock { $0 })
        #expect(try ContainedFileSystem(root: temp.url).itemType(at: SafeRelativePath("owned")) == nil)
    }

    @Test func cancelledPartialSetupStillRemovesRuntimeFiles() async throws {
        let temp = try TempDir(), root = temp.url.appendingPathComponent("owned")
        let extracted = TestEvent(), never = TestEvent()
        let caller = Task {
            try await withProbeTestRoot(root: root, setup: { root in
                try await BlockingIO.run {
                    try ContainedFileSystem(root: root).createDirectory(at: SafeRelativePath("store/Runtimes/extracted"))
                }
                extracted.signal()
                try await never.wait()
                throw LauncherError.io("Cancelled setup continued")
            }, operation: { _ in Issue.record("Cancelled setup must not launch Wine") })
        }
        try await extracted.wait(); caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(try ContainedFileSystem(root: temp.url).itemType(at: SafeRelativePath("owned")) == nil)
    }

    @Test func partialSetupWithUnexpectedPrefixIsRetained() async throws {
        let temp = try TempDir(), root = temp.url.appendingPathComponent("owned")
        await #expect(throws: LauncherError.self) {
            try await withProbeTestRoot(root: root, setup: { root in
                try await BlockingIO.run {
                    try ContainedFileSystem(root: root).createDirectory(at: SafeRelativePath("store/Prefixes/unexpected"))
                }
                throw LauncherError.io("Setup failed after unexpectedly creating a prefix")
            }, operation: { _ in Issue.record("Failed setup continued") })
        }
        #expect(try ContainedFileSystem(root: temp.url).itemType(at: SafeRelativePath("owned/store/Prefixes/unexpected")) == .directory)
    }

    @Test func handshakeDiagnosticsDistinguishRunningFromProbeReadiness() async throws {
        let temp = try TempDir(), configuration = try fixture(root: temp.url.appendingPathComponent("owned"))
        let diagnostics = try await BlockingIO.run {
            try ContainedFileSystem(root: configuration.root).createDirectory(at: SafeRelativePath("game"))
            try configuration.recordHandshakePhase("afterClaimRename: waiting for manager .running")
            try configuration.signal("probe-ready")
            return try configuration.handshakeDiagnostics()
        }
        #expect(diagnostics.contains("afterClaimRename: waiting for manager .running"))
        #expect(diagnostics.contains("probe-ready=present"))
        #expect(diagnostics.contains("launcher-ready=absent"))
    }

    @Test func handshakeTimeoutNamesStepAndCancelsObservation() async throws {
        let temp = try TempDir(), runner = StalledProbeRunner(), clock = ManagerClock()
        let child = ProbeHarnessChild(executable: URL(fileURLWithPath: "/unused"), arguments: [], root: temp.url,
            label: "d3dmetal / afterClaimRename", runner: runner)
        // stop() may cancel before the runner starts. Only an entered runner
        // promises to signal its finished event; acknowledge that before timing out.
        try await runner.entered.wait()
        let observing = TestEvent(), detached = TestEvent(), never = TestEvent()
        let waiter = Task {
            try await child.waitUntilReady(step: "launcher-ready", timeout: .seconds(1),
                timeoutWait: { try await clock.sleep(for: $0) }) {
                defer { detached.signal() }
                observing.signal()
                try await never.wait()
            }
        }
        try await observing.wait()
        await clock.waitForSleep(1)
        clock.advance(by: .seconds(1))
        do {
            try await waiter.value
            Issue.record("Missing handshake must time out")
        } catch {
            #expect(String(describing: error).contains("d3dmetal / afterClaimRename / launcher-ready"))
            #expect(String(describing: error).contains("timed out"))
        }
        try await detached.wait()
        await child.stop()
        try await runner.finished.wait()
    }

    @Test func cancelledCallerStillShutsDownAndVerifiesBeforeDeleting() async throws {
        let temp = try TempDir(), configuration = try fixture(root: temp.url.appendingPathComponent("owned"))
        let runner = CleanupRunner(), inspector = CleanupInspector()
        let entered = TestEvent(), release = TestEvent()
        let caller = Task {
            entered.signal()
            await #expect(throws: CancellationError.self) { try await release.wait() }
            try await configuration.cleanup(runner: runner, inspector: inspector, clock: ContinuousClock())
        }
        try await entered.wait(); caller.cancel()
        try await caller.value
        #expect(runner.arguments == [["-k"], ["-w"]])
        #expect(!runner.sawCancellation)
        #expect(inspector.calls == 1)
        #expect(try !rootExists(configuration))
    }

    @Test(arguments: ["-k", "-w"])
    func shutdownFailurePreservesRoot(command: String) async throws {
        let temp = try TempDir(), configuration = try fixture(root: temp.url.appendingPathComponent("owned"))
        let runner = CleanupRunner(fail: command), inspector = CleanupInspector()
        await #expect(throws: LauncherError.self) {
            try await configuration.cleanup(runner: runner, inspector: inspector, clock: ContinuousClock())
        }
        #expect(try rootExists(configuration))
        #expect(inspector.calls == 0)
    }

    @Test func idleKillStatusRequiresNamespaceProofAndSuccessfulWait() async throws {
        let temp = try TempDir(), configuration = try fixture(root: temp.url.appendingPathComponent("owned"))
        let runner = CleanupRunner(fail: "-k", status: 1), inspector = CleanupInspector()
        try await configuration.cleanup(runner: runner, inspector: inspector, clock: ContinuousClock(), serverIsIdle: { _ in true })
        #expect(runner.arguments == [["-k"], ["-w"]])
        #expect(inspector.calls == 1)
        #expect(try !rootExists(configuration))
    }

    @Test func killStatusOneWithBusyNamespacePreservesRoot() async throws {
        let temp = try TempDir(), configuration = try fixture(root: temp.url.appendingPathComponent("owned"))
        await #expect(throws: LauncherError.self) {
            try await configuration.cleanup(runner: CleanupRunner(fail: "-k", status: 1), inspector: CleanupInspector(),
                clock: ContinuousClock(), serverIsIdle: { _ in false })
        }
        #expect(try rootExists(configuration))
    }

    @Test func inspectionUncertaintyPreservesRoot() async throws {
        let temp = try TempDir(), configuration = try fixture(root: temp.url.appendingPathComponent("owned"))
        await #expect(throws: ProcessInspectionError.self) {
            try await configuration.cleanup(runner: CleanupRunner(), inspector: CleanupInspector(uncertain: true), clock: ContinuousClock())
        }
        #expect(try rootExists(configuration))
    }

    @Test func survivingProcessTimesOutAndPreservesRoot() async throws {
        let temp = try TempDir(), configuration = try fixture(root: temp.url.appendingPathComponent("owned"))
        let clock = ManagerClock(), inspector = CleanupInspector(live: true)
        let cleanup = Task {
            try await configuration.cleanup(runner: CleanupRunner(), inspector: inspector, clock: clock, exitTimeout: .seconds(1))
        }
        try await inspector.scanned.wait()
        await clock.waitForSleep(1, duration: .milliseconds(100))
        clock.advance(by: .seconds(1))
        await #expect(throws: LauncherError.self) { try await cleanup.value }
        #expect(inspector.calls >= 2)
        #expect(try rootExists(configuration))
    }

    @Test func stalledShutdownCommandTimesOutAndPreservesRoot() async throws {
        let temp = try TempDir(), configuration = try fixture(root: temp.url.appendingPathComponent("owned"))
        let clock = ManagerClock(), runner = StalledProbeRunner()
        let cleanup = Task {
            try await configuration.cleanup(runner: runner, inspector: CleanupInspector(), clock: clock, commandTimeout: .seconds(1))
        }
        try await runner.entered.wait()
        await clock.waitForSleep(1)
        clock.advance(by: .seconds(1))
        await #expect(throws: LauncherError.self) { try await cleanup.value }
        try await runner.finished.wait()
        #expect(try rootExists(configuration))
    }

    @Test func failedChildCompletesHandshakeWaitWithoutWaitingForDeadline() async throws {
        let temp = try TempDir(), never = TestEvent()
        let child = ProbeHarnessChild(executable: URL(fileURLWithPath: "/unused"), arguments: [], root: temp.url,
            runner: FailedProbeRunner())
        await #expect(throws: LauncherError.self) {
            try await child.waitUntilReady { try await never.wait() }
        }
        await child.stop()
    }

    @Test func stalledChildTimesOutAndJoinsBeforeTeardown() async throws {
        let temp = try TempDir(), clock = ManagerClock(), runner = StalledProbeRunner()
        let child = ProbeHarnessChild(executable: URL(fileURLWithPath: "/unused"), arguments: [], root: temp.url,
            runner: runner, timeout: .seconds(1), timeoutWait: { try await clock.sleep(for: $0) })
        try await runner.entered.wait()
        await clock.waitForSleep(1)
        clock.advance(by: .seconds(1))
        await #expect(throws: LauncherError.self) { try await child.result() }
        try await runner.finished.wait()
        await child.stop()
    }

    @Test func cancelledCompletionCancelsAndJoinsChild() async throws {
        let temp = try TempDir(), runner = StalledProbeRunner()
        let child = ProbeHarnessChild(executable: URL(fileURLWithPath: "/unused"), arguments: [], root: temp.url, runner: runner)
        let waiter = Task { try await child.result() }
        try await runner.entered.wait(); waiter.cancel()
        await #expect(throws: (any Error).self) { try await waiter.value }
        try await runner.finished.wait()
        await child.stop()
    }
}

private func rootExists(_ configuration: ProbeLaunchConfiguration) throws -> Bool {
    try ContainedFileSystem(root: configuration.root.deletingLastPathComponent())
        .itemType(at: SafeRelativePath(configuration.root.lastPathComponent)) != nil
}

private func fixture(root: URL) throws -> ProbeLaunchConfiguration {
    let configuration = ProbeLaunchConfiguration(root: root, bundleID: try SafeIdentifier("probe"),
        bundleRoot: root.appendingPathComponent("store/Runtimes/probe"), wine: root.appendingPathComponent("store/Runtimes/probe/bin/wine"),
        digest: testDigest(Data()), componentIDs: ["probe"])
    let fs = try ContainedFileSystem(root: root)
    try fs.createRootDurably()
    try fs.createDirectory(at: SafeRelativePath("store/Prefixes/starrail-probe"))
    return configuration
}

private final class CleanupRunner: ProcessRunner, Sendable {
    private struct State { var arguments: [[String]] = []; var cancelled = false }
    private let state = Mutex(State())
    let fail: String?
    let status: Int32
    init(fail: String? = nil, status: Int32 = 2) { self.fail = fail; self.status = status }
    var arguments: [[String]] { state.withLock { $0.arguments } }
    var sawCancellation: Bool { state.withLock { $0.cancelled } }
    func run(_ executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL?) async throws -> ProcessResult {
        state.withLock { $0.arguments.append(arguments); $0.cancelled = $0.cancelled || Task.isCancelled }
        try Task.checkCancellation()
        return ProcessResult(exitCode: arguments.first == fail ? status : 0, stdout: Data(), stderr: Data())
    }
}

private final class CleanupInspector: ProcessInspector, Sendable {
    let uncertain: Bool, live: Bool
    let scanned = TestEvent()
    private let count = Mutex(0)
    var calls: Int { count.withLock { $0 } }
    init(uncertain: Bool = false, live: Bool = false) { self.uncertain = uncertain; self.live = live }
    func isAlive(_ identity: ProcessIdentity) -> Bool { live }
    func processes(environmentContains key: String, value: String, scope: ProcessInspectionScope) throws -> [InspectedProcess] {
        count.withLock { $0 += 1 }; scanned.signal()
        if uncertain { throw ProcessInspectionError.incompleteScan }
        return live ? [InspectedProcess(identity: ProcessIdentity(pid: 123, startTime: 1), executablePath: "/wine", arguments: [])] : []
    }
}

private final class StalledProbeRunner: ProcessRunner, Sendable {
    let entered = TestEvent(), finished = TestEvent(), release = TestEvent()
    func run(_ executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL?) async throws -> ProcessResult {
        entered.signal()
        defer { finished.signal() }
        try await release.wait()
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
}

private struct FailedProbeRunner: ProcessRunner {
    func run(_ executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL?) async throws -> ProcessResult {
        ProcessResult(exitCode: 7, stdout: Data(), stderr: Data("fixture child failure".utf8))
    }
}
