// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine

public struct RuntimeAutomaticReplacement: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let familyID: String
    public let previousID: String
    public let replacementID: String
    public var qualification: RuntimeAutomaticQualification?
    public var verified: Bool { qualification != nil }
}

public struct RuntimeAutomaticQualification: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let bundleID: String
    public let componentIDs: [String]
    public let confirmedRunningSeconds: Double
}

public struct RuntimeAutomaticUpdateState: Codable, Sendable {
    public var schemaVersion = 1
    public var replacements: [RuntimeAutomaticReplacement] = []
    public var declinedGraphicsVersions: Set<String> = []
}

/// Contained cross-process state shared by the app and verified launch finalization.
/// All methods perform blocking I/O. Async callers use BlockingIO.
public struct RuntimeAutomaticUpdateStore: Sendable {
    private let paths: AppPaths
    private let file = try! SafeRelativePath("RuntimeCatalog/automatic-updates.json")
    public init(paths: AppPaths) { self.paths = paths }

    public func load() throws -> RuntimeAutomaticUpdateState {
        let fs = try ContainedFileSystem(root: paths.root)
        guard try fs.itemType(at: file) != nil else { return RuntimeAutomaticUpdateState() }
        let state = try JSONDecoder().decode(RuntimeAutomaticUpdateState.self, from: fs.readFile(at: file, maxBytes: 1 << 20))
        guard state.schemaVersion == 1, state.replacements.count <= 128, state.declinedGraphicsVersions.count <= 256,
            Set(state.replacements.map(\.id)).count == state.replacements.count else { throw catalogError("Invalid automatic update state") }
        for record in state.replacements {
            _ = try SafeIdentifier(record.familyID); _ = try SafeIdentifier(record.previousID); _ = try SafeIdentifier(record.replacementID)
            if let proof = record.qualification {
                guard proof.confirmedRunningSeconds.isFinite, (120...31_536_000).contains(proof.confirmedRunningSeconds),
                    proof.componentIDs.count <= 64, Set(proof.componentIDs).count == proof.componentIDs.count else {
                    throw catalogError("Invalid automatic session qualification")
                }
                _ = try SafeIdentifier(proof.bundleID)
                for id in proof.componentIDs { _ = try SafeIdentifier(id) }
            }
        }
        for version in state.declinedGraphicsVersions { _ = try SafeIdentifier(version) }
        return state
    }

    public func retain(familyID: String, previousID: String, replacementID: String) throws {
        _ = try SafeIdentifier(familyID); _ = try SafeIdentifier(previousID); _ = try SafeIdentifier(replacementID)
        try mutate { state in
            // A new trial cannot reuse qualification from an earlier switch.
            for index in state.replacements.indices where state.replacements[index].familyID == familyID && state.replacements[index].previousID == previousID {
                state.replacements[index].qualification = nil
            }
            guard !state.replacements.contains(where: { $0.familyID == familyID && $0.previousID == previousID && $0.replacementID == replacementID }) else { return }
            guard state.replacements.count < 128 else { throw catalogError("Too many retained automatic versions") }
            state.replacements.append(.init(id: UUID(), familyID: familyID, previousID: previousID, replacementID: replacementID, qualification: nil))
        }
    }

    /// Only called after normal, verified end of a session that reached running.
    /// Qualifies predecessors in the same replacement chain as well.
    public func recordVerifiedSession(bundleID: String, componentIDs: [String], confirmedRunningSeconds: Double, sessionID: UUID) throws {
        guard confirmedRunningSeconds.isFinite, (120...31_536_000).contains(confirmedRunningSeconds) else { return }
        _ = try SafeIdentifier(bundleID)
        guard componentIDs.count <= 64, Set(componentIDs).count == componentIDs.count else { throw catalogError("Invalid session components") }
        for id in componentIDs { _ = try SafeIdentifier(id) }
        try mutate { state in
            let proof = RuntimeAutomaticQualification(sessionID: sessionID, bundleID: bundleID,
                componentIDs: componentIDs, confirmedRunningSeconds: confirmedRunningSeconds)
            for family in Set(state.replacements.map(\.familyID)).sorted() {
                let roots = family.hasPrefix("bundle-") ? [bundleID] : componentIDs
                for root in roots {
                    let records = state.replacements.filter { $0.familyID == family }
                    guard records.contains(where: { $0.replacementID == root }) else { continue }
                    var predecessors: Set<String> = [root]
                    var changed = true
                    while changed {
                        changed = false
                        for record in records where predecessors.contains(record.replacementID) {
                            if predecessors.insert(record.previousID).inserted { changed = true }
                        }
                    }
                    // Only real session proof collapses cycles and failed-intent
                    // branches. Pending activation must preserve the old lineage.
                    var emitted: Set<String> = []
                    state.replacements = state.replacements.compactMap { record in
                        guard record.familyID == family else { return record }
                        if record.previousID == root { return nil }
                        guard predecessors.contains(record.previousID) else { return record }
                        guard emitted.insert(record.previousID).inserted else { return nil }
                        return RuntimeAutomaticReplacement(id: record.id, familyID: family,
                            previousID: record.previousID, replacementID: root, qualification: proof)
                    }
                }
            }
        }
    }

    public func cancelCleanup(familyID: String) throws {
        try mutate { $0.replacements.removeAll { $0.familyID == familyID } }
    }
    public func removeReplacement(id: UUID) throws { try mutate { $0.replacements.removeAll { $0.id == id } } }
    public func declineGraphics(version: String) throws {
        _ = try SafeIdentifier(version)
        try mutate { state in
            guard state.declinedGraphicsVersions.count < 256 || state.declinedGraphicsVersions.contains(version) else { throw catalogError("Too many declined graphics versions") }
            state.declinedGraphicsVersions.insert(version)
        }
    }

    private func mutate(_ update: (inout RuntimeAutomaticUpdateState) throws -> Void) throws {
        let fs = try ContainedFileSystem(root: paths.root)
        try fs.createRootDurably(); try fs.createDirectory(at: SafeRelativePath("RuntimeCatalog"))
        let lock = try InstallLock(fs: fs, path: SafeRelativePath("RuntimeCatalog/.automatic-updates.lock"))
        defer { withExtendedLifetime(lock) {} }
        var state = try load()
        let previous = state
        try update(&state)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(state)
        if bytes != (try encoder.encode(previous)) { try fs.writeAtomically(bytes, to: file) }
    }
}
