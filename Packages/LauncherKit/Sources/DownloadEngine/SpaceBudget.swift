// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

public enum SpaceBudget {
    public static let margin: Int64 = 1 << 30

    public static func required(plan: InstallPlan, state: JournalState, fs: ContainedFileSystem) throws -> (disk: Int64, network: Int64) {
        let budget = try estimate(plan: plan, state: state, fs: fs)
        return (budget.disk, budget.network)
    }

    /// Returns the same transfer set used for the byte totals, without re-reading local ranges.
    package static func estimate(plan: InstallPlan, state: JournalState, fs: ContainedFileSystem) throws -> (disk: Int64, network: Int64, objects: Set<String>) {
        try plan.validate()
        let remaining = try remainingFiles(plan: plan, state: state, fs: fs)
        let objects = try networkObjectIDs(files: remaining, plan: plan, state: state, fs: fs)
        let network = try transferBytes(objects: objects, plan: plan)
        let staged = try remaining.reduce(Int64(0)) { try adding($0, $1.size) }
        return (try adding(adding(staged, network), margin), network, objects)
    }

    public static func requiredLargestFile(plan: InstallPlan, state: JournalState, fs: ContainedFileSystem) throws -> Int64 {
        try plan.validate()
        var largest: Int64 = 0
        for file in try remainingFiles(plan: plan, state: state, fs: fs) {
            let objects = try networkObjectIDs(files: [file], plan: plan, state: state, fs: fs)
            let network = try transferBytes(objects: objects, plan: plan)
            largest = max(largest, try adding(file.size, network))
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

    private static func transferBytes(objects: Set<String>, plan: InstallPlan) throws -> Int64 {
        var bytes: Int64 = 0
        for id in objects {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            guard let object = plan.objects[id] else { throw LauncherError.io("Missing plan object") }
            bytes = try adding(bytes, object.transferSize)
        }
        return bytes
    }

    /// Fallback references retain objects, but only unusable local ranges require transfer space.
    private static func networkObjectIDs(files: [FileTask], plan: InstallPlan, state: JournalState, fs: ContainedFileSystem) throws -> Set<String> {
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
