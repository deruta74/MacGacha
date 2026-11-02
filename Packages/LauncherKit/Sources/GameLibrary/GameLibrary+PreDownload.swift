// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine
import Sophon

extension GameLibrary {
    public func preDownload(_ game: GameDefinition) -> AsyncThrowingStream<OperationEvent, any Error> {
        preDownloadStream(game, resume: false, expected: nil)
    }
    public func resumePreDownload(_ game: GameDefinition, expectedPlanID: SafeIdentifier? = nil) -> AsyncThrowingStream<OperationEvent, any Error> {
        preDownloadStream(game, resume: true, expected: expectedPlanID)
    }
    public func deletePreDownload(_ game: GameDefinition) async throws {
        let scope = try await preDownloadScope(game, action: .deletePreDownload)
        defer { withExtendedLifetime(scope) {} }
        try scope.cache.remove()
    }

    /// Refresh may reconcile metadata only under the ordinary mutation exclusion.
    /// Busy/live games retain their cache until a later guarded refresh.
    public func preDownloadInfo(_ game: GameDefinition, refresh: Bool = true) async throws -> PreDownloadInfo {
        guard let record = try await store.load(game.id), let installed = record.installed, !record.uninstalling else { return .unavailable }
        try requireGameLocationAvailable(record.installPath)
        let cache = try PreDownloadStore(fs: ContainedFileSystem(root: record.installPath, expectedRootIdentity: record.installIdentity))
        let saved = try cache.load()
        if !refresh { return try cache.info(saved, installed: installed, edition: game.id) }
        if record.pending != nil { return PreDownloadInfo(state: .unavailable, canDelete: saved != nil) }
        let branches: (main: GameBranch, preDownload: GameBranch?)
        do { branches = try await api.branches(biz: game.biz) }
        catch {
            if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
            return try cache.info(saved, installed: installed, edition: game.id)
        }
        var offered: PreDownloadPlan?
        var discoveryFailed = false
        if let future = branches.preDownload, future.diffTags.contains(installed.tag), future.tag != installed.tag {
            do {
                if try await api.config(biz: game.biz).enableLdiff { offered = try await discoverPreDownload(game, record: record, branch: future) }
            } catch {
                if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
                discoveryFailed = true
            }
        }
        do {
            let scope = try await preDownloadScope(game)
            defer { withExtendedLifetime(scope) {} }
            guard scope.record == record else { throw LauncherError.busy("game changed during pre-download discovery") }
            var current = try scope.cache.load()
            if let old = current, old.plan.edition != game.id || old.plan.sourceTag != installed.tag
                || (branches.main.tag != old.plan.sourceTag && branches.main.tag != old.plan.targetTag)
                || branches.preDownload.map({ $0.tag != old.plan.targetTag }) == true {
                try scope.cache.remove(); current = nil
            }
            // Branch selectors already establish staleness even if the new
            // campaign's config/build/manifest could not be loaded.
            if discoveryFailed { return try scope.cache.info(current, installed: installed, edition: game.id) }
            if let offered {
                if current != nil {
                    let state = try scope.cache.replace(offered)
                    return try scope.cache.info(state, installed: installed, edition: game.id)
                }
                return PreDownloadInfo(state: .available, version: offered.targetTag, bytes: try offered.bytes)
            }
            if var current {
                current.withdrawn = branches.main.tag != current.plan.targetTag || !current.completed
                try scope.cache.save(current)
                return try scope.cache.info(current, installed: installed, edition: game.id)
            }
            return .unavailable
        } catch LauncherError.busy {
            // A live session or another operation can defer mutation. Preserve
            // the existing overlay when the discovered campaign still agrees;
            // do not hide a paused/ready cache merely because it cannot prune.
            if let saved,
                saved.plan.edition == game.id, saved.plan.sourceTag == installed.tag,
                branches.main.tag == saved.plan.sourceTag || branches.main.tag == saved.plan.targetTag,
                branches.preDownload.map({ $0.tag == saved.plan.targetTag }) ?? true,
                discoveryFailed || branches.main.tag == saved.plan.targetTag || offered != nil {
                return try cache.info(saved, installed: installed, edition: game.id)
            }
            return PreDownloadInfo(state: .unavailable, canDelete: saved != nil)
        }
    }

    private func preDownloadStream(_ game: GameDefinition, resume: Bool, expected: SafeIdentifier?) -> AsyncThrowingStream<OperationEvent, any Error> {
        let session = PreDownloadSession(library: self, game: game, resume: resume, expected: expected)
        return session.stream()
    }

