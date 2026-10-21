// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

public enum SpaceBudget {
    public static let margin: Int64 = 1 << 30
    public static let defaultMaxConcurrentObjects = 8

    public static func required(plan: InstallPlan, state: JournalState, fs: ContainedFileSystem,
        maxConcurrentObjects: Int = defaultMaxConcurrentObjects) throws -> (disk: Int64, network: Int64) {
        let budget = try estimate(plan: plan, state: state, fs: fs, maxConcurrentObjects: maxConcurrentObjects)
        return (budget.disk, budget.network)
    }

    /// Returns the same transfer set used for the byte totals, without re-reading local ranges.
    package static func estimate(plan: InstallPlan, files: [FileTask]? = nil, state: JournalState, fs: ContainedFileSystem,
        maxConcurrentObjects: Int = defaultMaxConcurrentObjects) throws -> (disk: Int64, network: Int64, objects: Set<String>) {
        // Budgeting uses byte sizes independently of decoder availability; installation preflights codecs.
        try plan.validate(supportedCodecs: Set(ChunkCodec.allCases))
        let outstanding = try remainingFiles(plan: plan, state: state, fs: fs)
        let requested = files.map { Set($0.map(\.path)) }
        let remaining = outstanding.filter { requested?.contains($0.path) ?? true }
        let selected = Set(remaining.map(\.path))
        var external = Set<String>()
        for file in outstanding where !selected.contains(file.path) { external.formUnion(references(file)) }
        let objects = try networkObjectIDs(files: remaining, plan: plan, state: state, fs: fs)
        let network = try transferBytes(objects: objects, plan: plan)
        let costs = Dictionary(uniqueKeysWithValues: objects.map { ($0, plan.objects[$0]!.transferSize) })
        var allocation = PeakAllocation(limit: maxConcurrentObjects, retainedObjects: external)
        for file in remaining { try allocation.append(file, costs: costs) }
        return (try allocation.disk(), network, objects)
    }

    public static func requiredLargestFile(plan: InstallPlan, state: JournalState, fs: ContainedFileSystem,
        maxConcurrentObjects: Int = defaultMaxConcurrentObjects) throws -> Int64 {
        // Budgeting uses byte sizes independently of decoder availability; installation preflights codecs.
        try plan.validate(supportedCodecs: Set(ChunkCodec.allCases))
        var largest: Int64 = 0
        for file in try remainingFiles(plan: plan, state: state, fs: fs) {
            let objects = try networkObjectIDs(files: [file], plan: plan, state: state, fs: fs)
            let costs = Dictionary(uniqueKeysWithValues: objects.map { ($0, plan.objects[$0]!.transferSize) })
            var allocation = PeakAllocation(limit: maxConcurrentObjects)
            try allocation.append(file, costs: costs)
            largest = max(largest, try allocation.disk() - margin)
        }
        return try adding(largest, margin)
    }

    package static func remainingFiles(plan: InstallPlan, state: JournalState, fs: ContainedFileSystem) throws -> [FileTask] {
        let layout = StagingLayout(id: plan.id)
        return try plan.files.filter { file in
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            if state.committedFiles.contains(file.path) { return false }
            if !state.stagedFiles.contains(file.path) { return true }
            return try fs.size(at: layout.file(file.path)) != file.size
        }
    }

    package static func transferBytes(objects: Set<String>, plan: InstallPlan) throws -> Int64 {
        var bytes: Int64 = 0
        for id in objects {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            guard let object = plan.objects[id] else { throw LauncherError.io("Missing plan object") }
            bytes = try adding(bytes, object.transferSize)
        }
        return bytes
    }

