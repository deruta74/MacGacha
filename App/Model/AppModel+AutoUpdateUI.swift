// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import RuntimeManager

/// What the Dependencies panel shows for one dependency family (`RuntimeVersionGroup.id`)
/// while automatic updates work on it. Each case names the row ID it is about.
enum DependencyAutoUpdateState: Equatable, Sendable {
    /// A new recommended version downloads or installs beside the one games use.
    /// Progress comes from that row's own `.working` state.
    case installing(id: String)
    /// The new version is installed. It becomes active once no game, download
    /// or other dependency work is running.
    case waitingToActivate(id: String)
    /// Games already use the new version. The replaced one stays installed until
    /// a game has finished a normal session on the new version.
    case keepingPrevious(id: String)
    /// A newer D3DMetal exists while the active one was imported from the user's own
    /// Game Porting Toolkit. Wine still updates on its own; Apple's graphics layer waits
    /// for a yes. `id` is the bundle row that carries the newer D3DMetal.
    case graphicsUpdateOffered(id: String)
    /// The user skipped that D3DMetal version. The card stays quiet but keeps the way in.
    case graphicsUpdateDeclined(id: String)
}

/// The existing view surface backed by durable preferences and the update coordinator.
@MainActor extension AppModel {
    /// The "Update dependencies automatically" setting, on by default.
    var autoUpdateDependencies: Bool {
        get { globalLaunchSettings.autoUpdateDependencies }
        set {
            setGlobalLaunchPreference(\.autoUpdateDependencies, to: newValue)
            if !globalLaunchSettings.autoUpdateDependencies {
                dependencyAutoUpdateTask?.cancel()
                dependencyConsentTargets = [:]; runtimeUpdatesAwaitingConsent = []
            } else { scheduleDependencyAutoUpdates() }
        }
    }

    func dependencyAutoUpdate(for familyID: String) -> DependencyAutoUpdateState? {
        dependencyAutoUpdates[familyID]
    }

    /// Stops a background install. The version games use stays as it is.
    func cancelDependencyAutoUpdate(for familyID: String) {
        dependencyAutoUpdateSuppressed.insert(familyID)
        dependencyAutoUpdateTask?.cancel()
    }

    /// Skips the offered D3DMetal version. A later version offers again.
    /// TODO(auto-update): remember the declined bundle ID durably.
    func declineGraphicsUpdate(for familyID: String) {
        guard case .graphicsUpdateOffered(let id) = dependencyAutoUpdates[familyID] else { return }
        dependencyAutoUpdates[familyID] = .graphicsUpdateDeclined(id: id)
    }

    /// An offer nobody has answered yet. The rail marks Dependencies with a dot until then.
    var hasUnansweredDependencyOffer: Bool {
        dependencyAutoUpdates.values.contains { if case .graphicsUpdateOffered = $0 { true } else { false } }
    }

    /// True when the game's Set Up action stands for an automatic update that waits
    /// for Apple's terms, not for a first-time setup.
    func runtimeSetupIsUpdate(for gameID: String) -> Bool {
        runtimeUpdatesAwaitingConsent.contains(gameID)
    }
}
