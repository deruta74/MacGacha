// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import RuntimeManager
import GameLibrary
import Launch

struct RuntimeSetupPlan: Sendable, Equatable {
    struct Item: Sendable, Equatable, Identifiable {
        let id: String
        let name: String
        let size: Int64?
    }
    let gameID: String
    let items: [Item]
    var totalSize: Int64? { Self.total(items.map(\.size)) }
    let needsAppleTerms: Bool

    static func total(_ sizes: [Int64?]) -> Int64? {
        var total: Int64 = 0
        for size in sizes {
            guard let size else { return nil }
            let sum = total.addingReportingOverflow(size)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }
}

enum RuntimeSetupProgress: Sendable, Equatable {
    case installing(item: String, step: Int, of: Int, fraction: Double?)
    case failed(message: String)
}

struct RuntimeSetupRequirement {
    let item: RuntimeSetupPlan.Item
    let components: [RuntimeComponent]
}
struct RuntimeSetupChain {
    let plan: RuntimeSetupPlan
    var index = 0
    var attempted = false
}
enum RuntimeSetupItemState {
    case idle, installed, blocked
    case busy(fraction: Double?)
    case failed(String)
}

@MainActor extension AppModel {
    func runtimeSetupPlan(for gameID: String) -> RuntimeSetupPlan? {
        guard let missing = runtimeSetupRequirements(for: gameID), !missing.isEmpty else { return nil }
        return RuntimeSetupPlan(gameID: gameID, items: missing.map(\.item), needsAppleTerms: missing.contains { requirement in
            requirement.components.contains { $0.consent != nil && runtimeConsentAccepted[$0.id.rawValue] != true }
        })
    }

    /// Nil means the manifest cannot resolve a safe recommendation yet. Launch
    /// remains unavailable in that case; an empty list means everything is ready.
    func runtimeSetupRequirements(for gameID: String) -> [RuntimeSetupRequirement]? {
        #if DEBUG
        if debugLaunchRuntimesReady { return [] }
        #endif
        guard GameDefinition.find(gameID) != nil, let manifest,
            let bundle = manifest.defaultBundle(for: launchSettings(for: gameID).backend) else { return nil }
        var result: [RuntimeSetupRequirement] = []
        if installedBundles[bundle.id.rawValue] == nil {
            let components = manifest.components.filter { bundle.components.contains($0.id) }
            result.append(RuntimeSetupRequirement(item: .init(id: bundle.id.rawValue, name: bundle.displayName,
                size: RuntimeSetupPlan.total(components.map(\.size))), components: components))
        }
        guard launchSettings(for: gameID).compatibilityPatches else { return result }
        guard let recipe = Recipes.recipe(for: gameID) else { return nil }
        let kind: ComponentKind, name: String
        switch recipe.wrapper {
        case .none: return result
        case .jadeite: kind = .jadeite; name = String(localized: "Jadeite", comment: "Runtime component name")
        case .steamShim: kind = .steamShim; name = String(localized: "Steam shim", comment: "Runtime component name")
        }
        guard let component = manifest.components.first(where: { $0.kind == kind }) else { return nil }
        if !installed.contains(where: { $0.kind == kind && $0.version == component.version.rawValue }) {
            result.append(RuntimeSetupRequirement(item: .init(id: component.id.rawValue, name: name, size: component.size), components: [component]))
        }
        return result
    }

    func installRecommended(for gameID: String) {
        guard runtimeSetupChains[gameID] == nil, let plan = runtimeSetupPlan(for: gameID) else { return }
        runtimeSetupChains[gameID] = RuntimeSetupChain(plan: plan)
        advanceRuntimeSetups()
    }

    func cancelRuntimeSetup(for gameID: String) {
        guard let chain = runtimeSetupChains.removeValue(forKey: gameID) else { return }
        setRuntimeSetupProgress(nil, for: gameID)
        let id = chain.plan.items[chain.index].id
        // A shared item continues for its other subscriber. Joining a manual
        // install does not transfer cancellation ownership to this shortcut.
        if runtimeSetupOwnedItems.contains(id), !runtimeSetupChains.values.contains(where: { $0.plan.items[$0.index].id == id }) {
            runtimeSetupOwnedItems.remove(id)
            cancel(id)
        }
        scheduleRuntimeSetupUpdate()
    }

    func dismissRuntimeSetupFailure(for gameID: String) {
        if case .failed = runtimeSetupProgress[gameID] { setRuntimeSetupProgress(nil, for: gameID) }
    }

    /// Defer reduction until the current synchronous transition is complete:
    /// request/consent/install replace tasks and may briefly have no active task.
    func scheduleRuntimeSetupUpdate() {
        guard !runtimeSetupChains.isEmpty, !runtimeSetupUpdateScheduled else { return }
        runtimeSetupUpdateScheduled = true
        Task { [weak self] in
            guard let self else { return }
            self.runtimeSetupUpdateScheduled = false
            self.advanceRuntimeSetups()
        }
    }

    private func advanceRuntimeSetups() {
        for gameID in runtimeSetupChains.keys.sorted() {
            while var chain = runtimeSetupChains[gameID] {
                let item = chain.plan.items[chain.index]
                let progress: (Double?) -> RuntimeSetupProgress = {
                    .installing(item: item.name, step: chain.index + 1, of: chain.plan.items.count, fraction: $0)
                }
                switch runtimeSetupItemState(item.id) {
                case .installed:
                    runtimeSetupOwnedItems.remove(item.id)
                    chain.index += 1; chain.attempted = false
                    if chain.index == chain.plan.items.count {
                        runtimeSetupChains[gameID] = nil; setRuntimeSetupProgress(nil, for: gameID)
                    } else { runtimeSetupChains[gameID] = chain }
                    continue
                case .busy(let fraction):
                    chain.attempted = true; runtimeSetupChains[gameID] = chain
                    setRuntimeSetupProgress(progress(fraction), for: gameID)
                case .failed(let message) where chain.attempted:
                    runtimeSetupChains[gameID] = nil; runtimeSetupOwnedItems.remove(item.id)
                    setRuntimeSetupProgress(.failed(message: message), for: gameID)
                case .idle where chain.attempted:
                    runtimeSetupChains[gameID] = nil; runtimeSetupOwnedItems.remove(item.id)
                    setRuntimeSetupProgress(nil, for: gameID)
                case .idle, .failed, .blocked:
                    setRuntimeSetupProgress(progress(nil), for: gameID)
                    if canStartRuntimeSetupItem {
                        chain.attempted = true; runtimeSetupChains[gameID] = chain
                        runtimeSetupOwnedItems.insert(item.id)
                        install(item.id)
                    }
                }
                break
            }
        }
    }
}
