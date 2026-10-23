// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation

/// Advisory Finder-style capacity, including storage macOS may reclaim later.
/// Never use this value as an engine allocation budget.
public protocol PurgeableSpaceProbe: Sendable {
    func importantUsageBytes(at url: URL) -> Int64?
}

public struct SystemPurgeableSpaceProbe: PurgeableSpaceProbe {
    public init() {}

    /// May invoke CacheDelete; callers must use BlockingIO, outside hot paths.
    public func importantUsageBytes(at url: URL) -> Int64? {
        guard url.isFileURL else { return nil }
        var ancestor = url.standardizedFileURL
        while true {
            var info = stat()
            if stat(ancestor.path, &info) == 0 {
                return try? ancestor.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage
            }
            guard errno == ENOENT || errno == ENOTDIR else { return nil }
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { return nil }
            ancestor = parent
        }
    }
}
