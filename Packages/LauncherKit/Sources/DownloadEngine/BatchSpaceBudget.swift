// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

extension SpaceBudget {
    /// The engine's dependency check and conservative reservation for a complete
    /// partition. Every cross-batch object remains reserved beside the largest
    /// batch. The live free space is checked again before each batch is staged.
    package static func batchedPreflight(plan: InstallPlan, state: JournalState, fs: ContainedFileSystem,
        available: Int64) throws -> (batches: [[FileTask]], required: Int64) {
        let required = try Self.required(plan: plan, state: state, fs: fs).disk
        let paths = StagingLayout(id: plan.id)
        let staged = state.stagedFiles.subtracting(state.committedFiles)
        var transferCosts: [String: Int64] = [:]
        for object in plan.objects.values {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            let verified = try state.verifiedObjects.contains(object.id) && fs.size(at: paths.object(object)) == object.transferSize
            transferCosts[object.id] = verified ? 0 : object.transferSize
        }
        let pending = plan.files.filter { !state.committedFiles.contains($0.path) }
        let remaining = pending.filter { !staged.contains($0.path) }
        var batches: [[FileTask]] = []
        var index = 0, first = true
        // Consume each file once; repeatedly filtering the remaining plan would
        // make a one-file-per-batch partition quadratic at delivery scale.
        while index < remaining.count || (first && !staged.isEmpty) {
            let start = index
            var cost = margin, counted = Set<String>()
            while index < remaining.count {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                let file = remaining[index], ids = references(file)
                var added = file.size
                for id in ids.subtracting(counted) { added = try adding(added, transferCosts[id] ?? 0) }
                let next = try adding(cost, added)
                if next > available { break }
                counted.formUnion(ids); cost = next; index += 1
            }
            guard start != index || (first && !staged.isEmpty) else {
                throw LauncherError.insufficientSpace(required: required, available: available)
            }
            if first && !staged.isEmpty {
                let selected = staged.union(remaining[start..<index].map(\.path))
                batches.append(pending.filter { selected.contains($0.path) })
            } else { batches.append(Array(remaining[start..<index])) }
            first = false
        }
        var overwritten = Set<String>()
        for batch in batches {
            for file in batch where !staged.contains(file.path) {
                for extent in file.extents {
                    guard !Task.isCancelled else { throw LauncherError.cancelled }
                    if case .local(let source, _) = extent.source, extent.fallbackChunkID == nil,
                        overwritten.contains(batchPathKey(source)) {
                        throw LauncherError.insufficientSpace(required: required, available: available)
                    }
                }
            }
            overwritten.formUnion(batch.map { batchPathKey($0.path) })
        }
        var largest: Int64 = 0
        var seen = Set<String>(), shared = Set<String>()
        for batch in batches {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            let files = batch.filter { !staged.contains($0.path) }
            let ids = Set(files.flatMap { references($0) })
            var need = try files.reduce(Int64(0)) { try adding($0, $1.size) }
            for id in ids { need = try adding(need, transferCosts[id] ?? 0) }
            largest = max(largest, need)
            shared.formUnion(seen.intersection(ids)); seen.formUnion(ids)
        }
        var preflight = try adding(largest, margin)
        for id in shared {
            guard let object = plan.objects[id] else { throw LauncherError.io("Missing plan object") }
            preflight = try adding(preflight, object.transferSize)
        }
        return (batches, preflight)
    }

    /// Find a stable conservative budget: adding the shared-part reserve may
    /// change greedy boundaries, so repartition until the advertised amount
    /// passes the same preflight. Bound the work and fall back to whole mode.
    package static func minimumBatchedPreflight(plan: InstallPlan, state: JournalState, fs: ContainedFileSystem) throws -> Int64 {
        let whole = try required(plan: plan, state: state, fs: fs).disk
        let layout = StagingLayout(id: plan.id)
        var candidate = margin
        for file in try remainingFiles(plan: plan, state: state, fs: fs) {
            var need = file.size
            for id in references(file) {
                guard let object = plan.objects[id] else { throw LauncherError.io("Missing plan object") }
                if try !state.verifiedObjects.contains(id) || fs.size(at: layout.object(object)) != object.transferSize {
                    need = try adding(need, object.transferSize)
                }
            }
            candidate = max(candidate, try adding(need, margin))
        }
        for _ in 0..<64 {
            if candidate >= whole { return whole }
            do {
                let result = try batchedPreflight(plan: plan, state: state, fs: fs, available: candidate)
                if result.required <= candidate { return candidate }
                candidate = result.required
            } catch LauncherError.insufficientSpace {
                // A dependency boundary may require a whole-mode partition.
                return whole
            }
        }
        return whole
    }

    private static func batchPathKey(_ path: SafeRelativePath) -> String {
        path.description.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }
}
