// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import LauncherCore

/// A whole-file primary recipe. FileTask.extents always retain the immutable
/// chunk/local fallback, so execution and resume never need to replan.
public enum FileRecipe: Codable, Sendable, Hashable {
    case patch(source: SafeRelativePath, sourceSize: Int64, sourceDigest: Digest, container: String, offset: Int64, length: Int64)
    case copy(container: String, offset: Int64, length: Int64)

    public var containerID: String {
        switch self {
        case .patch(_, _, _, let container, _, _), .copy(let container, _, _): container
        }
    }
    package var sourcePath: SafeRelativePath? {
        if case .patch(let source, _, _, _, _, _) = self { source } else { nil }
    }
    package var slice: (offset: Int64, length: Int64) {
        switch self {
        case .patch(_, _, _, _, let offset, let length), .copy(_, let offset, let length): (offset, length)
        }
    }
}
