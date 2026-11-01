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
        guard let recipe = Recipes.recipe(for: gameID) else { return nil }
        let required = LaunchResolver.requiredComponents(recipe: recipe, settings: launchSettings(for: gameID),
            runtimeBundleID: bundle.id.rawValue)
        // Keep the ABI-specific Wine correction beside its bundle, before optional wrappers.
        let scoped: Set<ComponentKind> = [.crypt32Fix, .surroundAudio, .genshinFps]
        let kinds = required.filter { scoped.contains($0) } + required.filter { !scoped.contains($0) }
        for kind in kinds {
            guard let component = manifest.components.first(where: {
                $0.kind == kind && (kind != .crypt32Fix || $0.id.rawValue == Crypt32Fix.componentID)
                    && (kind != .surroundAudio || $0.id.rawValue == SurroundAudio.componentID)
                    && (kind != .genshinFps || $0.id.rawValue == GenshinFps.componentID)
            }) else { return nil }
            if !installed.contains(where: { $0.kind == kind && $0.version == component.version.rawValue }) {
                result.append(RuntimeSetupRequirement(item: .init(id: component.id.rawValue, name: Self.kindName(kind),
                    size: component.size), components: [component]))
            }
        }
        return result
    }

    func installRecommended(for gameID: String) {
        guard canBeginGameOrRuntimeOperation() else { return }
        guard runtimeSetupChains[gameID] == nil, runtimeSetupRosettaChecks[gameID] == nil,
            let plan = runtimeSetupPlan(for: gameID), let first = plan.items.first else { return }
        setRuntimeSetupProgress(.installing(item: first.name, step: 1, of: plan.items.count, fraction: nil), for: gameID)
        let generation = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if self.runtimeSetupRosettaChecks[gameID]?.id == generation { self.runtimeSetupRosettaChecks[gameID] = nil } }
            await self.refreshRosetta()
            guard !Task.isCancelled, self.runtimeSetupRosettaChecks[gameID]?.id == generation else { return }
            if self.rosetta == .missing {
                self.setRuntimeSetupProgress(.failed(message: LauncherError.rosettaMissing.userMessage), for: gameID)
                self.show(LauncherError.rosettaMissing)
                return
            }
            self.runtimeSetupChains[gameID] = RuntimeSetupChain(plan: plan)
            self.advanceRuntimeSetups()
        }
        runtimeSetupRosettaChecks[gameID] = (generation, task)
    }

    func cancelRuntimeSetup(for gameID: String) {
        if let check = runtimeSetupRosettaChecks.removeValue(forKey: gameID) {
            check.task.cancel(); setRuntimeSetupProgress(nil, for: gameID)
        }
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
