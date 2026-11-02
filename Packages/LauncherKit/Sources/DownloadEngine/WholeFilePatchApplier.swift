// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

/// Delivery adapters supply their decoder without reversing the engine's module
/// dependency. Output writes must use fs.fileOps to retain allocation barriers.
public protocol WholeFilePatchApplier: Sendable {
    func apply(source: SafeRelativePath, sourceSize: Int64, container: SafeRelativePath, offset: Int64, length: Int64,
        expectedSize: Int64, fs: ContainedFileSystem, output: FileHandle) async throws
}

package struct RecipeFallback: Error { let reason: String }

package enum FileRecipeAssembler {
    @concurrent static func sourceMatches(_ recipe: FileRecipe, fs: ContainedFileSystem) async throws -> Bool {
        try await BlockingIO.run {
            guard case .patch(let source, let size, let digest, _, _, _) = recipe else { return true }
            guard try fs.size(at: source) == size else { return false }
            return try LocalRange.matches(path: source, offset: 0, length: size, digest: digest, fs: fs)
        }
    }

    @concurrent static func assemble(_ file: FileTask, plan: InstallPlan, fs: ContainedFileSystem,
        applier: (any WholeFilePatchApplier)?, durable: Bool) async throws {
        try await BlockingIO.run {
            guard let recipe = file.recipe, let object = plan.objects[recipe.containerID] else { throw LauncherError.io("Missing recipe") }
            let layout = StagingLayout(id: plan.id), part = try layout.object(object), path = try layout.file(file.path)
            guard try await ChunkFetcher.verifiedPart(object, fs: fs, part: part) else {
                throw AssemblyBadObject(id: object.id, cause: LauncherError.digestMismatch(path: "patch container", expected: object.decodedDigest.hex, actual: "invalid"))
            }
            let output = try fs.openForWriting(at: path, truncate: true)
            defer { try? output.close() }
            do {
                switch recipe {
                case .patch(let source, let size, _, _, let offset, let length):
                    guard let applier else { throw LauncherError.unsupportedCompressor }
                    try await applier.apply(source: source, sourceSize: size, container: part, offset: offset, length: length,
                        expectedSize: file.size, fs: fs, output: output)
                case .copy(_, let offset, let length):
                    let input = try fs.openForReading(at: part)
                    defer { try? input.close() }
                    try input.seek(toOffset: UInt64(offset))
                    var remaining = length
                    while remaining > 0 {
                        try Task.checkCancellation()
                        let bytes = try input.read(upToCount: Int(min(65_536, remaining))) ?? Data()
                        guard !bytes.isEmpty else { throw LauncherError.sizeMismatch(path: "patch slice", expected: length, actual: length - remaining) }
                        try fs.fileOps.writeAll(bytes, to: output.fileDescriptor)
                        remaining -= Int64(bytes.count)
                    }
                }
                guard try await FileAssembler.matches(file, plan: plan, fs: fs) else {
                    throw LauncherError.digestMismatch(path: "patch output", expected: file.digest.hex, actual: "invalid")
                }
                try fs.synchronizeFile(at: path, durable: durable)
            } catch let error as LauncherError {
                switch error {
                case .malformedPatch, .unsupportedCompressor, .sizeMismatch, .digestMismatch, .io:
                    throw RecipeFallback(reason: error.logCase)
                default: throw error
                }
            }
        }
    }
}
