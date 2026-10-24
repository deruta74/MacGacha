// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import Foundation
import LauncherCore

/// Inert model construction stays deterministic; live() supplies the system probe.
struct UnknownRosettaProbe: RosettaProbing {
    func status() async -> RosettaStatus { .unknown }
}

@MainActor enum RosettaPrompt {
    static func open() async throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Rosetta Prompt.app", isDirectory: true)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: helper, configuration: configuration)
    }
}

@MainActor extension AppModel {
    func refreshRosetta() async {
        if let task = rosettaRefreshTask { await task.value; return }
        let probe = rosettaProbe, generation = UUID()
        rosettaRefreshGeneration = generation
        let task = Task { [weak self] in
            let status = await probe.status()
            guard let self, !Task.isCancelled, self.rosettaRefreshGeneration == generation else { return }
            self.setRosetta(status)
            if status == .installed { self.cancelRosettaInstall() }
        }
        rosettaRefreshTask = task
        await task.value
        if rosettaRefreshGeneration == generation { rosettaRefreshTask = nil }
    }

    func requestRosettaInstall() {
        guard rosetta != .installed else { return }
        if !rosettaInstallInProgress { startRosettaInstallPoll() }
        let generation = rosettaPollGeneration, request = UUID(), prompt = rosettaPrompt
        // Reopening brings Apple's dialog forward; it does not extend the poll.
        rosettaInstallTask?.cancel()
        rosettaPromptGeneration = request
        rosettaInstallTask = Task { [weak self] in
            defer { if self?.rosettaPromptGeneration == request { self?.rosettaInstallTask = nil } }
            do { try await prompt() }
            catch {
                guard !Task.isCancelled, let self, self.rosettaPollGeneration == generation else { return }
                // Launch Services can report failure while Apple's installer
                // handles this launch. Only the completed poll can reject it.
                self.rosettaHelperLaunchFailed = true
                await self.refreshRosetta()
            }
        }
    }

    func cancelRosettaInstall() {
        // Stop our observation, not Apple's installation. Old callbacks must not
        // clear a subsequent attempt while Launch Services finishes draining.
        rosettaPollGeneration = UUID(); rosettaPromptGeneration = UUID()
        rosettaPollTask?.cancel(); rosettaPollTask = nil
        rosettaInstallTask?.cancel(); rosettaInstallTask = nil
        rosettaHelperLaunchFailed = false
        setRosettaInstallInProgress(false)
    }

    private func startRosettaInstallPoll() {
        let generation = UUID(), clock = rosettaClock, interval = rosettaPollInterval, timeout = rosettaPollTimeout
        rosettaPollGeneration = generation
        rosettaHelperLaunchFailed = false
        setRosettaInstallInProgress(true)
        rosettaPollTask = Task { [weak self] in
            defer { if self?.rosettaPollGeneration == generation { self?.cancelRosettaInstall() } }
            await Self.pollRosetta(clock, interval: interval, timeout: timeout) { [weak self] in
                guard let self else { return true }
                await self.refreshRosetta()
                return self.rosetta == .installed
            }
            guard !Task.isCancelled, let self, self.rosettaPollGeneration == generation,
                self.rosettaHelperLaunchFailed else { return }
            await self.refreshRosetta()
            guard !Task.isCancelled, self.rosettaPollGeneration == generation, self.rosetta == .missing else { return }
            self.cancelRosettaInstall()
            self.show(LauncherError.rosettaInstallerUnavailable)
        }
    }

    private static func pollRosetta<C: Clock>(_ clock: C, interval: Duration, timeout: Duration,
        check: @MainActor () async -> Bool) async where C.Duration == Duration {
        guard interval > .zero, timeout > .zero else { return }
        let deadline = clock.now.advanced(by: timeout)
        do {
            while !Task.isCancelled, clock.now < deadline {
                try await clock.sleep(until: min(clock.now.advanced(by: interval), deadline), tolerance: nil)
                guard !Task.isCancelled, clock.now < deadline else { return }
                if await check() { return }
            }
        } catch { } // Poll cancellation or timeout never changes the launch outcome.
    }
}