    func preparePreDownload(_ game: GameDefinition, resume: Bool, expected: SafeIdentifier?) async throws -> PreparedPreDownload {
        let settings = await runner.preDownloadSettings()
        try settings.pipeline.validate()
        guard settings.maxConcurrentObjects > 0 else { throw LauncherError.io("Invalid object concurrency limit") }
        let scope = try await preDownloadScope(game)
        defer { withExtendedLifetime(scope) {} }
        var state: PreDownloadState
        if resume {
            guard let saved = try scope.cache.load(), saved.plan.edition == game.id,
                saved.plan.sourceTag == scope.record.installed?.tag, !saved.withdrawn else { throw LauncherError.io("pre-download plan unavailable") }
            let savedID = try saved.plan.id
            guard expected == nil || expected == savedID else { throw LauncherError.io("pre-download plan changed") }
            state = saved
        } else {
            guard let installed = scope.record.installed else { throw LauncherError.io("game is not installed") }
            let branches = try await api.branches(biz: game.biz)
            guard let future = branches.preDownload, future.diffTags.contains(installed.tag), future.tag != installed.tag,
                try await api.config(biz: game.biz).enableLdiff else { throw LauncherError.io("pre-download unavailable") }
            let plan = try await discoverPreDownload(game, record: scope.record, branch: future)
            state = try scope.cache.replace(plan)
            hooks.reach(.afterPreDownloadPlanStored)
        }
        state.completed = false
        return PreparedPreDownload(transfer: PreDownloadTransfer(state: state, cache: scope.cache,
            fetcher: settings.fetcher, disk: disk, hooks: hooks, maxConcurrentObjects: settings.maxConcurrentObjects, pipeline: settings.pipeline),
            lease: scope.lease, lock: scope.lock)
    }

    private func preDownloadScope(_ game: GameDefinition, action: GameAction = .preDownload) async throws -> PreDownloadScope {
        try await operationGuard?.willOperate(on: game.id)
        try await store.waitForPipelineDrain()
        let lock = try acquireGameLock(game.id)
        let lease = try await store.acquireOperationLease(retainedGameLock: lock)
        guard let record = try await store.load(game.id) else { throw LauncherError.io("game is not installed") }
        try GameRecordRules.check(action, record: record, others: [])
        try requireGameLocationAvailable(record.installPath)
        let fs = try ContainedFileSystem(root: record.installPath, fileOps: fileOps, expectedRootIdentity: record.installIdentity)
        let cache = try PreDownloadStore(fs: fs)
        try cache.finishDeletion()
        return PreDownloadScope(record: record, cache: cache, lease: lease, lock: lock)
    }

    private func discoverPreDownload(_ game: GameDefinition, record: GameRecord, branch: GameBranch) async throws -> PreDownloadPlan {
        guard let installed = record.installed else { throw LauncherError.io("game is not installed") }
        let full = try await api.build(branch), patch = try await api.patchBuild(branch)
        guard full.tag == branch.tag, patch.tag == full.tag, patch.buildID == full.buildID else { throw LauncherError.io("pre-download target changed") }
        let selected = try SophonPlanner.selectCategories(branch, build: full, voices: installed.voices)
        var available: [String: PatchBuildCategory] = [:]
        for category in patch.categories {
            guard available.updateValue(category, forKey: category.id) == nil else { throw LauncherError.io("duplicate patch category") }
        }
        var categories: [PreDownloadCategory] = [], containers: [String: PreDownloadContainer] = [:]
        for full in selected {
            guard let category = available[full.id], category.region == game.region,
                category.matchingField == full.matchingField, category.diffCodec == .identity else { throw LauncherError.io("missing pre-download category") }
            let manifest = try await api.patchManifest(category).manifest
            var ids = Set<String>()
            for file in manifest.files {
                try Task.checkCancellation()
                guard let instruction = file.patches[installed.tag] else { continue }
                let id = SophonPlanner.patchContainerIdentity(id: instruction.containerID, digest: instruction.containerMD5)
                let url = try category.diffURL(id: instruction.containerID)
                var urls = [url]
                if let old = containers[id]?.object {
                    guard old.transferSize == instruction.containerSize, old.decodedDigest == instruction.containerMD5 else { throw LauncherError.io("conflicting pre-download container") }
                    urls = Array(Set(old.urls + urls)).sorted { $0.absoluteString < $1.absoluteString }
                }
                let object = ChunkObject(id: id, urls: Array(urls.prefix(InstallPlan.maximumURLsPerObject)), transferSize: instruction.containerSize,
                    transferDigest: instruction.containerMD5, decodedSize: instruction.containerSize, decodedDigest: instruction.containerMD5)
                containers[id] = PreDownloadContainer(rawID: instruction.containerID, object: object); ids.insert(id)
            }
            categories.append(PreDownloadCategory(id: category.id, matchingField: category.matchingField, containers: ids.sorted()))
        }
        return try PreDownloadPlan(edition: game.id, region: game.region, installation: record.installIdentity, sourceTag: installed.tag,
            targetTag: full.tag, buildID: full.buildID, patchID: patch.patchID, categories: categories, voices: installed.voices, containers: containers)
    }
}

private struct PreDownloadScope: Sendable {
    let record: GameRecord
    let cache: PreDownloadStore
    let lease: GameOperationLease
    let lock: InstallLock
}

extension PreDownloadStore {
    func info(_ state: PreDownloadState?, installed: InstalledBuild, edition: String) throws -> PreDownloadInfo {
        guard let state else { return .unavailable }
        let plan = state.plan, valid = plan.edition == edition && plan.sourceTag == installed.tag
        var downloaded: Int64 = 0
        for id in state.verified {
            if let object = plan.containers[id]?.object, try fs.size(at: part(object)) == object.transferSize { downloaded = try SpaceBudget.adding(downloaded, object.transferSize) }
        }
        let total = try plan.bytes
        let ready = state.completed && downloaded == total && Set(plan.voices) == installed.voices
        return PreDownloadInfo(state: !valid || state.withdrawn ? .unavailable : ready ? .ready : .paused,
            version: plan.targetTag, bytes: try plan.bytes, downloaded: downloaded, planID: try plan.id, planDigest: state.planDigest, canDelete: true)
    }
}
