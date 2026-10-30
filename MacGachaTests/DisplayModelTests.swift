// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import Foundation
import Observation
import Synchronization
import Testing
import Launch
import LauncherCore
import RuntimeManager
@testable import MacGacha

@Suite(.timeLimit(.minutes(1))) @MainActor struct DisplayModelTests {
    @Test func startupRefreshesFixedDisplaysAndResolvesNamesInApp() async throws {
        let main = ConnectedDisplay(id: "00000000-0000-0000-0000-000000000001", name: "", isMain: true)
        let second = ConnectedDisplay(id: "00000000-0000-0000-0000-000000000002", name: "", isMain: false)
        let probe = ModelDisplayProbe([main])
        let model = try fixture(probe, names: { [main.id: "Main screen", second.id: "Second screen"] })
        #expect(model.connectedDisplays.map(\.name) == ["Main screen"])
        probe.set([main, second])
        await model.start()
        #expect(model.connectedDisplays.map(\.id) == [main.id, second.id])
        #expect(model.connectedDisplays.map(\.name) == ["Main screen", "Second screen"])
    }

    @Test func screenNotificationRefreshesObservableListAndPreservesDisconnectedChoice() async throws {
        let main = ConnectedDisplay(id: "00000000-0000-0000-0000-000000000001", name: "Main", isMain: true)
        let second = ConnectedDisplay(id: "00000000-0000-0000-0000-000000000002", name: "Second", isMain: false)
        let probe = ModelDisplayProbe([main, second]), center = NotificationCenter()
        let preferences = DisplayPreferences()
        let model = try fixture(probe, center: center, preferences: preferences)
        var settings = model.launchSettings(for: "genshin")
        settings.display = DisplayChoice(id: second.id, name: second.name)
        try model.saveLaunchSettings(settings, for: "genshin")
        try await model.flushLaunchSettings()
        let changed = AsyncStream<Void>.makeStream()
        var changes = changed.stream.makeAsyncIterator()
        withObservationTracking { _ = model.connectedDisplays } onChange: { changed.continuation.yield(()) }
        probe.set([main])
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        _ = await changes.next()
        #expect(model.connectedDisplays == [main])
        #expect(model.launchSettings(for: "genshin").display == settings.display)
        #expect(model.launchSettings(for: "genshin-cn").display == nil)
    }

    @Test func saveRejectsInvalidChoiceBeforeChangingCache() throws {
        let model = try fixture(ModelDisplayProbe([]))
        var settings = model.launchSettings(for: "genshin")
        settings.display = DisplayChoice(id: "invalid", name: "Screen")
        #expect(throws: LauncherError.self) { try model.saveLaunchSettings(settings, for: "genshin") }
        #expect(model.launchSettings(for: "genshin").display == nil)
        #expect(model.settingsWriteTask == nil)
    }

    @Test func unknownNameStaysEmptyForThePicker() throws {
        let display = ConnectedDisplay(id: "00000000-0000-0000-0000-000000000001", name: "", isMain: true)
        let model = try fixture(ModelDisplayProbe([display]))
        #expect(model.connectedDisplays == [display])
    }

    private func fixture(_ probe: any DisplayProbe, center: NotificationCenter = NotificationCenter(),
        preferences: (any LaunchPreferencesPersistence)? = nil,
        names: @escaping @MainActor @Sendable () -> [String: String] = { [:] }) throws -> AppModel {
        AppModel(paths: AppPaths(root: URL(fileURLWithPath: "/inert/displays")),
            manifest: try RuntimeManifest(components: []), services: FakeRuntimeServices(), defaults: nil,
            displayProbe: probe, displayNames: names, activationCenter: center, launchPreferences: preferences ?? DisplayPreferences())
    }
}

private final class ModelDisplayProbe: DisplayProbe, Sendable {
    private let value: Mutex<[ConnectedDisplay]>
    init(_ displays: [ConnectedDisplay]) { value = Mutex(displays) }
    func set(_ displays: [ConnectedDisplay]) { value.withLock { $0 = displays } }
    func connectedDisplays() -> [ConnectedDisplay] { value.withLock { $0 } }
}

private final class DisplayPreferences: LaunchPreferencesPersistence, Sendable {
    private let games = Mutex<[String: LaunchSettings]>([:])
    func loadGames() throws -> [String: LaunchSettings] { games.withLock { $0 } }
    func loadGlobal() throws -> GlobalLaunchSettings { GlobalLaunchSettings() }
    func save(_ settings: LaunchSettings, game: String) throws { games.withLock { $0[game] = settings } }
    func saveGlobal(_ settings: GlobalLaunchSettings) throws {}
}
