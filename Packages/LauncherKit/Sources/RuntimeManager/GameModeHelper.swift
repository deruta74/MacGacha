// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import CoreServices
import LauncherCore

public protocol GameModeRegistering: Sendable {
    func register(_ app: URL) throws
}

public struct SystemGameModeRegistration: GameModeRegistering {
    public init() {}
    public func register(_ app: URL) throws {
        guard LSRegisterURL(app as CFURL, true) == noErr else { throw LauncherError.io("Game Mode registration failed") }
    }
}

public struct GameModeRuntime: Sendable, Equatable {
    /// The mirrored runtime root is Contents, with bin renamed to MacOS.
    public let root: URL
    public let wineBinary: URL
    public var wineserver: URL { wineBinary.deletingLastPathComponent().appendingPathComponent("wineserver") }
    public init(root: URL, wineBinary: URL) {
        self.root = URL(fileURLWithPath: root.path, isDirectory: true)
        self.wineBinary = URL(fileURLWithPath: wineBinary.path, isDirectory: false)
    }
}

public protocol GameModeProviding: Sendable {
    func prepare(bundle: InstalledRuntimeBundle, componentIDs: [String]) async throws -> GameModeRuntime
    func validate(_ helper: GameModeRuntime, bundle: InstalledRuntimeBundle) async throws
}

/// Mirrors owned runtime files without copying or modifying their signed bytes.
/// A launch treats any failure as an optional-feature failure and uses normal Wine.
public struct GameModeHelper: GameModeProviding {
    private let paths: AppPaths
    private let registration: any GameModeRegistering
    private let beforeLink: @Sendable () throws -> Void
    public init(paths: AppPaths, registration: any GameModeRegistering = SystemGameModeRegistration()) {
        self.paths = paths; self.registration = registration; self.beforeLink = {}
    }
    package init(paths: AppPaths, registration: any GameModeRegistering, beforeLink: @escaping @Sendable () throws -> Void) {
        self.paths = paths; self.registration = registration; self.beforeLink = beforeLink
    }

    private struct Marker: Codable, Equatable {
        let bundleID: SafeIdentifier
        let bundleDigest: Digest
        let wineDigest: Digest
    }

    public func prepare(bundle: InstalledRuntimeBundle, componentIDs: [String]) async throws -> GameModeRuntime {
        try await BlockingIO.run {
            let lease = try RuntimeStoreLease(store: RuntimeStore(paths: paths))
            defer { withExtendedLifetime(lease) {} }
            let fs = try ContainedFileSystem(root: paths.root).pinRoot()
            let source = try sourcePath(bundle)
            let marker = try self.marker(bundle, fs: fs)
            let destination = try Self.appPath(bundle.id, paths: paths)
            let helper = GameModeRuntime(root: try SafeRelativePath("\(destination)/Contents").resolved(against: paths.root),
                wineBinary: try SafeRelativePath("\(destination)/Contents/MacOS/\(bundle.wineBinary.lastPathComponent)").resolved(against: paths.root))
            if (try? verify(helper, bundle: bundle, fs: fs, marker: marker)) != nil {
                try registration.register(destination.resolved(against: paths.root))
                return helper
            }
            // Valid reuse is read-only, but construction/replacement needs the same
            // component exclusion and journal barrier as runtime publication/removal.
            let pins = try RuntimeRemovalLease(paths: paths, componentIDs: componentIDs)
            defer { withExtendedLifetime(pins) {} }
            guard !pins.componentIDs.isEmpty else { throw LauncherError.io("Missing Game Mode component exclusion") }
            let entries = try snapshot(fs: fs, root: source)
            let incoming = try SafeRelativePath("\(destination.components.dropLast().joined(separator: "/"))/.incoming-\(UUID().uuidString)")
            do {
                try fs.createDirectory(at: SafeRelativePath("\(incoming)/Contents"))
                for entry in entries {
                    try Task.checkCancellation()
                    let output = try SafeRelativePath("\(incoming)/Contents/\(mapped(entry.path))")
                    if entry.type == .directory { try fs.createDirectory(at: output) }
                    else if let target = entry.linkTarget { try fs.createSymbolicLink(at: output, target: target) }
                    else {
                        try beforeLink()
                        try fs.createHardLink(at: output, to: SafeRelativePath("\(source)/\(entry.path)"))
                    }
                }
                let contents = try SafeRelativePath("\(incoming)/Contents")
                let plist = try PropertyListSerialization.data(fromPropertyList: Self.plist(executable: bundle.wineBinary.lastPathComponent), format: .xml, options: 0)
                try fs.writeAtomically(plist, to: SafeRelativePath("\(contents)/Info.plist"))
                try fs.writeAtomically(JSONEncoder().encode(marker), to: SafeRelativePath("\(incoming)/.macgacha-game-mode.json"))
                // Never sync/quarantine/sign the linked tree: those operations would
                // mutate or repeatedly flush the original runtime's shared inodes.
                try fs.publishDirectory(at: incoming, to: destination)
                try verify(helper, bundle: bundle, fs: fs, marker: marker)
                try registration.register(destination.resolved(against: paths.root))
                try fs.removeItem(at: incoming)
                return helper
            } catch {
                try? fs.removeItem(at: incoming)
                throw error
            }
        }
    }

    public func validate(_ helper: GameModeRuntime, bundle: InstalledRuntimeBundle) async throws {
        try await BlockingIO.run {
            let fs = try ContainedFileSystem(root: paths.root).pinRoot()
            try verify(helper, bundle: bundle, fs: fs, marker: marker(bundle, fs: fs))
        }
    }