    /// Fallback references retain objects, but only unusable local ranges require transfer space.
    package static func networkObjectIDs(files: [FileTask], plan: InstallPlan, state: JournalState, fs: ContainedFileSystem) throws -> Set<String> {
        let layout = StagingLayout(id: plan.id)
        var needed = Set<String>()
        for file in files {
            for extent in file.extents {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                switch extent.source {
                case .chunk(let id): needed.insert(id)
                case .local(let path, let offset):
                    if let fallback = extent.fallbackChunkID,
                        try !LocalRange.matches(path: path, offset: offset, length: extent.length, digest: extent.digest, fs: fs) {
                        needed.insert(fallback)
                    }
                }
            }
        }
        return try Set(needed.filter { id in
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            guard let object = plan.objects[id] else { throw LauncherError.io("Missing plan object") }
            if state.verifiedObjects.contains(id), try fs.size(at: layout.object(object)) == object.transferSize { return false }
            return true
        })
    }

    package static func references(_ file: FileTask) -> Set<String> {
        var ids = Set<String>()
        for extent in file.extents {
            if case .chunk(let id) = extent.source { ids.insert(id) }
            if let fallback = extent.fallbackChunkID { ids.insert(fallback) }
        }
        return ids
    }

    /// Additional allocation, excluding parts already on disk. Files stage in
    /// order; shared objects survive until their last referrer. All direct parts
    /// of one file are prefetched before assembly, and fallback parts can join
    /// them during assembly. Thus concurrency alone is not a live-part cap.
    /// The part reserve is bounded by all needed parts, and otherwise by shared
    /// parts plus the larger of the in-flight and per-file retained-part bounds.
    package struct PeakAllocation {
        let limit: Int
        private let retainedObjects: Set<String>
        private var decoded: Int64 = 0, parts: Int64 = 0, shared: Int64 = 0
        private var largestObject: Int64 = 0, largestFileParts: Int64 = 0
        private var counts: [String: Int] = [:]

        package init(limit: Int = defaultMaxConcurrentObjects, retainedObjects: Set<String> = []) {
            self.limit = limit; self.retainedObjects = retainedObjects
        }
        package mutating func append(_ file: FileTask, costs: [String: Int64]) throws {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            decoded = try adding(decoded, file.size)
            var fileParts: Int64 = 0
            for id in references(file) {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                let cost = costs[id] ?? 0
                fileParts = try adding(fileParts, cost)
                let previous = counts[id, default: 0]
                if previous == 0 {
                    parts = try adding(parts, cost); largestObject = max(largestObject, cost)
                    if retainedObjects.contains(id) { shared = try adding(shared, cost) }
                }
                if previous == 1 && !retainedObjects.contains(id) { shared = try adding(shared, cost) }
                counts[id] = previous + 1
            }
            largestFileParts = max(largestFileParts, fileParts)
        }
        package func disk() throws -> Int64 {
            try peakDisk(decoded: decoded, parts: parts, shared: shared,
                largestObject: largestObject, largestFileParts: largestFileParts, limit: limit)
        }
    }

    package static func peakDisk(decoded: Int64, parts: Int64, shared: Int64,
        largestObject: Int64, largestFileParts: Int64, limit: Int) throws -> Int64 {
        guard limit > 0 else { throw LauncherError.io("Invalid object concurrency limit") }
        let (flight, overflow) = largestObject.multipliedReportingOverflow(by: Int64(limit))
        let inFlight = min(parts - shared, overflow ? Int64.max : flight)
        let (combined, combinedOverflow) = shared.addingReportingOverflow(max(inFlight, largestFileParts))
        let retained = combinedOverflow ? parts : min(parts, combined)
        return try adding(adding(decoded, retained), margin)
    }

    package static func adding(_ a: Int64, _ b: Int64) throws -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw LauncherError.io("Space budget overflow") }
        return sum
    }
}

package struct StagingLayout: Sendable {
    let id: SafeIdentifier
    func file(_ path: SafeRelativePath) throws -> SafeRelativePath { try SafeRelativePath(".macgacha-staging/\(id)/files/\(path)") }
    func object(_ object: ChunkObject) throws -> SafeRelativePath { try SafeRelativePath(".macgacha-staging/\(id)/objects/\(object.partFileName)") }
}
