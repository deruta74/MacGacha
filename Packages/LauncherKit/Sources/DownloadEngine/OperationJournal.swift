// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).

import Dispatch
import Foundation
import LauncherCore

public enum JournalRecord: Codable, Sendable, Equatable {
    case planStored(planID: SafeIdentifier, planDigest: Digest)
    case operationStarted
    case objectVerified(id: String)
    case fileStaged(path: SafeRelativePath)
    case fileUnstaged(path: SafeRelativePath)
    case batchStarted(index: Int)
    case commitStarted(batch: Int)
    case fileCommitted(path: SafeRelativePath)
    case fileDeleted(path: SafeRelativePath)
    case operationCompleted

    private enum CodingKeys: String, CodingKey { case type, planID, planDigest, id, path, index, batch }
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private var allowedKeys: Set<String> {
        switch self {
        case .planStored: ["type", "planID", "planDigest"]
        case .objectVerified: ["type", "id"]
        case .fileStaged, .fileUnstaged, .fileCommitted, .fileDeleted: ["type", "path"]
        case .batchStarted: ["type", "index"]
        case .commitStarted: ["type", "batch"]
        case .operationStarted, .operationCompleted: ["type"]
        }
    }

    public init(from decoder: any Decoder) throws {
        do {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "planStored":
                self = .planStored(planID: try c.decode(SafeIdentifier.self, forKey: .planID),
                    planDigest: try c.decode(Digest.self, forKey: .planDigest))
            case "operationStarted": self = .operationStarted
            case "objectVerified": self = .objectVerified(id: try c.decode(String.self, forKey: .id))
            case "fileStaged": self = .fileStaged(path: try c.decode(SafeRelativePath.self, forKey: .path))
            case "fileUnstaged": self = .fileUnstaged(path: try c.decode(SafeRelativePath.self, forKey: .path))
            case "batchStarted": self = .batchStarted(index: try c.decode(Int.self, forKey: .index))
            case "commitStarted": self = .commitStarted(batch: try c.decode(Int.self, forKey: .batch))
            case "fileCommitted": self = .fileCommitted(path: try c.decode(SafeRelativePath.self, forKey: .path))
            case "fileDeleted": self = .fileDeleted(path: try c.decode(SafeRelativePath.self, forKey: .path))
            case "operationCompleted": self = .operationCompleted
            default: throw LauncherError.journalCorrupt("Unknown journal record type")
            }
            let keys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
            guard Set(keys) == allowedKeys else { throw LauncherError.journalCorrupt("Unexpected journal record keys") }
            try validate()
        } catch LauncherError.journalCorrupt(let reason) {
            throw LauncherError.journalCorrupt(reason)
        } catch {
            throw LauncherError.journalCorrupt("Invalid journal record")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .planStored(let id, let digest):
            try c.encode("planStored", forKey: .type)
            try c.encode(id, forKey: .planID)
            try c.encode(digest, forKey: .planDigest)
        case .operationStarted: try c.encode("operationStarted", forKey: .type)
        case .objectVerified(let id):
            try c.encode("objectVerified", forKey: .type)
            try c.encode(id, forKey: .id)
        case .fileStaged(let path):
            try c.encode("fileStaged", forKey: .type)
            try c.encode(path, forKey: .path)
        case .fileUnstaged(let path):
            try c.encode("fileUnstaged", forKey: .type)
            try c.encode(path, forKey: .path)
        case .batchStarted(let index):
            try c.encode("batchStarted", forKey: .type)
            try c.encode(index, forKey: .index)
        case .commitStarted(let batch):
            try c.encode("commitStarted", forKey: .type)
            try c.encode(batch, forKey: .batch)
        case .fileCommitted(let path):
            try c.encode("fileCommitted", forKey: .type)
            try c.encode(path, forKey: .path)
        case .fileDeleted(let path):
            try c.encode("fileDeleted", forKey: .type)
            try c.encode(path, forKey: .path)
        case .operationCompleted: try c.encode("operationCompleted", forKey: .type)
        }
    }

    private func validate() throws {
        switch self {
        case .batchStarted(let index), .commitStarted(let index):
            guard index >= 0 else { throw LauncherError.journalCorrupt("Negative batch index") }
        case .objectVerified(let id):
            guard !id.isEmpty, id.utf8.count <= ChunkObject.maximumIDBytes else {
                throw LauncherError.journalCorrupt("Invalid object id")
            }
        default: break
        }
    }
}