    private func verify(_ helper: GameModeRuntime, bundle: InstalledRuntimeBundle, fs: ContainedFileSystem, marker: Marker) throws {
        let app = try Self.appPath(bundle.id, paths: paths)
        let root = try SafeRelativePath("\(app)/Contents")
        guard helper.root.path == root.resolved(against: paths.root).path,
            helper.wineBinary.path == (try SafeRelativePath("\(root)/MacOS/\(bundle.wineBinary.lastPathComponent)").resolved(against: paths.root)).path else {
            throw LauncherError.io("Game Mode helper location changed")
        }
        guard try JSONDecoder().decode(Marker.self, from: fs.readFile(at: SafeRelativePath("\(app)/.macgacha-game-mode.json"), maxBytes: 4096)) == marker else {
            throw LauncherError.io("Game Mode identity changed")
        }
        let source = try sourcePath(bundle), entries = try snapshot(fs: fs, root: source)
        let actual = try fs.inspectTree(at: root, allowingExternalHardLinks: true)
        let byPath = Dictionary(uniqueKeysWithValues: actual.map { ($0.path.description, $0) })
        guard actual.count == entries.count + 1 else { throw LauncherError.io("Game Mode mirror contents changed") }
        for entry in entries {
            let mapped = try mapped(entry.path)
            guard let mirror = byPath[mapped.description], mirror.type == entry.type, mirror.linkTarget == entry.linkTarget else {
                throw LauncherError.io("Game Mode mirror entry changed")
            }
            if entry.type == .regularFile {
                guard try fs.regularFileIdentity(at: SafeRelativePath("\(source)/\(entry.path)")) == fs.regularFileIdentity(at: SafeRelativePath("\(root)/\(mapped)")) else {
                    throw LauncherError.io("Game Mode mirror inode changed")
                }
            }
        }
        let plist = try PropertyListSerialization.propertyList(from: fs.readFile(at: SafeRelativePath("\(root)/Info.plist"), maxBytes: 16384), format: nil)
        guard let dictionary = plist as? NSDictionary, dictionary == Self.plist(executable: bundle.wineBinary.lastPathComponent) as NSDictionary else {
            throw LauncherError.io("Game Mode application metadata changed")
        }
    }

    private func marker(_ bundle: InstalledRuntimeBundle, fs: ContainedFileSystem) throws -> Marker {
        var hash = StreamingHasher(.sha256)
        hash.update(try fs.readFile(at: RuntimeJSONFile.relativePath(bundle.wineBinary, root: paths.root), maxBytes: 32 << 20))
        return Marker(bundleID: bundle.id, bundleDigest: bundle.digest, wineDigest: hash.finalize())
    }
    private func sourcePath(_ bundle: InstalledRuntimeBundle) throws -> SafeRelativePath {
        let root = try RuntimeJSONFile.relativePath(bundle.root, root: paths.root)
        let runtime = try RuntimeJSONFile.relativePath(paths.runtimes, root: paths.root)
        guard root.components.starts(with: runtime.components), !root.components.contains("GameMode"),
            bundle.wineBinary.deletingLastPathComponent().path == bundle.root.appendingPathComponent("bin").path else {
            throw LauncherError.io("Invalid Game Mode runtime layout")
        }
        return root
    }
    private func snapshot(fs: ContainedFileSystem, root: SafeRelativePath) throws -> [ContainedFileSystem.TreeEntry] {
        let entries = try fs.inspectTree(at: root, allowingExternalHardLinks: true)
        guard entries.contains(where: { $0.path.description == "bin" && $0.type == .directory }),
            !entries.contains(where: { ["Info.plist", "MacOS"].contains($0.path.components[0]) }) else {
            throw LauncherError.io("Unsupported Game Mode runtime layout")
        }
        // Validate containment both before and after the bin -> MacOS mapping.
        for transform in [false, true] {
            try ArchivePolicy.validate(entries.map { entry in
                ArchiveEntry(path: try transform ? mapped(entry.path).description : entry.path.description,
                    kind: entry.linkTarget.map { .symlink($0) } ?? (entry.type == .directory ? .directory : .file))
            })
        }
        return entries
    }
    private func mapped(_ path: SafeRelativePath) throws -> SafeRelativePath {
        try SafeRelativePath(([path.components[0] == "bin" ? "MacOS" : path.components[0]] + path.components.dropFirst()).joined(separator: "/"))
    }
    private static func plist(executable: String) -> [String: Any] {
        ["CFBundleIdentifier": "com.lo7ted.macgacha.game", "CFBundleName": "MacGacha Game", "CFBundleExecutable": executable,
         "CFBundlePackageType": "APPL", "LSApplicationCategoryType": "public.app-category.games", "LSSupportsGameMode": true, "LSUIElement": true]
    }
    private static func appPath(_ id: SafeIdentifier, paths: AppPaths) throws -> SafeRelativePath {
        try SafeRelativePath("\(RuntimeJSONFile.relativePath(paths.runtimes, root: paths.root))/GameMode/\(id)/MacGacha Game.app")
    }
    static func remove(bundleID: SafeIdentifier, paths: AppPaths, fs: ContainedFileSystem) throws {
        try fs.removeItem(at: SafeRelativePath("\(RuntimeJSONFile.relativePath(paths.runtimes, root: paths.root))/GameMode/\(bundleID)"))
    }
}
