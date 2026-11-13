// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation

/// Display-only names come from the saved path, including while the drive is absent.
/// Never include these URLs or names in operational events.
public enum GameLocation {
    public static func volumeRoot(for root: URL) -> URL? {
        let components = root.standardizedFileURL.pathComponents
        let folded = components.map { $0.lowercased() }
        let name: String
        if folded.count >= 3, folded[1] == "volumes" { name = components[2] }
        else if folded.count >= 6, folded[1...4].elementsEqual(["system", "volumes", "data", "volumes"]) { name = components[5] }
        else { return nil }
        return URL(fileURLWithPath: "/Volumes", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    public static func volumeDisplayName(for root: URL) -> String? { volumeRoot(for: root)?.lastPathComponent }
}

public protocol GameLocationProbing: Sendable {
    /// Checks the volume without creating an absent mount point or installation.
    /// Blocking platform volume discovery belongs on BlockingIO or an I/O executor.
    func requireAvailable(at root: URL) throws
}

public struct SystemGameLocationProbe: GameLocationProbing {
    private let mountedVolumes: @Sendable () -> [URL]?
    public init(mountedVolumes: @escaping @Sendable () -> [URL]? = {
        FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [])
    }) { self.mountedVolumes = mountedVolumes }

    public func requireAvailable(at root: URL) throws {
        guard let volume = GameLocation.volumeRoot(for: root) else { return }
        // An empty directory left at /Volumes/<name> is not a mounted drive.
        guard mountedVolumes()?.contains(where: {
            (GameLocation.volumeRoot(for: $0) ?? $0.standardizedFileURL).path == volume.path
        }) == true else { throw LauncherError.installVolumeUnavailable }
    }
}
