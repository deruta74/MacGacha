// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import LauncherCore
import Sophon

public enum FolderOwnership: String, Codable, Sendable { case created, adopted }

public struct InstalledBuild: Codable, Sendable, Equatable {
    public let tag: String
    public let buildID: String
    public let categories: [BuildCategory]
    public let voices: Set<String>
    public init(tag: String, buildID: String, categories: [BuildCategory], voices: Set<String>) {
        self.tag = tag; self.buildID = buildID; self.categories = categories; self.voices = voices
    }
    private enum CodingKeys: String, CodingKey { case tag, buildID, categories, voices }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(tag: try c.decode(String.self, forKey: .tag), buildID: try c.decode(String.self, forKey: .buildID),
            categories: try c.decode([BuildCategory].self, forKey: .categories), voices: try c.decode(Set<String>.self, forKey: .voices))
        guard !tag.isEmpty, !buildID.isEmpty, voices.allSatisfy({ !$0.isEmpty }) else { throw LauncherError.io("invalid game record") }
    }
}

public struct PendingOperation: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case install, update, repair, adopt, voices }
    public let kind: Kind
    public let planID: SafeIdentifier
    public let planDigest: Digest
    public let target: InstalledBuild
    public init(kind: Kind, planID: SafeIdentifier, planDigest: Digest, target: InstalledBuild) {
        self.kind = kind; self.planID = planID; self.planDigest = planDigest; self.target = target
    }
    private enum CodingKeys: String, CodingKey { case kind, planID, planDigest, target }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try c.decode(Kind.self, forKey: .kind), planID: try c.decode(SafeIdentifier.self, forKey: .planID),
            planDigest: try c.decode(Digest.self, forKey: .planDigest), target: try c.decode(InstalledBuild.self, forKey: .target))
        guard planDigest.algorithm == .sha256 else { throw LauncherError.io("invalid game record") }
    }
}

public struct GameRecord: Codable, Sendable, Equatable {
    public var installPath: URL
    public var ownership: FolderOwnership
    public var executable: SafeRelativePath
    public var installed: InstalledBuild?
    public var pending: PendingOperation?
    public var uninstalling: Bool
    public init(installPath: URL, ownership: FolderOwnership, executable: SafeRelativePath,
        installed: InstalledBuild? = nil, pending: PendingOperation? = nil, uninstalling: Bool = false) {
        self.installPath = installPath; self.ownership = ownership; self.executable = executable
        self.installed = installed; self.pending = pending; self.uninstalling = uninstalling
    }
    private enum CodingKeys: String, CodingKey { case installPath, ownership, executable, installed, pending, uninstalling }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(installPath: try c.decode(URL.self, forKey: .installPath), ownership: try c.decode(FolderOwnership.self, forKey: .ownership),
            executable: try c.decode(SafeRelativePath.self, forKey: .executable), installed: try c.decodeIfPresent(InstalledBuild.self, forKey: .installed),
            pending: try c.decodeIfPresent(PendingOperation.self, forKey: .pending), uninstalling: try c.decode(Bool.self, forKey: .uninstalling))
        guard localFileURL(installPath) else { throw LauncherError.io("invalid game record") }
    }
}

public enum GameAction: Sendable, Equatable { case install, adopt, update, repair, voices, resume, uninstall }

public enum GameRecordRules {
    /// Pure transition policy. Paused records of other games do not establish a
    /// running operation; Task 18's library owns that independent concurrency lock.
    public static func check(_ action: GameAction, record: GameRecord?, others _: [GameRecord]) throws {
        if record?.uninstalling == true {
            guard action == .uninstall else { throw LauncherError.busy("finish uninstall first") }
            return
        }
        if record?.pending != nil {
            guard action == .resume || action == .uninstall else {
                throw LauncherError.busy("finish or uninstall the paused operation first")
            }
            return
        }
        switch action {
        case .install, .adopt:
            guard record == nil else { throw LauncherError.io("game already has a record") }
        case .update, .repair, .voices:
            guard record?.installed != nil else { throw LauncherError.io("game is not installed") }
        case .resume: throw LauncherError.io("no pending operation")
        case .uninstall:
            guard record != nil else { throw LauncherError.io("game is not installed") }
        }
    }

