// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import LauncherCore

/// Called under install ownership, after the immutable plan has been persisted.
/// True means size/digest verified and moved without a second payload allocation.
public protocol InstallObjectCache: Sendable {
    func adopt(_ object: ChunkObject, to destination: SafeRelativePath, fs: ContainedFileSystem) async throws -> Bool
}
