// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation

public protocol DiskSpaceProbe: Sendable {
    func availableBytes(at url: URL) throws -> Int64
}

public struct SystemDiskSpaceProbe: DiskSpaceProbe {
    public init() {}

    /// Fresh kernel allocation capacity, without credit for potentially
    /// purgeable caches. The Foundation "important usage" query invokes
    /// CacheDelete/volume enumeration and is unsuitable for every file's
    /// allocation barrier. This query is uncached and excludes purgeable credit.
    /// Free blocks do not establish quota headroom; EDQUOT/ENOSPC from
    /// actual allocation is handled as a resumable insufficient-space pause.
    public func availableBytes(at url: URL) throws -> Int64 {
        var ancestor = url.standardizedFileURL
        while true {
            let fd = open(ancestor.path, O_EVTONLY | O_CLOEXEC | O_NONBLOCK)
            if fd >= 0 {
                defer { close(fd) }
                var info = statfs()
                guard fstatfs(fd, &info) == 0, info.f_bsize > 0 else {
                    throw LauncherError.io("Available disk capacity is unavailable")
                }
                let (bytes, overflow) = info.f_bavail.multipliedReportingOverflow(by: UInt64(info.f_bsize))
                guard !overflow, bytes <= UInt64(Int64.max) else { throw LauncherError.io("Available disk capacity overflow") }
                return Int64(bytes)
            }
            guard errno == ENOENT || errno == ENOTDIR else { throw LauncherError.io("Available disk capacity is unavailable") }
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { throw LauncherError.io("No existing ancestor for disk capacity query") }
            ancestor = parent
        }
    }
}
