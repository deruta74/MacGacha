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
    public var verified: Bool
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
        }
        for version in state.declinedGraphicsVersions { _ = try SafeIdentifier(version) }
        return state
    }

    public func retain(familyID: String, previousID: String, replacementID: String) throws {
        _ = try SafeIdentifier(familyID); _ = try SafeIdentifier(previousID); _ = try SafeIdentifier(replacementID)
        try mutate { state in
            guard !state.replacements.contains(where: { $0.familyID == familyID && $0.previousID == previousID && $0.replacementID == replacementID }) else { return }
            guard state.replacements.count < 128 else { throw catalogError("Too many retained automatic versions") }
            state.replacements.append(.init(id: UUID(), familyID: familyID, previousID: previousID, replacementID: replacementID, verified: false))
        }
    }

    /// Only called after normal, verified end of a session that reached running.
    /// Qualifies predecessors in the same replacement chain as well.
    public func recordVerifiedSession(bundleID: String, componentIDs: [String]) throws {
        try mutate { state in
            var proven = Set(state.replacements.filter { record in
                record.familyID.hasPrefix("bundle-") ? record.replacementID == bundleID : componentIDs.contains(record.replacementID)
            }.map(\.id))
            var changed = true
            while changed {
                changed = false
                for record in state.replacements where !proven.contains(record.id) {
                    if state.replacements.contains(where: { proven.contains($0.id) && $0.familyID == record.familyID && $0.previousID == record.replacementID }) {
                        proven.insert(record.id); changed = true
                    }
                }
            }
            for index in state.replacements.indices where proven.contains(state.replacements[index].id) { state.replacements[index].verified = true }
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