public struct JournalState: Sendable, Equatable {
    public private(set) var planID: SafeIdentifier?
    public private(set) var planDigest: Digest?
    public private(set) var verifiedObjects: Set<String> = []
    public private(set) var stagedFiles: Set<SafeRelativePath> = []
    public private(set) var currentBatch: Int?
    public private(set) var committedFiles: Set<SafeRelativePath> = []
    public private(set) var deletedFiles: Set<SafeRelativePath> = []
    public private(set) var commitStartedBatches: Set<Int> = []
    public private(set) var completed = false
    // Replay-derived membership survives fileUnstaged after commitStarted. No new wire record.
    package private(set) var batchFiles: Set<SafeRelativePath> = []

    public init() {}

    fileprivate func validateTransition(_ record: JournalRecord) throws {
        guard !completed else { throw LauncherError.journalCorrupt("Record after operationCompleted") }
        if case .planStored(let id, let digest) = record {
            guard planID == nil || (planID == id && planDigest == digest) else {
                throw LauncherError.journalCorrupt("Conflicting planStored")
            }
        } else if planID == nil { throw LauncherError.journalCorrupt("Record before planStored") }
        if case .commitStarted(let batch) = record, currentBatch != batch {
            throw LauncherError.journalCorrupt("commitStarted without batchStarted")
        }
    }

    package mutating func apply(_ record: JournalRecord) throws {
        try validateTransition(record)
        switch record {
        case .planStored(let id, let digest): planID = id; planDigest = digest
        case .operationStarted: break
        case .objectVerified(let id): verifiedObjects.insert(id)
        case .fileStaged(let path): stagedFiles.insert(path)
        case .fileUnstaged(let path): stagedFiles.remove(path)
        case .batchStarted(let index):
            currentBatch = index
            batchFiles = stagedFiles.subtracting(committedFiles)
        case .commitStarted(let batch):
            commitStartedBatches.insert(batch)
        case .fileCommitted(let path): committedFiles.insert(path)
        case .fileDeleted(let path): deletedFiles.insert(path)
        case .operationCompleted: completed = true
        }
    }
}

