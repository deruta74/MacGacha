// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

public enum LaunchCopies {
    /// Blocking I/O; async callers use BlockingIO.run. Source access is read-only.
    public static func copyIfPresent(_ items: [(SafeRelativePath, String)], installRoot: URL, system32: URL, log: SessionLog?) throws {
        try copyIfPresent(items, installRoot: installRoot, system32: system32, log: log, fileOps: SystemFileOps())
    }
    package static func copyIfPresent(_ items: [(SafeRelativePath, String)], installRoot: URL, system32: URL, log: SessionLog?,
        fileOps: any FileOps, beforePublication: @Sendable (SafeRelativePath) -> Void = { _ in }) throws {
        guard Array(system32.pathComponents.suffix(3)) == ["drive_c", "windows", "system32"] else { throw LauncherError.unsafePath(system32.path) }
        let prefix = system32.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let destination = try ContainedFileSystem(root: prefix, fileOps: fileOps).pinRoot()
        _ = try destination.directoryURL(at: SafeRelativePath("drive_c/windows"))
        let source = try ContainedFileSystem(root: installRoot).pinRoot()
        for (input, name) in items {
            guard try SafeRelativePath(name).components.count == 1 else { throw LauncherError.unsafePath(name) }
            guard try source.itemType(at: input) != nil else { log?.append(line: "skip \(input.components.last!) (not present)"); continue }
            try source.withClaimedFile(at: input, permitHardLinks: true) { sourceClaim in
                let size = sourceClaim.stamp.size, digest = sourceClaim.sha256
                let final = try SafeRelativePath("drive_c/windows/system32/\(name)")
                let temporary = try SafeRelativePath("drive_c/windows/system32/.macgacha-copy-\(UUID().uuidString)")
                guard let output = try destination.createOwnedFile(at: temporary) else { throw LauncherError.io("Launch copy temporary already exists") }
                defer { _ = try? output.removeIfNamed() }
                try sourceClaim.copyBytes(to: output)
                func install() throws {
                    try output.withClaim { claim in
                        guard claim.stamp.size == size, claim.sha256 == digest else { throw LauncherError.io("Launch copy verification failed") }
                        try claim.fullSync()
                        beforePublication(temporary)
                        guard try claim.move(to: final, in: destination) else { throw LauncherError.io("Launch copy publication changed") }
                    }
                }
                if try destination.itemType(at: final) != nil {
                    try destination.withClaimedFile(at: final) { prior in
                        if prior.stamp.size == size, prior.sha256 == digest { return }
                        let identity = try prior.ownedIdentity(), oldDigest = prior.sha256
                        let backup = try SafeRelativePath("drive_c/windows/system32/.macgacha-copy-prior-\(UUID().uuidString)")
                        guard try prior.move(to: backup, in: destination) else { throw LauncherError.io("Previous launch copy changed") }
                        do {
                            try install()
                            _ = try destination.removeOwnedFile(at: backup, matching: identity)
                        } catch {
                            // Restore only the exact displaced inode, and only into
                            // a vacant name. An updater's new file is never replaced.
                            if (try? destination.itemType(at: final, allowingLeafSymlink: true)) == nil {
                                try? destination.withClaimedFile(at: backup) { claim in
                                    guard try claim.ownedIdentity() == identity, claim.sha256 == oldDigest else { return }
                                    _ = try claim.move(to: final, in: destination)
                                }
                            }
                            throw error
                        }
                    }
                } else { try install() }
                log?.append(line: "copy \(input.components.last!) to system32/\(name)")
            }
        }
    }
}
