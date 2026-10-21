// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

package enum LocalRange {
    /// Checks installed bytes without writing staging data or trusting metadata alone.
    static func matches(path: SafeRelativePath, offset: Int64, length: Int64, digest: Digest, fs: ContainedFileSystem) throws -> Bool {
        guard offset >= 0, length >= 0,
            let size = try fs.size(at: path), offset <= size, length <= size - offset else { return false }
        OperationWork.record(.localRangeHash)
        let input = try fs.openForReading(at: path)
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(offset))
        var hasher = StreamingHasher(digest.algorithm)
        var remaining = length
        while remaining > 0 {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            guard let data = try autoreleasepool(invoking: { try input.read(upToCount: Int(min(65_536, remaining))) }),
                !data.isEmpty else { return false }
            hasher.update(data)
            remaining -= Int64(data.count)
        }
        return hasher.finalize() == digest
    }
}
