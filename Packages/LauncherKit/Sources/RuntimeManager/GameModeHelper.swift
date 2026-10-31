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

public struct GameModeOptions: Sendable, Equatable {
    public let gameModeEnabled: Bool
    public let surroundModule: URL?
    public init(gameModeEnabled: Bool = true, surroundModule: URL? = nil) {
        self.gameModeEnabled = gameModeEnabled; self.surroundModule = surroundModule
    }
}

public struct GameModeRuntime: Sendable, Equatable {
    public let gameModeEnabled: Bool
    public let surroundModule: URL?
    public let gameID: String
    public let root: URL
    public let wineBinary: URL
    public let wineserver: URL
    public var loader: URL { root.appendingPathComponent("MacOS/wine", isDirectory: false) }
    public init(game: GameDefinition, root: URL, wineBinary: URL, wineserver: URL, gameModeEnabled: Bool = true, surroundModule: URL? = nil) {
        self.gameModeEnabled = gameModeEnabled; self.surroundModule = surroundModule
        gameID = game.id
        self.root = URL(fileURLWithPath: root.path, isDirectory: true)
        self.wineBinary = URL(fileURLWithPath: wineBinary.path, isDirectory: false)
        self.wineserver = URL(fileURLWithPath: wineserver.path, isDirectory: false)
    }
}

public protocol GameModeProviding: Sendable {
    func prepare(bundle: InstalledRuntimeBundle, game: GameDefinition, componentIDs: [String], options: GameModeOptions) async throws -> GameModeRuntime
    func validate(_ helper: GameModeRuntime, bundle: InstalledRuntimeBundle) async throws
}

extension GameModeProviding {
    public func prepare(bundle: InstalledRuntimeBundle, game: GameDefinition, componentIDs: [String]) async throws -> GameModeRuntime {
        try await prepare(bundle: bundle, game: game, componentIDs: componentIDs, options: GameModeOptions())
    }
}

/// Keep the runtime tree intact, but load ntdll and every long-running Unix
/// loader from MacOS so macOS attributes the game and its children to this app.
public struct GameModeHelper: GameModeProviding {
    private let paths: AppPaths
    private let icons: any GameModeIconProviding
    private let registration: any GameModeRegistering
    private let beforeLink: @Sendable () throws -> Void
    public init(paths: AppPaths, icons: any GameModeIconProviding = BundleGameModeIcons(), registration: any GameModeRegistering = SystemGameModeRegistration()) {
        self.paths = paths; self.icons = icons; self.registration = registration; self.beforeLink = {}
    }
    package init(paths: AppPaths, icons: any GameModeIconProviding = BundleGameModeIcons(), registration: any GameModeRegistering,
        beforeLink: @escaping @Sendable () throws -> Void) {
        self.paths = paths; self.icons = icons; self.registration = registration; self.beforeLink = beforeLink
    }

    private struct Marker: Codable, Equatable {
        let layout: Int
        let gameID: String
        let bundleID: SafeIdentifier
        let bundleDigest: Digest
        let wineDigest: Digest
        let iconDigest: Digest
        let sourceRoot: SafeRelativePath
        let gameModeEnabled: Bool
        let surroundSource: SafeRelativePath?
        let surroundDigest: Digest?
    }
    private struct Entry {
        let path: SafeRelativePath
        var source: SafeRelativePath? = nil
        var link: String? = nil
        var data: Data? = nil
        var directory: Bool = false
    }
    private struct Plan {
        let marker: Marker
        let entries: [Entry]
        let command: String
        let options: GameModeOptions
    }

