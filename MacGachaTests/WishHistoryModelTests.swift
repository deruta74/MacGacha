// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import GameLibrary
import Launch
@testable import MacGacha

@Suite(.timeLimit(.minutes(1))) @MainActor struct WishHistoryModelTests {
    @Test func disabledFeatureDoesNotInvokeExporterAndHasNoMenuEligibility() async throws {
        let service = ModelWishExporter(), model = fixture(service)
        #expect(!model.wishHistoryEnabled); #expect(!model.canExportWishHistory("genshin"))
        await #expect(throws: LauncherError.cancelled) { try await model.exportWishHistory("genshin") }
        #expect(service.calls.withLock { $0 } == 0)
    }

    @Test func switchPersistsAndExportReturnsSavePanelDataAndCounts() async throws {
        let preferences = WishPreferences(), service = ModelWishExporter(), model = fixture(service, preferences)
        model.wishHistoryEnabled = true
        try await model.flushLaunchSettings()
        #expect(try preferences.loadGlobal().wishHistoryEnabled)
        #expect(model.canExportWishHistory("genshin")); #expect(!model.canExportWishHistory("genshin-cn"))
        let result = try await model.exportWishHistory("genshin")
        #expect(result.countsByGame == ["genshin": 3]); #expect(result.data == Data("synthetic".utf8))
        #expect(model.wishHistoryProgress == nil); #expect(model.wishHistoryFailure == nil)
        let next = fixture(service, preferences)
        await next.reattachOnStart()
        #expect(next.wishHistoryEnabled)
        #expect(service.calls.withLock { $0 } == 1)
    }

    @Test func disablingCancelsAnActiveExportAndHidesLateProgress() async throws {
        let gate = WishModelGate(), service = ModelWishExporter(gate), model = fixture(service)
        model.wishHistoryEnabled = true
        let export = Task { try await model.exportWishHistory("genshin") }
        try await gate.waitForEntry()
        #expect(model.wishHistoryProgress?.banner == "301")
        #expect(model.wishHistoryProgress?.page == 2)
        model.wishHistoryEnabled = false
        #expect(model.wishHistoryProgress == nil); #expect(!model.canExportWishHistory("genshin"))
        await #expect(throws: LauncherError.cancelled) { try await export.value }
        #expect(model.wishHistoryFailure == nil)
        try await model.flushLaunchSettings()
    }

    @Test func callerCancellationPropagatesToExporter() async throws {
        let gate = WishModelGate(), service = ModelWishExporter(gate), model = fixture(service)
        model.wishHistoryEnabled = true
        let export = Task { try await model.exportWishHistory("genshin") }
        try await gate.waitForEntry(); export.cancel()
        await #expect(throws: LauncherError.cancelled) { try await export.value }
        #expect(model.wishHistoryProgress == nil)
    }

    @Test(arguments: [LauncherError.wishHistoryNoCachedLink, .wishHistoryLinkExpired, .wishHistoryNetwork, .wishHistoryInvalidData])
    func exportFailuresAreTyped(error: LauncherError) async throws {
        let model = fixture(ModelWishExporter(error: error)); model.wishHistoryEnabled = true
        await #expect(throws: error) { try await model.exportWishHistory("genshin") }
        #expect(model.wishHistoryFailure == error)
        #expect(!error.userMessage.isEmpty)
    }

    @Test func arbitraryServiceErrorsAreSanitized() async throws {
        let model = fixture(ModelWishExporter(error: .transport("SYNTHETIC_PRIVATE"))); model.wishHistoryEnabled = true
        await #expect(throws: LauncherError.wishHistoryNetwork) { try await model.exportWishHistory("genshin") }
        #expect(model.wishHistoryFailure == .wishHistoryNetwork)
    }

    @Test func operationAndRestartBlockExportWithoutReadingCache() throws {
        let service = ModelWishExporter(), model = fixture(service); model.wishHistoryEnabled = true
        model.gameOperation = GameOperationToken(id: "genshin", generation: UUID())
        #expect(!model.canExportWishHistory("genshin"))
        model.gameOperation = nil; model.setLanguageRestart(UUID())
        #expect(!model.canExportWishHistory("genshin"))
        #expect(service.calls.withLock { $0 } == 0)
    }

    private func fixture(_ service: ModelWishExporter, _ preferences: WishPreferences = WishPreferences()) -> AppModel {
        let model = AppModel(paths: AppPaths(root: URL(fileURLWithPath: "/inert/wish-model")),
            defaults: nil, launchPreferences: preferences, wishHistoryExporter: service)
        let root = URL(fileURLWithPath: "/inert/game")
        model.setGameRecord("genshin", GameRecord(installPath: root, ownership: .created,
            executable: try! SafeRelativePath("GenshinImpact.exe"), installed: InstalledBuild(tag: "1", buildID: "1", categories: [], voices: []),
            installIdentity: FileSystemIdentity(volumeUUID: nil, device: 1, inode: 2)))
        model.setGameState("genshin", GameState(status: .installed(tag: "1")))
        return model
    }
}

private actor WishModelGate {
    private var entered: CheckedContinuation<Void, Never>?
    private var didEnter = false
    func signal() { didEnter = true; entered?.resume(); entered = nil }
    func waitForEntry() async throws {
        if !didEnter { await withCheckedContinuation { entered = $0 } }
    }
}
private final class ModelWishExporter: WishHistoryExporting {
    let calls = Mutex<Int>(0)
    let gate: WishModelGate?
    let error: LauncherError?
    init(_ gate: WishModelGate? = nil, error: LauncherError? = nil) { self.gate = gate; self.error = error }
    func export(_ request: WishHistoryRequest, progress: @escaping @Sendable (WishHistoryProgress) async -> Void) async throws -> WishHistoryExport {
        calls.withLock { $0 += 1 }
        if let error { throw error }
        await progress(WishHistoryProgress(gameID: request.game.id, banner: "301", page: 2, count: 3))
        if let gate { await gate.signal(); try await Task.sleep(for: .seconds(3600)) }
        return WishHistoryExport(data: Data("synthetic".utf8), countsByGame: [request.game.id: 3])
    }
}
private final class WishPreferences: LaunchPreferencesPersistence, Sendable {
    let settings = Mutex(GlobalLaunchSettings())
    func loadGames() throws -> [String: LaunchSettings] { [:] }
    func loadGlobal() throws -> GlobalLaunchSettings { settings.withLock { $0 } }
    func save(_ settings: LaunchSettings, game: String) throws {}
    func saveGlobal(_ settings: GlobalLaunchSettings) throws { self.settings.withLock { $0 = settings } }
}
