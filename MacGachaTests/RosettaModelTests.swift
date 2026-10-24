// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import Foundation
import Observation
import Synchronization
import Testing
import LauncherCore
import RuntimeManager
@testable import MacGacha

@Suite(.timeLimit(.minutes(1))) @MainActor struct RosettaModelTests {
    @Test func startAndActivationRecheckStatus() async throws {
        let probe = ModelRosettaProbe(.missing), center = NotificationCenter(), model = fixture(probe, center: center)
        var calls = probe.events.stream.makeAsyncIterator()
        await model.start()
        #expect(await calls.next() == 1)
        #expect(model.rosetta == .missing)
        probe.set(.installed)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(await calls.next() == 2)
        try await rosettaWait { model.rosetta == .installed }
    }

    @Test func playRefreshesAndRefusesMissingRosetta() async throws {
        let probe = ModelRosettaProbe(.missing), model = fixture(probe)
        #expect(model.rosetta == .unknown)
        model.play("genshin")
        await model.launchTasks["genshin"]?.value
        #expect(model.rosetta == .missing)
        guard case .failed(let failure) = model.launchState(for: "genshin") else { Issue.record("Missing launch refusal"); return }
        #expect(failure.message == LauncherError.rosettaMissing.userMessage)
        #expect(model.launchSlotOwner == nil)
    }

    @Test func recommendedSetupChecksBeforeInstalling() async throws {
        let probe = ModelRosettaProbe(.missing), fake = FakeRuntimeServices()
        let manifest = try await BundledRuntimeManifest.load()
        let model = AppModel(paths: paths, manifest: manifest, services: fake, defaults: nil, rosettaProbe: probe)
        model.installRecommended(for: "genshin")
        try await rosettaWait { model.runtimeSetupProgress["genshin"] == .failed(message: LauncherError.rosettaMissing.userMessage) }
        #expect(model.rosetta == .missing)
        #expect(fake.snapshot.bundleInstalls.isEmpty && fake.snapshot.installs.isEmpty)
    }

    @Test func promptPollStopsWhenInstalled() async throws {
        let probe = ModelRosettaProbe(.missing), clock = NativeWindowClock(), opens = Mutex(0)
        let model = fixture(probe, clock: clock, open: { opens.withLock { $0 += 1 } })
        await model.refreshRosetta()
        #expect(!model.rosettaInstallInProgress)
        model.requestRosettaInstall()
        #expect(model.rosettaInstallInProgress)
        await model.rosettaInstallTask?.value
        let poll = model.rosettaPollTask
        await clock.waitForSleep(.seconds(2))
        probe.set(.installed); clock.advance(by: .seconds(2))
        await poll?.value
        #expect(model.rosetta == .installed)
        #expect(!model.rosettaInstallInProgress)
        #expect(opens.withLock { $0 } == 1)
        #expect(clock.activeSleeps == 0 && model.rosettaPollTask == nil)
    }

    @Test(arguments: [RosettaStatus.missing, .unknown])
    func promptPollStopsAtInjectedDeadline(status: RosettaStatus) async throws {
        let probe = ModelRosettaProbe(.missing), clock = NativeWindowClock(), opens = Mutex(0)
        let model = fixture(probe, clock: clock, timeout: .seconds(6), open: { opens.withLock { $0 += 1 } })
        await model.refreshRosetta()
        model.requestRosettaInstall()
        #expect(model.rosettaInstallInProgress)
        let poll = model.rosettaPollTask, generation = model.rosettaPollGeneration
        await model.rosettaInstallTask?.value
        await clock.waitForSleep(.seconds(2))
        probe.set(status); await model.refreshRosetta()
        clock.advance(by: .seconds(6)); await poll?.value
        #expect(model.rosetta == status)
        #expect(!model.rosettaInstallInProgress)
        #expect(clock.activeSleeps == 0 && model.rosettaPollTask == nil)
        #expect(probe.count == 2)
        model.requestRosettaInstall()
        #expect(model.rosettaInstallInProgress)
        #expect(model.rosettaPollTask != nil)
        #expect(model.rosettaPollGeneration != generation)
        await model.rosettaInstallTask?.value
        #expect(opens.withLock { $0 } == 2)
        model.cancelRosettaInstall()
    }

    @Test func activationCanCancelASleepingPoll() async throws {
        let probe = ModelRosettaProbe(.missing), clock = NativeWindowClock(), center = NotificationCenter()
        let model = fixture(probe, clock: clock, center: center)
        await model.start(); model.requestRosettaInstall()
        let poll = model.rosettaPollTask
        await clock.waitForSleep(.seconds(2))
        probe.set(.installed)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await rosettaWait { model.rosetta == .installed }
        await poll?.value
        #expect(clock.activeSleeps == 0)
        #expect(!model.rosettaInstallInProgress)
    }

    @Test func helperFailureEndsAttemptAndAllowsRetry() async throws {
        let probe = ModelRosettaProbe(.missing), clock = NativeWindowClock(), opens = Mutex(0)
        let model = fixture(probe, clock: clock, open: {
            let count = opens.withLock { $0 += 1; return $0 }
            if count == 1 { throw LauncherError.io("Synthetic helper failure") }
        })
        await model.refreshRosetta()
        model.requestRosettaInstall()
        #expect(model.rosettaInstallInProgress)
        let poll = model.rosettaPollTask
        try await rosettaWait { !model.rosettaInstallInProgress }
        await poll?.value
        #expect(model.lastError == LauncherError.io("Synthetic helper failure").userMessage)
        #expect(clock.activeSleeps == 0)
        model.requestRosettaInstall()
        #expect(model.rosettaInstallInProgress)
        await model.rosettaInstallTask?.value
        #expect(opens.withLock { $0 } == 2)
        model.cancelRosettaInstall()
    }

    @Test func cancellationAllowsRetryBeforeOldHelperDrains() async throws {
        let probe = ModelRosettaProbe(.missing), clock = NativeWindowClock()
        let entered = AsyncStream<Void>.makeStream(), release = AsyncStream<Void>.makeStream()
        let opens = Mutex(0)
        let model = fixture(probe, clock: clock, open: {
            let count = opens.withLock { $0 += 1; return $0 }
            if count == 1 {
                entered.continuation.yield(())
                // A Launch Services callback may finish after cancellation.
                await withCheckedContinuation { continuation in
                    Task { for await _ in release.stream { break }; continuation.resume() }
                }
                throw LauncherError.io("Old helper failure")
            }
        })
        await model.refreshRosetta()
        model.requestRosettaInstall()
        for await _ in entered.stream { break }
        let oldHelper = model.rosettaInstallTask, oldPoll = model.rosettaPollTask
        await clock.waitForSleep(.seconds(2))
        model.cancelRosettaInstall()
        #expect(!model.rosettaInstallInProgress)
        #expect(clock.activeSleeps == 0)
        model.requestRosettaInstall()
        #expect(model.rosettaInstallInProgress)
        release.continuation.yield(())
        await oldHelper?.value; await oldPoll?.value
        #expect(model.rosettaInstallInProgress)
        #expect(model.lastError == nil)
        model.cancelRosettaInstall()
    }

    @Test func reopenWhileInProgressKeepsSinglePoll() async throws {
        let probe = ModelRosettaProbe(.missing), clock = NativeWindowClock(), opens = Mutex(0)
        let model = fixture(probe, clock: clock, timeout: .seconds(6), open: { opens.withLock { $0 += 1 } })
        await model.refreshRosetta()
        model.requestRosettaInstall()
        await model.rosettaInstallTask?.value
        let poll = model.rosettaPollTask, generation = model.rosettaPollGeneration
        await clock.waitForSleep(.seconds(2))
        model.requestRosettaInstall()
        await model.rosettaInstallTask?.value
        #expect(opens.withLock { $0 } == 2)
        #expect(model.rosettaPollGeneration == generation)
        #expect(clock.activeSleeps == 1)
        #expect(model.rosettaInstallInProgress)
        clock.advance(by: .seconds(6)); await poll?.value
        #expect(!model.rosettaInstallInProgress)
    }

    private var paths: AppPaths { AppPaths(root: URL(fileURLWithPath: "/inert/Rosetta")) }
    private func fixture(_ probe: ModelRosettaProbe, clock: NativeWindowClock = NativeWindowClock(), timeout: Duration = .seconds(300),
        center: NotificationCenter = NotificationCenter(),
        open: @escaping @MainActor @Sendable () async throws -> Void = {}) -> AppModel {
        AppModel(paths: paths, manifest: try? RuntimeManifest(components: []), services: PreviewRuntimeServices(), defaults: nil,
            rosettaProbe: probe, activationCenter: center, rosettaClock: clock, rosettaPollTimeout: timeout, rosettaPrompt: open)
    }
}

private final class ModelRosettaProbe: RosettaProbing, Sendable {
    private let state: Mutex<(RosettaStatus, Int)>
    let events = AsyncStream<Int>.makeStream()
    init(_ status: RosettaStatus) { state = Mutex((status, 0)) }
    var count: Int { state.withLock { $0.1 } }
    func set(_ status: RosettaStatus) { state.withLock { $0.0 = status } }
    func status() async -> RosettaStatus {
        let result = state.withLock { $0.1 += 1; return $0 }
        events.continuation.yield(result.1)
        return result.0
    }
}

@MainActor private func rosettaWait(_ condition: @escaping @MainActor () -> Bool) async throws {
    while !condition() {
        let stream = AsyncStream<Void> { continuation in
            withObservationTracking { _ = condition() } onChange: { continuation.yield(()); continuation.finish() }
        }
        for await _ in stream { break }
        try Task.checkCancellation()
    }
}