    public func prepare(bundle: InstalledRuntimeBundle, game: GameDefinition, componentIDs: [String], options: GameModeOptions) async throws -> GameModeRuntime {
        guard options.surroundModule == nil || componentIDs.contains(SurroundAudio.componentID) else { throw LauncherError.io("Missing surround component exclusion") }
        let icon = try await icons.icon(for: game)
        return try await BlockingIO.run {
            let lease = try RuntimeStoreLease(store: RuntimeStore(paths: paths))
            defer { withExtendedLifetime(lease) {} }
            let fs = try ContainedFileSystem(root: paths.root).pinRoot()
            let plan = try self.plan(bundle: bundle, game: game, icon: icon, fs: fs, options: options)
            let destination = try appPath(bundle.id, game: game)
            let helper = try result(destination: destination, game: game, command: plan.command, options: plan.options)
            if (try? verify(helper, destination: destination, plan: plan, fs: fs)) != nil {
                try registration.register(destination.resolved(against: paths.root))
                return helper
            }
            let pins = try RuntimeRemovalLease(paths: paths, componentIDs: componentIDs)
            defer { withExtendedLifetime(pins) {} }
            guard !pins.componentIDs.isEmpty else { throw LauncherError.io("Missing Game Mode component exclusion") }
            // Old sessions keep these links until their pins and journal drain.
            let legacy = try SafeRelativePath("\(RuntimeJSONFile.relativePath(paths.runtimes, root: paths.root))/GameMode/\(bundle.id)/MacGacha Game.app")
            try fs.removeItem(at: legacy)
            let titleNamed = try SafeRelativePath("\(destination.components.dropLast().joined(separator: "/"))/\(game.gameApplicationName).app")
            if titleNamed != destination { try fs.removeItem(at: titleNamed) }
            let incoming = try SafeRelativePath("\(destination.components.dropLast().joined(separator: "/"))/.incoming-\(UUID().uuidString)")
            do {
                try fs.createDirectory(at: incoming)
                for entry in plan.entries {
                    try Task.checkCancellation()
                    let output = try SafeRelativePath("\(incoming)/\(entry.path)")
                    if entry.directory { try fs.createDirectory(at: output) }
                    else if let link = entry.link { try fs.createSymbolicLink(at: output, target: link) }
                    else if let source = entry.source { try beforeLink(); try fs.createHardLink(at: output, to: source) }
                    else if let data = entry.data { try fs.writeAtomically(data, to: output) }
                }
                try fs.writeAtomically(JSONEncoder().encode(plan.marker), to: SafeRelativePath("\(incoming)/.macgacha-game-mode.json"))
                // Shared executable inodes must never be re-signed or modified.
                try fs.publishDirectory(at: incoming, to: destination)
                try verify(helper, destination: destination, plan: plan, fs: fs)
                try registration.register(destination.resolved(against: paths.root))
                try fs.removeItem(at: incoming)
                return helper
            } catch {
                try? await BlockingIO.finish { try fs.removeItem(at: incoming) }
                throw error
            }
        }
    }

    public func validate(_ helper: GameModeRuntime, bundle: InstalledRuntimeBundle) async throws {
        guard let game = GameDefinition.find(helper.gameID) else { throw LauncherError.io("Unknown Game Mode edition") }
        let icon = try await icons.icon(for: game)
        try await BlockingIO.run {
            let fs = try ContainedFileSystem(root: paths.root).pinRoot()
            try verify(helper, destination: appPath(bundle.id, game: game), plan: plan(bundle: bundle, game: game, icon: icon, fs: fs, options: GameModeOptions(gameModeEnabled: helper.gameModeEnabled, surroundModule: helper.surroundModule)), fs: fs)
        }
    }

    private func surroundSource(_ options: GameModeOptions, bundle: InstalledRuntimeBundle, game: GameDefinition, fs: ContainedFileSystem) throws -> SafeRelativePath? {
        guard let url = options.surroundModule else { return nil }
        guard SurroundAudio.applies(game: game.id, backend: .d3dmetal, bundleID: bundle.id.rawValue) else { throw LauncherError.io("Incompatible surround helper") }
        let root = try SafeRelativePath("\(RuntimeJSONFile.relativePath(paths.runtimes, root: paths.root))/surroundAudio/\(SurroundAudio.version)")
        let module = try SafeRelativePath("\(root)/\(SurroundAudio.modulePath)")
        guard url.isFileURL, url.path == module.resolved(against: paths.root).path else { throw LauncherError.io("Invalid surround component location") }
        let record = try JSONDecoder().decode(InstalledComponent.self, from: fs.readFile(at: SafeRelativePath("\(root)/.macgacha-component.json"), maxBytes: 16384))
        guard record.kind == .surroundAudio, record.version == SurroundAudio.version else { throw LauncherError.io("Invalid surround component identity") }
        return module
    }

