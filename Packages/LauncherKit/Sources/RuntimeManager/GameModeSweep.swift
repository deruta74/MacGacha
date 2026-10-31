// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

/// Runs within the store lease. Pins are kept on disk, so even an old partial
/// mirror whose marker was never written can be reclaimed under exclusion.
enum GameModeSweep {
    private struct Source: Decodable { let sourceRoot: SafeRelativePath? }

    static func run(paths: AppPaths, fs: ContainedFileSystem, holding held: RuntimeRemovalLease?,
        deleting: (ContainedFileSystem, SafeRelativePath) throws -> Void) throws {
        let runtimes = try RuntimeJSONFile.relativePath(paths.runtimes, root: paths.root)
        let root = try SafeRelativePath("\(runtimes)/GameMode")
        guard let type = try fs.itemType(at: root) else { return }
        guard type == .directory else { throw LauncherError.unsafePath(root.description) }
        // Legacy partial mirrors have no component metadata. Reserve all known
        // component IDs, including retired ones, before inspecting or unlinking.
        let ids = try children(runtimes, fs: fs).compactMap { path -> String? in
            let name = path.components.last!
            guard name.hasPrefix(".pin-"), name.hasSuffix(".lock") else { return nil }
            return try SafeIdentifier(String(name.dropFirst(5).dropLast(5))).rawValue
        }
        let missing = Set(ids).subtracting(held?.componentIDs ?? [])
        let pins = try RuntimeRemovalLease(paths: paths, componentIDs: Array(missing))
        defer { withExtendedLifetime(pins) {} }
        for bundle in try children(root, fs: fs) {
            try Task.checkCancellation()
            guard let id = try? SafeIdentifier(bundle.components.last!), try isDirectory(bundle, fs: fs) else { continue }
            for stage in try children(bundle, fs: fs) {
                let name = stage.components.last!
                guard name.hasPrefix(".incoming-") || name.hasPrefix(".removing-"), try isDirectory(stage, fs: fs) else { continue }
                try deleting(fs, stage)
            }
            let legacy = try SafeRelativePath("\(bundle)/MacGacha Game.app")
            if try isDirectory(legacy, fs: fs) {
                try reclaim(app: legacy, container: legacy, bundleID: id, runtimes: runtimes, fs: fs, deleting: deleting)
            }
            for game in GameDefinition.all {
                let group = try SafeRelativePath("\(bundle)/\(SafeIdentifier(game.id))")
                guard try isDirectory(group, fs: fs) else { continue }
                for stage in try children(group, fs: fs) {
                    let name = stage.components.last!
                    if (name.hasPrefix(".incoming-") || name.hasPrefix(".removing-")), try isDirectory(stage, fs: fs) { try deleting(fs, stage) }
                }
                // Retain title-named helpers for old sessions, but reclaim both
                // generations when their runtime source no longer exists.
                for name in [game.id, game.gameApplicationName] {
                    let app = try SafeRelativePath("\(group)/\(name).app")
                    if try isDirectory(app, fs: fs) {
                        try reclaim(app: app, container: group, bundleID: id, runtimes: runtimes, fs: fs, deleting: deleting)
                    }
                }
                if try isDirectory(group, fs: fs), try children(group, fs: fs).isEmpty { try deleting(fs, group) }
            }
            if try children(bundle, fs: fs).isEmpty { try deleting(fs, bundle) }
        }
    }

    private static func reclaim(app: SafeRelativePath, container: SafeRelativePath, bundleID: SafeIdentifier,
        runtimes: SafeRelativePath, fs: ContainedFileSystem, deleting: (ContainedFileSystem, SafeRelativePath) throws -> Void) throws {
        let source = try sourceRoot(app: app, id: bundleID, runtimes: runtimes, fs: fs)
        guard source.components.count > runtimes.components.count, source.components.starts(with: runtimes.components),
            !source.components.contains("GameMode") else { throw LauncherError.io("Invalid Game Mode source location") }
        if try fs.itemType(at: source) != .directory { try deleting(fs, container) }
    }

    private static func sourceRoot(app: SafeRelativePath, id: SafeIdentifier, runtimes: SafeRelativePath,
        fs: ContainedFileSystem) throws -> SafeRelativePath {
        let marker = try SafeRelativePath("\(app)/.macgacha-game-mode.json")
        if let data = try RuntimeJSONFile.read(marker, in: fs, limit: 4096),
            let path = try JSONDecoder().decode(Source.self, from: data).sourceRoot { return path }
        // Before sourceRoot was recorded, downloaded D3DMetal mirrored its
        // component marker; assembled and imported bundles used bundles/<id>.
        let component = try SafeRelativePath("\(app)/Contents/.macgacha-component.json")
        if let data = try RuntimeJSONFile.read(component, in: fs, limit: 16384) {
            let record = try JSONDecoder().decode(InstalledComponent.self, from: data)
            return try SafeRelativePath("\(runtimes)/\(record.kind.rawValue)/\(record.version)")
        }
        return try SafeRelativePath("\(runtimes)/bundles/\(id)")
    }

    private static func children(_ path: SafeRelativePath, fs: ContainedFileSystem) throws -> [SafeRelativePath] {
        let result = try fs.contentsOfDirectoryReportingInvalid(at: path)
        guard result.paths.count + result.invalid.count <= 1024 else { throw LauncherError.io("Too many Game Mode sweep entries") }
        return result.paths
    }

    private static func isDirectory(_ path: SafeRelativePath, fs: ContainedFileSystem) throws -> Bool {
        // Classify the leaf without following it; directory traversal itself also
        // refuses symlink ancestors. Foreign targets are never cleanup inputs.
        try fs.itemType(at: path, allowingLeafSymlink: true) == .directory
    }
}
