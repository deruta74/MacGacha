// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

/// Shared by downloaded archives and local GPTK imports. Callers retain the store
/// lock through preparation, publication, and cleanup of the swapped-out tree.
enum RuntimePublication {
    static func prepare(_ component: RuntimeComponent, fs: ContainedFileSystem, incoming: SafeRelativePath) throws {
        try fs.removeQuarantineRecursively(at: incoming)
        try fs.synchronizeTree(at: incoming)
        let marker = try InstalledComponent(kind: component.kind, version: component.version.rawValue,
            installedAt: Date(), source: component.sourceMode, archiveDigest: component.sha256)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let markerPath = try SafeRelativePath("\(incoming)/.macgacha-component.json")
        try fs.writeAtomically(encoder.encode(marker), to: markerPath)
        try fs.fullSync(at: markerPath)
    }

    static func publish(fs: ContainedFileSystem, incoming: SafeRelativePath, destination: SafeRelativePath,
        uncertain: inout Bool, failurePoint: @Sendable (ComponentInstaller.PublishPoint) throws -> Void) throws {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        try failurePoint(.beforePublish)
        uncertain = true
        try fs.publishDirectory(at: incoming, to: destination)
        uncertain = false
        try failurePoint(.afterPublish)
    }
}