    private func plan(bundle: InstalledRuntimeBundle, game: GameDefinition, icon: GameModeIcon, fs: ContainedFileSystem, options: GameModeOptions) throws -> Plan {
        guard GameDefinition.find(game.id) != nil else { throw LauncherError.io("Unknown Game Mode edition") }
        let source = try RuntimeJSONFile.relativePath(bundle.root, root: paths.root)
        let runtimes = try RuntimeJSONFile.relativePath(paths.runtimes, root: paths.root)
        guard source.components.starts(with: runtimes.components), !source.components.contains("GameMode"),
            bundle.wineBinary.deletingLastPathComponent().path == bundle.root.appendingPathComponent("bin").path else { throw LauncherError.io("Invalid Game Mode runtime layout") }
        let unix = "lib/wine/x86_64-unix"
        let wrapper = try fs.readFile(at: RuntimeJSONFile.relativePath(bundle.wineBinary, root: paths.root), maxBytes: 32 << 20)
        let script = String(data: wrapper, encoding: .utf8)
        let wrapped = script?.hasPrefix("#!/bin/sh") == true && script?.contains("$wrapper_dir/wine.real") == true
        let magic = Data([0xcf, 0xfa, 0xed, 0xfe])
        guard wrapped || wrapper.starts(with: magic) else { throw LauncherError.io("Unsupported Game Mode Wine wrapper") }
        var hash = StreamingHasher(.sha256); hash.update(wrapper)
        for name in ["wine", "ntdll.so"] {
            let data = try fs.readFile(at: SafeRelativePath("\(source)/\(unix)/\(name)"), maxBytes: 32 << 20)
            guard data.starts(with: magic) else { throw LauncherError.io("Unsupported Game Mode Unix loader") }
            hash.update(data)
        }
        let audio = try surroundSource(options, bundle: bundle, game: game, fs: fs)
        var audioDigest: Digest?
        if let audio {
            let data = try fs.readFile(at: audio, maxBytes: 32 << 20)
            guard data.starts(with: magic) else { throw LauncherError.io("Unsupported surround module") }
            var audioHash = StreamingHasher(.sha256); audioHash.update(data); audioDigest = audioHash.finalize()
        }
        let marker = Marker(layout: 4, gameID: game.id, bundleID: bundle.id, bundleDigest: bundle.digest,
            wineDigest: hash.finalize(), iconDigest: icon.digest, sourceRoot: source, gameModeEnabled: options.gameModeEnabled,
            surroundSource: audio, surroundDigest: audioDigest)
        let original = try fs.inspectTree(at: source, allowingExternalHardLinks: true)
        guard !original.contains(where: { ["MacOS", "Info.plist", "Resources"].contains($0.path.components[0]) }) else { throw LauncherError.io("Unsupported Game Mode runtime layout") }
        if audio != nil {
            guard original.contains(where: { $0.path.description == "\(unix)/winecoreaudio.so" && $0.type == .regularFile }) else {
                throw LauncherError.io("Missing runtime audio module slot")
            }
        }
        try ArchivePolicy.validate(original.map { ArchiveEntry(path: $0.path.description, kind: $0.linkTarget.map { .symlink($0) } ?? ($0.type == .directory ? .directory : .file)) })
        var entries = [Entry(path: try SafeRelativePath("Contents"), directory: true)]
        for entry in original {
            entries.append(Entry(path: try SafeRelativePath("Contents/\(entry.path)"), source: entry.type == .regularFile ? try SafeRelativePath("\(source)/\(entry.path)") : nil,
                link: entry.linkTarget, directory: entry.type == .directory))
        }
        entries.append(Entry(path: try SafeRelativePath("Contents/MacOS"), directory: true))
        for entry in original where entry.path.components.dropLast().joined(separator: "/") == unix {
            let name = entry.path.components.last!
            guard !["wine-wrapper", "wine.real", "x86_64-unix", "x86_64-windows"].contains(name), entry.type != .directory else { throw LauncherError.io("Unsupported Game Mode Unix directory") }
            let override = name == "winecoreaudio.so" ? audio : nil
            let stockSource = entry.type == .regularFile ? try SafeRelativePath("\(source)/\(entry.path)") : nil
            entries.append(Entry(path: try SafeRelativePath("Contents/MacOS/\(name)"),
                source: override ?? stockSource,
                link: override == nil ? entry.linkTarget.map { "../\(unix)/\($0)" } : nil))
        }
        entries.append(Entry(path: try SafeRelativePath("Contents/MacOS/wine-wrapper"), source: try RuntimeJSONFile.relativePath(bundle.wineBinary, root: paths.root)))
        entries.append(Entry(path: try SafeRelativePath("Contents/MacOS/wine.real"), source: try SafeRelativePath("\(source)/\(unix)/wine")))
        entries.append(Entry(path: try SafeRelativePath("Contents/MacOS/x86_64-windows"), link: "../lib/wine/x86_64-windows"))
        entries.append(Entry(path: try SafeRelativePath("Contents/MacOS/x86_64-unix"), link: "."))
        for name in ["bin", "lib", "share"] where original.contains(where: { $0.path.description == name && $0.type == .directory }) {
            entries.append(Entry(path: try SafeRelativePath(name), link: "Contents/\(name)"))
        }
        // Relocated Unix modules retain @loader_path/../.. rpaths. From
        // MacOS that is the app root, so expose every lib entry there too.
        for entry in original where entry.path.components.count == 2 && entry.path.components.first == "lib" {
            let name = entry.path.components.last!
            if entries.contains(where: { $0.path.description == name }) { continue }
            entries.append(Entry(path: try SafeRelativePath(name), link: "Contents/lib/\(name)"))
        }
        entries.append(Entry(path: try SafeRelativePath("Contents/Resources"), directory: true))
        entries.append(Entry(path: try SafeRelativePath("Contents/Resources/AppIcon.icns"), data: icon.icns))
        if let assets = icon.assets { entries.append(Entry(path: try SafeRelativePath("Contents/Resources/Assets.car"), data: assets)) }
        for (language, text) in GameModePrivacy.descriptions.sorted(by: { $0.key < $1.key }) {
            let directory = "Contents/Resources/\(language).lproj"
            entries.append(Entry(path: try SafeRelativePath(directory), directory: true))
            entries.append(Entry(path: try SafeRelativePath("\(directory)/InfoPlist.strings"),
                data: try PropertyListSerialization.data(fromPropertyList: [GameModePrivacy.key: text], format: .xml, options: 0)))
        }
        entries.append(Entry(path: try SafeRelativePath("Contents/Info.plist"), data: try PropertyListSerialization.data(fromPropertyList: plist(game, gameModeEnabled: options.gameModeEnabled), format: .xml, options: 0)))
        try validateDependencies(entries: entries, original: original, source: source, fs: fs, audio: audio)
        return Plan(marker: marker, entries: entries, command: wrapped ? "wine-wrapper" : "wine", options: options)
    }

