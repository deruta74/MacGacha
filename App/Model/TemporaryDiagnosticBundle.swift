// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

/// Only complete, bounded files cross the model's export boundary. Every file operation runs off-main.
enum TemporaryDiagnosticBundle {
    private static let byteLimit = 64 << 20

    @concurrent static func make(export: @escaping @Sendable (URL) async throws -> Void) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
        let name = try SafeRelativePath("MacGacha-Diagnostics-\(UUID().uuidString).zip")
        let url = name.resolved(against: directory)
        let fs = try ContainedFileSystem(root: directory)
        do {
            try Task.checkCancellation()
            try await export(url)
            try Task.checkCancellation()
            guard try fs.itemType(at: name) == .regularFile, let size = try fs.size(at: name), size > 0 else {
                throw LauncherError.io("Diagnostics export produced no bundle")
            }
            guard size <= byteLimit else { throw LauncherError.fileTooLarge(path: "diagnostics", limit: byteLimit) }
            return url
        } catch {
            await discard(url)
            throw launcherError(error)
        }
    }

    @concurrent static func publish(_ complete: URL, to destination: URL) async throws {
        guard destination.isFileURL else { throw LauncherError.unsafePath("diagnostics destination") }
        let source = try ContainedFileSystem(root: complete.deletingLastPathComponent())
        let bytes = try source.readFile(at: SafeRelativePath(complete.lastPathComponent), maxBytes: byteLimit)
        guard !bytes.isEmpty else { throw LauncherError.io("Diagnostics export produced no bundle") }
        let target = try ContainedFileSystem(root: destination.deletingLastPathComponent())
        try target.writeAtomically(bytes, to: SafeRelativePath(destination.lastPathComponent))
    }

    static func discard(_ file: URL) async {
        // Failure/cancellation must still clean up a partially written temporary bundle.
        await Task.detached {
            let fs = try? ContainedFileSystem(root: file.deletingLastPathComponent())
            if let path = try? SafeRelativePath(file.lastPathComponent) { try? fs?.removeFile(at: path) }
        }.value
    }
}