/// A single-writer JSON Lines journal. Callers hold the install-root lock (Task 6)
/// for its lifetime; separate instances do not coordinate writes to the same path.
/// Expected size is linear in plan objects/files/deletions plus staging retries: roughly
/// one object record, two file records and one record per deletion, with batch boundaries.
/// Large plans can produce hundreds of MiB. Replay streams records; no compaction yet.
/// Completed journals are removed with staging. Retry history has no fixed total cap.
public actor OperationJournal {
    /// A complete encoded record may occupy at most 1 MiB, excluding its newline.
    /// Replay streams the file; a torn tail of any size is discarded without buffering it all.
    public static let maximumRecordBytes = 1_048_576

    nonisolated let ioQueue = DispatchSerialQueue(label: "org.macgacha.operation-journal")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { ioQueue.asUnownedSerialExecutor() }
    public nonisolated let recoveredState: JournalState
    private var currentState: JournalState

    private let fs: ContainedFileSystem
    private let path: SafeRelativePath
    private let synchronize: ContainedFileSystem.FileSynchronizer?
    private let crashHooks: CrashHooks
    private var needsRecovery = false

    public init(fs: ContainedFileSystem, path: SafeRelativePath,
        synchronize: ContainedFileSystem.FileSynchronizer? = nil, crashHooks: CrashHooks = .none) throws {
        self.fs = fs
        self.path = path
        self.synchronize = synchronize
        self.crashHooks = crashHooks
        if try fs.itemType(at: path) == nil {
            try fs.append(Data(), to: path, durable: true, synchronize: synchronize)
            recoveredState = JournalState()
        } else {
            let result = try Self.scan(fs: fs, path: path)
            try fs.truncateFile(at: path, toByteCount: result.validBytes, synchronize: synchronize)
            recoveredState = result.state
        }
        currentState = recoveredState
    }

    /// Batch/commit boundaries and completion always use F_FULLFSYNC; other records use fsync.
    /// Once writing starts cancellation is deferred until the record has been synchronized.
    /// If append throws after writing any bytes, the record is possibly written: reopen
    /// and use recoveredState as the source of truth before proceeding.
    public func append(_ record: JournalRecord) throws {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard !needsRecovery else { throw LauncherError.journalCorrupt("Reopen journal after failed append") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var bytes = try encoder.encode(record)
        guard bytes.count <= Self.maximumRecordBytes else { throw Self.oversizedRecord() }
        try currentState.validateTransition(record)
        bytes.append(0x0a)
        let durable = switch record {
        case .batchStarted, .commitStarted, .operationCompleted: true
        default: false
        }
        var written = 0
        do {
            // Only explicit harness injection splits a fileCommitted line at the rename gap.
            if case .fileCommitted = record, crashHooks.enabled(.midJournalWrite) {
                let split = bytes.count / 2
                try fs.append(Data(bytes.prefix(split)), to: path, synchronize: synchronize, didWrite: { written += $0 })
                crashHooks.reach(.midJournalWrite)
                try fs.append(Data(bytes.dropFirst(split)), to: path, durable: durable, synchronize: synchronize, didWrite: { written += $0 })
            } else {
                try fs.append(bytes, to: path, durable: durable, synchronize: synchronize, didWrite: { written += $0 })
            }
        } catch {
            needsRecovery = written > 0
            throw error
        }
        try currentState.apply(record)
    }

    package func snapshot() throws -> JournalState {
        guard !needsRecovery else { throw LauncherError.journalCorrupt("Reopen journal after failed append") }
        return try Self.replay(fs: fs, path: path)
    }

    /// Replays complete LF-terminated records without modifying the file. Missing is empty;
    /// unterminated or syntactically torn final records are ignored. Semantic errors and
    /// invalid lines followed by nonzero bytes remain corruption.
    public static func replay(fs: ContainedFileSystem, path: SafeRelativePath) throws -> JournalState {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard try fs.itemType(at: path) != nil else { return JournalState() }
        return try scan(fs: fs, path: path).state
    }

    private static func scan(fs: ContainedFileSystem, path: SafeRelativePath) throws -> (state: JournalState, validBytes: Int64) {
        var state = JournalState()
        var pending = Data()
        var oversized = false
        var damagedTail = false
        var position: Int64 = 0
        var validBytes: Int64 = 0
        let decoder = JSONDecoder()
        try fs.readFile(at: path, chunkSize: 65_536) { chunk in
            if damagedTail {
                guard chunk.allSatisfy({ $0 == 0 }) else { throw LauncherError.journalCorrupt("Invalid mid-file journal record") }
                return
            }
            var start = chunk.startIndex
            while let newline = chunk[start...].firstIndex(of: 0x0a) {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                let fragment = chunk[start..<newline]
                guard !oversized, fragment.count <= maximumRecordBytes - pending.count else { throw oversizedRecord() }
                pending.append(fragment)
                let record: JournalRecord
                do { record = try decoder.decode(JournalRecord.self, from: pending) }
                catch let error as LauncherError { throw error }
                catch {
                    guard chunk[chunk.index(after: newline)...].allSatisfy({ $0 == 0 }) else {
                        throw LauncherError.journalCorrupt("Invalid complete journal record")
                    }
                    damagedTail = true
                    return
                }
                try state.apply(record)
                position += Int64(fragment.count) + 1
                validBytes = position
                pending.removeAll(keepingCapacity: true)
                start = chunk.index(after: newline)
            }
            let tail = chunk[start...]
            if !oversized {
                if tail.count > maximumRecordBytes - pending.count {
                    oversized = true
                    pending.removeAll(keepingCapacity: false)
                } else { pending.append(tail) }
            }
            position += Int64(tail.count)
        }
        return (state, validBytes)
    }

    private static func oversizedRecord() -> LauncherError {
        .journalCorrupt("Journal record exceeds \(maximumRecordBytes) bytes")
    }
}
