// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation

public protocol DiskSpaceProbe: Sendable {
    func availableBytes(at url: URL) throws -> Int64
}

public struct SystemDiskSpaceProbe: DiskSpaceProbe {
    public init() {}

    public func availableBytes(at url: URL) throws -> Int64 {
        do {
            var ancestor = url.standardizedFileURL
            while !FileManager.default.fileExists(atPath: ancestor.path) {
                let parent = ancestor.deletingLastPathComponent()
                guard parent.path != ancestor.path else {
                    throw LauncherError.io("No existing ancestor for disk capacity query")
                }
                ancestor = parent
            }
            let values = try ancestor.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            if let bytes = values.volumeAvailableCapacityForImportantUsage, bytes > 0 { return bytes }
            // Some environments report zero for important usage despite having free blocks.
            // Ordinary available capacity excludes purgeable space and is conservative here.
            if let bytes = values.volumeAvailableCapacity, bytes > 0 { return Int64(bytes) }
            guard let bytes = values.volumeAvailableCapacityForImportantUsage else {
                throw LauncherError.io("Available disk capacity is unavailable")
            }
            return bytes
        } catch let error as LauncherError {
            throw error
        } catch {
            throw LauncherError.io(error.localizedDescription)
        }
    }
}
