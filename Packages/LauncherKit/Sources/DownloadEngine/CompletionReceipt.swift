// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

/// Durable engine completion, retained until the owning game record acknowledges it.
public struct CompletionReceipt: Codable, Sendable, Equatable {
    public let planID: SafeIdentifier
    public let planDigest: Digest

    public init(planID: SafeIdentifier, planDigest: Digest) {
        self.planID = planID; self.planDigest = planDigest
    }

    private enum CodingKeys: String, CodingKey { case planID, planDigest }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        planID = try values.decode(SafeIdentifier.self, forKey: .planID)
        planDigest = try values.decode(Digest.self, forKey: .planDigest)
        guard planDigest.algorithm == .sha256 else { throw LauncherError.journalCorrupt("Invalid completion receipt") }
    }

    public static func load(installRoot: URL, planID: SafeIdentifier) throws -> Self? {
        try load(fs: ContainedFileSystem(root: installRoot), planID: planID)
    }

    public static func acknowledge(installRoot: URL, planID: SafeIdentifier) throws {
        try acknowledge(fs: ContainedFileSystem(root: installRoot), planID: planID)
    }
    package static func acknowledge(fs: ContainedFileSystem, planID: SafeIdentifier) throws {
        try fs.removeFile(at: path(planID))
    }

    package static func load(fs: ContainedFileSystem, planID: SafeIdentifier) throws -> Self? {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        let path = try path(planID)
        guard try fs.itemType(at: path) != nil else { return nil }
        let data = try fs.readFile(at: path, maxBytes: 4096)
        do {
            let receipt = try JSONDecoder().decode(Self.self, from: data)
            guard receipt.planID == planID else { throw LauncherError.journalCorrupt("Invalid completion receipt") }
            return receipt
        } catch { throw LauncherError.journalCorrupt("Invalid completion receipt") }
    }

    func write(fs: ContainedFileSystem) throws {
        guard planDigest.algorithm == .sha256 else { throw LauncherError.journalCorrupt("Invalid completion receipt") }
        // The engine holds the root lock, so none of these are active writes.
        try Self.discardInterruptedWrites(fs: fs)
        if let existing = try Self.load(fs: fs, planID: planID), existing != self {
            throw LauncherError.journalCorrupt("Completion receipt digest mismatch")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try fs.writeAtomically(encoder.encode(self), to: Self.path(planID))
    }

    /// Bounded discovery lets reconciliation acknowledge a receipt even if the
    /// process died after deleting the library's stored plan.
    package static func unacknowledged(installRoot: URL) throws -> [Self] {
        try unacknowledged(fs: ContainedFileSystem(root: installRoot))
    }
    package static func unacknowledged(fs: ContainedFileSystem) throws -> [Self] {
        let directory = try SafeRelativePath(".macgacha-receipts")
        guard let type = try fs.itemType(at: directory) else { return [] }
        guard type == .directory else { throw LauncherError.journalCorrupt("Invalid completion receipt directory") }
        let paths = try fs.contentsOfDirectory(at: directory).filter { !isAtomicTemporary($0) }
        guard paths.count <= 64 else { throw LauncherError.journalCorrupt("Too many completion receipts") }
        return try paths.sorted(by: { $0.description < $1.description }).map { path in
            guard let name = path.components.last, name.hasSuffix(".json"),
                let id = try? SafeIdentifier(String(name.dropLast(5))),
                let receipt = try load(fs: fs, planID: id) else {
                throw LauncherError.journalCorrupt("Invalid completion receipt")
            }
            return receipt
        }
    }

    /// Finish the cleanup window after a crash, without downloading or running
    /// the plan again. The receipt proves the journal reached operationCompleted.
    package func finishCleanup(installRoot: URL) throws {
        try finishCleanup(fs: ContainedFileSystem(root: installRoot))
    }
    package func finishCleanup(fs: ContainedFileSystem) throws {
        let lock = try InstallLock(fs: fs, path: SafeRelativePath(".macgacha-staging/.lock"))
        defer { withExtendedLifetime(lock) {} }
        try Self.discardInterruptedWrites(fs: fs)
        try cleanupInstallStaging(planID: planID, fs: fs)
    }

    package static func discardInterruptedWrites(installRoot: URL) throws {
        let fs = try ContainedFileSystem(root: installRoot)
        guard try fs.itemType(at: SafeRelativePath(".macgacha-receipts")) != nil else { return }
        let lock = try InstallLock(fs: fs, path: SafeRelativePath(".macgacha-staging/.lock"))
        defer { withExtendedLifetime(lock) {} }
        try discardInterruptedWrites(fs: fs)
    }

    package static func discardInterruptedWrites(fs: ContainedFileSystem) throws {
        let directory = try SafeRelativePath(".macgacha-receipts")
        guard let type = try fs.itemType(at: directory) else { return }
        guard type == .directory else { throw LauncherError.journalCorrupt("Invalid completion receipt directory") }
        for path in try fs.contentsOfDirectory(at: directory) where isAtomicTemporary(path) {
            // removeFile accepts regular files only and never follows a leaf symlink.
            try fs.removeFile(at: path)
        }
    }

    private static func isAtomicTemporary(_ path: SafeRelativePath) -> Bool {
        guard let name = path.components.last, name.hasPrefix(".macgacha-write-") else { return false }
        return UUID(uuidString: String(name.dropFirst(".macgacha-write-".count))) != nil
    }

    private static func path(_ id: SafeIdentifier) throws -> SafeRelativePath {
        try SafeRelativePath(".macgacha-receipts/\(id).json")
    }
}

func cleanupInstallStaging(planID: SafeIdentifier, fs: ContainedFileSystem) throws {
    let marker = try InstallStateMarker.load(fs: fs)
    if marker == nil || marker?.planID == planID {
        try InstallStateMarker.clear(fs: fs, matching: planID)
    }
    // Retire the plan before recursive removal can delete its completion journal.
    try fs.removeFile(at: SafeRelativePath(".macgacha-staging/\(planID)/plan.json"))
    try fs.removeItem(at: SafeRelativePath(".macgacha-staging/\(planID)"))
}