    private func validateDependencies(entries: [Entry], original: [ContainedFileSystem.TreeEntry], source: SafeRelativePath, fs: ContainedFileSystem, audio: SafeRelativePath?) throws {
        let runtime = GameModeDependencyTree(paths: Set(original.map { $0.path.description }),
            directories: Set(original.filter { $0.type == .directory }.map { $0.path.description }),
            links: Dictionary(uniqueKeysWithValues: original.compactMap { entry in entry.linkTarget.map { (entry.path.description, $0) } }),
            files: Dictionary(uniqueKeysWithValues: try original.filter { $0.type == .regularFile }.map {
                let stock = try SafeRelativePath("\(source)/\($0.path)")
                return ($0.path.description, ($0.path.description == "lib/wine/x86_64-unix/winecoreaudio.so" ? audio : nil) ?? stock)
            }))
        let mirror = GameModeDependencyTree(paths: Set(entries.map { $0.path.description }),
            directories: Set(entries.filter { $0.directory }.map { $0.path.description }),
            links: Dictionary(uniqueKeysWithValues: entries.compactMap { entry in entry.link.map { (entry.path.description, $0) } }),
            files: Dictionary(uniqueKeysWithValues: entries.compactMap { entry in entry.source.map { (entry.path.description, $0) } }))
        let validator = GameModeDependencies(runtime: runtime, mirror: mirror, sourceRoot: source.resolved(against: paths.root).path, fs: fs)
        for entry in entries where entry.path.components.dropLast() == ["Contents", "MacOS"][...] {
            guard let file = entry.source else { continue }
            let data = try fs.readFile(at: file, maxBytes: MachOLoadCommands.maximumFileBytes)
            for image in try MachOLoadCommands.images(in: data) {
                try validator.validate(image, originalParent: file == audio ? ["lib", "wine", "x86_64-unix"] : Array(file.components.dropFirst(source.components.count).dropLast()),
                    helperParent: Array(entry.path.components.dropLast()))
            }
        }
    }

