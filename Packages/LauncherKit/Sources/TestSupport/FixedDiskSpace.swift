// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

public struct FixedDiskSpace: DiskSpaceProbe {
    public let bytes: Int64
    public init(bytes: Int64) { self.bytes = bytes }
    public func availableBytes(at url: URL) throws -> Int64 { bytes }
}
