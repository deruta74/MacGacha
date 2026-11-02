// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine

public struct HDiff13PatchApplier: WholeFilePatchApplier {
    public init() {}
    public func apply(source: SafeRelativePath, sourceSize: Int64, container: SafeRelativePath, offset: Int64, length: Int64,
        expectedSize: Int64, fs: ContainedFileSystem, output: FileHandle) async throws {
        try await HDiff13.apply(old: HDiff13.FileRange(fileSystem: fs, path: source, length: sourceSize),
            patch: HDiff13.FileRange(fileSystem: fs, path: container, offset: offset, length: length),
            expectedSize: expectedSize, output: output, fileOps: fs.fileOps)
    }
}