    private func verify(_ helper: GameModeRuntime, destination: SafeRelativePath, plan: Plan, fs: ContainedFileSystem) throws {
        guard let game = GameDefinition.find(plan.marker.gameID), helper == (try result(destination: destination, game: game, command: plan.command, options: plan.options)),
            try JSONDecoder().decode(Marker.self, from: fs.readFile(at: SafeRelativePath("\(destination)/.macgacha-game-mode.json"), maxBytes: 4096)) == plan.marker else { throw LauncherError.io("Game Mode identity changed") }
        let actual = try fs.inspectTree(at: destination, allowingExternalHardLinks: true)
        guard actual.count == plan.entries.count + 1 else { throw LauncherError.io("Game Mode mirror contents changed") }
        let byPath = Dictionary(uniqueKeysWithValues: actual.map { ($0.path.description, $0) })
        for entry in plan.entries {
            guard let found = byPath[entry.path.description], found.linkTarget == entry.link,
                found.type == (entry.directory ? .directory : entry.link == nil ? .regularFile : .other) else { throw LauncherError.io("Game Mode mirror entry changed") }
            let target = try SafeRelativePath("\(destination)/\(entry.path)")
            if let source = entry.source {
                guard try fs.regularFileIdentity(at: source) == fs.regularFileIdentity(at: target) else { throw LauncherError.io("Game Mode mirror inode changed") }
            }
            if let data = entry.data {
                guard try fs.readFile(at: target, maxBytes: max(16384, data.count)) == data else { throw LauncherError.io("Game Mode resources changed") }
            }
        }
    }

    private func plist(_ game: GameDefinition, gameModeEnabled: Bool) -> [String: Any] {
        ["CFBundleIdentifier": "com.lo7ted.macgacha.game.\(game.id)", "CFBundleName": game.gameApplicationName,
         "CFBundleDisplayName": game.gameApplicationName, "CFBundleExecutable": "wine", "CFBundlePackageType": "APPL",
         "CFBundleInfoDictionaryVersion": "6.0", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "2",
         "CFBundleIconName": "AppIcon", "CFBundleIconFile": "AppIcon", "LSApplicationCategoryType": gameModeEnabled ? "public.app-category.games" : "public.app-category.utilities",
         "LSSupportsGameMode": gameModeEnabled, "LSUIElement": true, "CFBundleDevelopmentRegion": "en",
         "CFBundleLocalizations": GameModePrivacy.descriptions.keys.sorted(), GameModePrivacy.key: GameModePrivacy.english]
    }
    private func appPath(_ id: SafeIdentifier, game: GameDefinition) throws -> SafeRelativePath {
        try SafeRelativePath("\(RuntimeJSONFile.relativePath(paths.runtimes, root: paths.root))/GameMode/\(id)/\(SafeIdentifier(game.id))/\(SafeIdentifier(game.id)).app")
    }
    private func result(destination: SafeRelativePath, game: GameDefinition, command: String, options: GameModeOptions) throws -> GameModeRuntime {
        let root = try SafeRelativePath("\(destination)/Contents").resolved(against: paths.root)
        return GameModeRuntime(game: game, root: root, wineBinary: root.appendingPathComponent("MacOS/\(command)"), wineserver: root.appendingPathComponent("bin/wineserver"), gameModeEnabled: options.gameModeEnabled, surroundModule: options.surroundModule)
    }
    static func remove(bundleID: SafeIdentifier, paths: AppPaths, fs: ContainedFileSystem) throws {
        try fs.removeItem(at: SafeRelativePath("\(RuntimeJSONFile.relativePath(paths.runtimes, root: paths.root))/GameMode/\(bundleID)"))
    }
}