    /// File inspection is separate from the pure transition check, which has no
    /// target URL. Call this for fresh installs, never for adopt or uninstall.
    /// Reads just one non-dot directory entry; hidden files also make it nonempty.
    public static func checkInstallFolder(_ folder: URL) throws {
        try checkFolderURL(folder)
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        var info = stat()
        guard lstat(folder.path, &info) == 0 else {
            switch errno {
            case ENOENT: return
            case ELOOP, ENOTDIR: throw LauncherError.unsafePath("install location")
            default: throw LauncherError.io("cannot inspect install folder")
            }
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw LauncherError.unsafePath("install location") }
        guard let directory = opendir(folder.path) else {
            if errno == ELOOP || errno == ENOTDIR { throw LauncherError.unsafePath("install location") }
            throw LauncherError.io("cannot inspect install folder")
        }
        defer { closedir(directory) }
        while true {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw LauncherError.io("cannot inspect install folder") }
                return
            }
            let count = Int(entry.pointee.d_namlen)
            let dot = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                (count == 1 && bytes[0] == 46) || (count == 2 && bytes[0] == 46 && bytes[1] == 46)
            }
            if !dot { throw LauncherError.io("folder is not empty — use an existing installation instead") }
        }
    }

    /// Existing symlinks are resolved before component-wise, case-folded overlap
    /// checks. Home, filesystem and volume roots are anchors: their children may
    /// contain games. Explicit protected trees (App Support/runtime roots) may not.
    public static func checkLocation(_ folder: URL, others: [GameRecord], reserved: [URL]) throws {
        try checkFolderURL(folder)
        let resolved = try resolvedURL(folder)
        let key = try locationKey(resolved)
        let home = try resolvedURL(FileManager.default.homeDirectoryForCurrentUser)
        let homeKey = try locationKey(home)
        let volumesKey = try locationKey(resolvedURL(URL(fileURLWithPath: "/Volumes")))
        let anchors = [homeKey, try locationKey(resolvedURL(URL(fileURLWithPath: "/"))), volumesKey]
        let originalParent = try locationKey(resolvedURL(folder.deletingLastPathComponent()))
        guard try !reservedAnchor(resolved, key: key, anchors: anchors, volumes: volumesKey),
            !sameLocation(originalParent, volumesKey), !volumeRoot(folder) else {
            throw LauncherError.unsafePath("install location")
        }
        for record in others {
            guard !overlaps(key, try locationKey(resolvedURL(record.installPath))) else { throw LauncherError.unsafePath("install location") }
        }
        let applicationSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        for protected in reserved + [applicationSupport] {
            let path = try resolvedURL(protected)
            let protectedKey = try locationKey(path)
            if try reservedAnchor(path, key: protectedKey, anchors: anchors, volumes: volumesKey) || volumeRoot(protected) {
                guard !sameLocation(key, protectedKey) else { throw LauncherError.unsafePath("install location") }
            } else {
                guard !overlaps(key, protectedKey) else { throw LauncherError.unsafePath("install location") }
            }
        }
    }

    private static func checkFolderURL(_ folder: URL) throws {
        guard localFileURL(folder) else { throw LauncherError.unsafePath("install location") }
        // Reject ambiguous caller paths rather than collapsing dot components
        // before the filesystem has resolved any symlinks.
        let hasDotComponent = folder.path.utf8.split(separator: 0x2f).contains {
            $0.elementsEqual([0x2e]) || $0.elementsEqual([0x2e, 0x2e])
        }
        guard !hasDotComponent else { throw LauncherError.unsafePath("install location") }
    }

    private static func resolvedURL(_ url: URL) throws -> URL {
        guard localFileURL(url) else { throw LauncherError.unsafePath("install location") }
        // Foundation can leave an entire path unresolved when its tail is
        // missing. Walk existing components so a missing install directory does
        // not hide a symlinked ancestor. Dot-dot is applied after link expansion.
        var pending = url.path.split(separator: "/").map(String.init).reversed().map { $0 }
        var resolved = URL(fileURLWithPath: "/", isDirectory: true)
        var steps = 0
        var links = 0
        while let part = pending.popLast() {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            steps += 1
            guard steps <= maximumResolutionSteps else { throw LauncherError.unsafePath("install location") }
            if part == "." { continue }
            if part == ".." { resolved.deleteLastPathComponent(); continue }
            let candidate = resolved.appendingPathComponent(part)
            var info = stat()
            if lstat(candidate.path, &info) != 0 {
                guard errno == ENOENT else { throw LauncherError.unsafePath("install location") }
                resolved = candidate
                continue
            }
            if info.st_mode & S_IFMT == S_IFLNK {
                links += 1
                guard links <= maximumSymlinks else { throw LauncherError.unsafePath("install location") }
                var buffer = [UInt8](repeating: 0, count: maximumLinkBytes)
                let count = buffer.withUnsafeMutableBytes { raw in
                    readlink(candidate.path, raw.baseAddress!.assumingMemoryBound(to: CChar.self), raw.count)
                }
                guard count > 0, count < buffer.count, let target = String(bytes: buffer.prefix(count), encoding: .utf8) else {
                    throw LauncherError.unsafePath("install location")
                }
                if target.hasPrefix("/") { resolved = URL(fileURLWithPath: "/", isDirectory: true) }
                pending.append(contentsOf: target.split(separator: "/").map(String.init).reversed())
            } else {
                guard info.st_mode & S_IFMT == S_IFDIR else { throw LauncherError.unsafePath("install location") }
                resolved = candidate
            }
        }
        return resolved
    }
    private static let maximumResolutionSteps = 4096
    private static let maximumSymlinks = 40
    private static let maximumLinkBytes = 4096
    private static func pathKey(_ url: URL) -> [String] {
        url.pathComponents.map { $0.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) }
    }
    private struct FileIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
    }
    private struct LocationKey {
        let components: [String]
        let ancestors: [FileIdentity: ArraySlice<String>]
    }
    private static func locationKey(_ resolved: URL) throws -> LocationKey {
        let components = pathKey(resolved)
        var ancestors: [FileIdentity: ArraySlice<String>] = [:]
        var path = resolved
        // Firmlinks are not symlinks. Match existing ancestors by filesystem
        // identity, retaining folded suffixes even when the install tail is absent.
        for depth in stride(from: components.count, through: 1, by: -1) {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            var info = stat()
            if lstat(path.path, &info) == 0 {
                ancestors[FileIdentity(device: info.st_dev, inode: info.st_ino)] = components.dropFirst(depth)
            } else if errno != ENOENT {
                throw LauncherError.unsafePath("install location")
            }
            path.deleteLastPathComponent()
        }
        return LocationKey(components: components, ancestors: ancestors)
    }
    private static func sameLocation(_ a: LocationKey, _ b: LocationKey) -> Bool {
        a.components == b.components || a.ancestors.contains { identity, suffix in
            b.ancestors[identity].map { suffix.elementsEqual($0) } == true
        }
    }
    private static func overlaps(_ a: LocationKey, _ b: LocationKey) -> Bool {
        a.components.starts(with: b.components) || b.components.starts(with: a.components)
            || a.ancestors.contains { identity, suffix in
                b.ancestors[identity].map { suffix.starts(with: $0) || $0.starts(with: suffix) } == true
            }
    }
    private static func reservedAnchor(_ url: URL, key: LocationKey, anchors: [LocationKey], volumes: LocationKey) throws -> Bool {
        if anchors.contains(where: { sameLocation(key, $0) }) || volumeRoot(url) { return true }
        // /Volumes children are anchors even when unmounted or reached through
        // an APFS firmlink whose URLResourceValues does not identify a volume.
        return sameLocation(try locationKey(url.deletingLastPathComponent()), volumes)
    }
    private static func volumeRoot(_ url: URL) -> Bool {
        let parts = pathKey(url)
        if parts.count == 3, parts[1] == "volumes" { return true }
        return (try? url.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true
    }
}

private func localFileURL(_ url: URL) -> Bool {
    url.isFileURL && (url.host == nil || url.host == "" || url.host?.lowercased() == "localhost")
        && url.query == nil && url.fragment == nil && url.path.hasPrefix("/") && !url.path.utf8.contains(0)
}
