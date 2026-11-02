// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine

struct PreDownloadObjectCache: InstallObjectCache {
    let cache: PreDownloadStore
    let plan: PreDownloadPlan
    let hooks: CrashHooks

    static func prepare(edition: String, record: GameRecord, target: InstalledBuild, plan: InstallPlan,
        fs: ContainedFileSystem, hooks: CrashHooks) throws -> PreDownloadObjectCache? {
        let cache = try PreDownloadStore(fs: fs)
        try cache.finishDeletion()
        guard var saved = try cache.load() else { return nil }
        guard saved.plan.edition == edition, saved.plan.sourceTag == record.installed?.tag else { try cache.remove(); return nil }
        guard saved.plan.targetTag == target.tag else {
            if target.tag != record.installed?.tag { try cache.remove() }
            return nil
        }
        let needed = Set(plan.files.compactMap { $0.recipe?.containerID })
        // A chunk plan is not evidence of replacement patch metadata: ldiff may
        // be disabled or discovery may have failed. Keep cache ownership until
        // durable completion rather than deleting it before space preflight.
        guard !needed.isEmpty else { return nil }
        let matching = Set(saved.plan.containers.compactMap { id, container -> String? in
            guard needed.contains(id), let target = plan.objects[id], target.codec == .identity,
                target.transferSize == container.object.transferSize, target.decodedDigest == container.object.decodedDigest else { return nil }
            return id
        })
        let removed = Set(saved.plan.containers.keys).subtracting(matching)
        if !removed.isEmpty {
            saved.verified.subtract(removed); saved.completed = false; try cache.save(saved)
            for id in removed { try cache.fs.removeFile(at: cache.part(saved.plan.containers[id]!.object)) }
        }
        return PreDownloadObjectCache(cache: cache, plan: saved.plan, hooks: hooks)
    }

    func adopt(_ object: ChunkObject, to destination: SafeRelativePath, fs: ContainedFileSystem) async throws -> Bool {
        try await BlockingIO.run {
            guard try fs.rootIdentity() == plan.installation, let cached = plan.containers[object.id]?.object,
                cached.transferSize == object.transferSize, cached.decodedDigest == object.decodedDigest,
                object.codec == .identity else { return false }
            let source = try cache.part(cached)
            // A previous process can die after the move and before its engine
            // receipt. This owned staging destination is still verified once.
            if try fs.size(at: destination) == object.transferSize,
                try await ChunkFetcher.verifiedPart(object, fs: fs, part: destination) { return true }
            guard try cache.fs.size(at: source) == object.transferSize else { return false }
            guard try await ChunkFetcher.verifiedPart(object, fs: cache.fs, part: source) else {
                if var state = try cache.load() {
                    state.verified.remove(object.id); state.completed = false; try cache.save(state)
                }
                try cache.fs.removeFile(at: source)
                return false
            }
            if var state = try cache.load() {
                state.verified.remove(object.id); state.completed = false; try cache.save(state)
            }
            // Both locations are inside the same pinned installation. Rename
            // preserves the payload allocation; live free-space probes count it.
            try fs.rename(from: source, to: destination)
            try fs.fullSync(at: destination)
            hooks.reach(.afterPreDownloadContainerMoved)
            return true
        }
    }
}

extension PreDownloadStore {
    func reconcileInstalled(edition: String, installed: InstalledBuild) throws {
        try finishDeletion()
        guard let state = try load() else { return }
        guard state.plan.edition == edition, state.plan.sourceTag == installed.tag else { try remove(); return }
        try pruneUnreferencedParts(state)
        let known = Set(GameDefinition.find(edition)?.voices.map(\.code) ?? [])
        let categories = state.plan.categories.filter { !known.contains($0.matchingField) || installed.voices.contains($0.matchingField) }
        let needed = Set(categories.flatMap(\.containers))
        let voices = Set(state.plan.voices).intersection(installed.voices)
        guard categories != state.plan.categories || voices != Set(state.plan.voices) else { return }
        let old = state.plan
        let plan = try PreDownloadPlan(edition: old.edition, region: old.region, installation: old.installation, sourceTag: old.sourceTag,
            targetTag: old.targetTag, buildID: old.buildID, patchID: old.patchID, categories: categories, voices: voices,
            containers: old.containers.filter { needed.contains($0.key) })
        var next = try replace(plan); next.withdrawn = state.withdrawn; try save(next)
    }
}
