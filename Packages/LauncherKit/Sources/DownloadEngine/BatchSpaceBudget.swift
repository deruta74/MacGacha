// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

extension SpaceBudget {
    /// Minimal contiguous batches preserve every local dependency without a
    /// fallback. Their reservation covers the entire sequence, including output
    /// kept after commits and parts retained for later batches.
    package static func batchedPreflight(plan: InstallPlan, state: JournalState, fs: ContainedFileSystem,
        available: Int64, maxConcurrentObjects: Int = defaultMaxConcurrentObjects, pipeline: PipelineConfiguration = .default) throws -> (batches: [[FileTask]], required: Int64) {
        try plan.validate(supportedCodecs: Set(ChunkCodec.allCases))
        let pending = plan.files.filter { !state.committedFiles.contains($0.path) }
        guard !pending.isEmpty else { return ([], margin) }
        let staged = pending.filter { state.stagedFiles.contains($0.path) }
        let stagedPaths = Set(staged.map(\.path)), stagedKeys = Set(staged.map { batchPathKey($0.path) })
        let remaining = pending.filter { !stagedPaths.contains($0.path) }
        if remaining.isEmpty { return ([staged], try sequencePeak([staged], plan: plan, state: state, fs: fs, limit: maxConcurrentObjects, pipeline: pipeline)) }
        let indexes = Dictionary(uniqueKeysWithValues: remaining.enumerated().map { (batchPathKey($0.element.path), $0.offset) })
        var ends = Array(remaining.indices)
        for (index, file) in remaining.enumerated() {
            for extent in file.extents {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                if case .local(let source, _) = extent.source, extent.fallbackChunkID == nil {
                    if let earlier = indexes[batchPathKey(source)], earlier < index { ends[earlier] = max(ends[earlier], index) }
                    if stagedKeys.contains(batchPathKey(source)) { ends[0] = max(ends[0], index) }
                }
            }
        }
        var batches: [[FileTask]] = [], start = 0
        while start < remaining.count {
            var end = ends[start], cursor = start
            while cursor <= end { end = max(end, ends[cursor]); cursor += 1 }
            if start == 0, !staged.isEmpty {
                let selected = stagedPaths.union(remaining[start...end].map(\.path))
                batches.append(pending.filter { selected.contains($0.path) })
            } else { batches.append(Array(remaining[start...end])) }
            start = end + 1
        }
        let sequential = try sequencePeak(batches, plan: plan, state: state, fs: fs, limit: maxConcurrentObjects, pipeline: pipeline)
        let whole = try required(plan: plan, state: state, fs: fs, maxConcurrentObjects: maxConcurrentObjects, pipeline: pipeline).disk
        // Whole mode may avoid a fallback by preserving a local source until all
        // consumers stage. It is itself a valid single-batch partition.
        return whole < sequential ? ([pending], whole) : (batches, sequential)
    }

    package static func minimumBatchedPreflight(plan: InstallPlan, state: JournalState, fs: ContainedFileSystem, maxConcurrentObjects: Int = defaultMaxConcurrentObjects, pipeline: PipelineConfiguration = .default) throws -> Int64 {
        try batchedPreflight(plan: plan, state: state, fs: fs, available: Int64.max, maxConcurrentObjects: maxConcurrentObjects, pipeline: pipeline).required
    }

    private static func sequencePeak(_ batches: [[FileTask]], plan: InstallPlan, state: JournalState,
        fs: ContainedFileSystem, limit: Int, pipeline: PipelineConfiguration) throws -> Int64 {
        let layout = StagingLayout(id: plan.id)
        var first: [String: Int] = [:], last: [String: Int] = [:], costs: [String: Int64] = [:]
        for (index, batch) in batches.enumerated() {
            for file in batch {
                for id in references(file) {
                    if first[id] == nil { first[id] = index }
                    last[id] = index
                }
            }
        }
        for id in first.keys {
            let object = plan.objects[id]!
            let resident = try state.verifiedObjects.contains(id) && fs.size(at: layout.object(object)) == object.transferSize
            costs[id] = resident ? 0 : object.transferSize
        }
        var growth: Int64 = 0, peak = margin, decoded: Int64 = 0, largestBatchParts: Int64 = 0
        // Lifetime events avoid scanning every object at every batch.
        var newParts = Array(repeating: [String](), count: batches.count)
        var expiredParts = newParts
        for id in first.keys {
            newParts[first[id]!].append(id)
            expiredParts[last[id]!].append(id)
        }
        for (index, batch) in batches.enumerated() {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            let newCosts = Dictionary(uniqueKeysWithValues: newParts[index].map { ($0, costs[$0]!) })
            let retained = Set(newParts[index].filter { last[$0]! > index })
            var allocation = PeakAllocation(limit: limit, retainedObjects: retained, pipeline: pipeline)
            for file in batch where !state.stagedFiles.contains(file.path) { try allocation.append(file, costs: newCosts) }
            let batchDecoded = try batch.filter { !state.stagedFiles.contains($0.path) }.reduce(Int64(0)) { try adding($0, $1.size) }
            let batchPeak = try allocation.disk()
            decoded = try adding(decoded, batchDecoded)
            largestBatchParts = max(largestBatchParts, batchPeak - batchDecoded - margin)
            peak = max(peak, try adding(growth, batchPeak))
            for file in batch {
                if !state.stagedFiles.contains(file.path) { growth = try adding(growth, file.size) }
                // Never assume an unlink releases destination blocks: APFS
                // clones and snapshots can retain them despite st_nlink == 1.
                // Only the live disk probe may report that capacity as freed.
            }
            for id in newParts[index] { growth = try adding(growth, costs[id]!) }
            for id in expiredParts[index] { growth -= costs[id]! }
        }
        peak = max(peak, try adding(adding(decoded, largestBatchParts), margin))
        return peak
    }

    private static func batchPathKey(_ path: SafeRelativePath) -> String {
        path.description.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }
}
