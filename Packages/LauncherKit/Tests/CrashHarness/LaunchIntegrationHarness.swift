// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import LauncherCore
import GameLibrary
import TestSupport
import Launch

/// All manager waits live in a killable process, never in the test runner.
func runLaunchIntegration(root: URL, mode: String, conflict: Bool) async throws {
    let configuration = try await BlockingIO.run { try ProbeLaunchConfiguration.read(root: root) }
    if mode == "cleanup" {
        try await configuration.cleanup(clock: ContinuousClock())
        return
    }
    let hooks: LaunchFileHooks
    if let step = LaunchFileStep(rawValue: mode) {
        hooks = LaunchFileHooks(at: step, action: { _ = kill(getpid(), SIGKILL) })
    } else { hooks = .none }
    let inspector = DiagnosticProbeInspector(configuration: configuration, stall: mode == "stall-inspection")
    let manager = configuration.manager(hooks: hooks, inspector: inspector)
    try await BlockingIO.run { try configuration.recordHandshakePhase("\(mode): starting manager") }
    if mode == "recover" {
        try await BlockingIO.run { try configuration.recordHandshakePhase("\(mode): waiting for reattachAll") }
        let sessions = await manager.reattachAll()
        await manager.markReady(game: "starrail")
        try await BlockingIO.run {
            let fs = try ContainedFileSystem(root: configuration.gameRoot)
            try fs.writeAtomically(JSONEncoder().encode(sessions.mapValues(\.sessionID)), to: SafeRelativePath("recovery-attached.json"))
            try configuration.signal("recovery-ready")
        }
        await manager.waitForSupervision(game: "starrail")
        guard try await manager.sessionObservation(for: "starrail") == nil else {
            throw LauncherError.io("Probe recovery did not finalize")
        }
        return
    }
    let ready = try FileAppearanceEvent(configuration.gameRoot.appendingPathComponent("probe-ready"))
    try await BlockingIO.run { try configuration.recordHandshakePhase("\(mode): waiting for manager .running") }
    let stream = await manager.launch(game: GameDefinition.all.first { $0.id == "starrail" }!, installRoot: configuration.gameRoot, gameBuild: "probe")
    var restored = false
    for await event in stream {
        if case .stage(let stage) = event {
            try await BlockingIO.run { try configuration.recordHandshakePhase("\(mode): manager stage \(stage.rawValue); waiting for .running") }
        }
        if case .failed(let failure) = event { throw failure }
        if case .restored(let outcome) = event {
            guard outcome == .clean else { throw LauncherError.io("Probe did not restore cleanly") }
            restored = true
        }
        if case .running = event {
            try await BlockingIO.run { try configuration.recordHandshakePhase("\(mode): manager .running received; waiting for probe-ready") }
            try await ready.wait()
            await manager.markReady(game: "starrail")
            try await BlockingIO.run {
                let fs = try ContainedFileSystem(root: configuration.gameRoot)
                if conflict { try fs.writeAtomically(Data("integration replacement vulkan DLL".utf8), to: SafeRelativePath("vulkan-1.dll")) }
                try configuration.recordHandshakePhase("\(mode): probe-ready observed; publishing launcher-ready")
                try fs.writeAtomically(Data(String(getpid()).utf8), to: SafeRelativePath("launcher-ready"))
            }
        }
    }
    await manager.waitForSupervision(game: "starrail")
    if mode == "complete", restored { return }
    throw LauncherError.io("Launch completed without reaching crash boundary: \(mode)")
}

private struct DiagnosticProbeInspector: ProcessInspector {
    let configuration: ProbeLaunchConfiguration
    let stall: Bool
    func isAlive(_ identity: ProcessIdentity) -> Bool { SystemProcessInspector().isAlive(identity) }
    func processes(environmentContains key: String, value: String, scope: ProcessInspectionScope) throws -> [InspectedProcess] {
        let fs = try ContainedFileSystem(root: configuration.gameRoot)
        if stall, try fs.itemType(at: SafeRelativePath("probe-release")) != nil {
            try configuration.signal("inspection-stalled")
            throw ProcessInspectionError.incompleteScan
        }
        do {
            return try SystemProcessInspector().processes(environmentContains: key, value: value, scope: scope)
        } catch {
            // Diagnostic failure must not replace the actual inspection failure.
            try? fs.writeAtomically(Data(String(describing: error).utf8), to: SafeRelativePath("inspection-error"))
            throw error
        }
    }
}
