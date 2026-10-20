import Foundation
import LauncherCore

public struct InstalledComponent: Codable, Sendable, Equatable {
    public let kind: ComponentKind
    public let version: String
    public let installedAt: Date
    public let source: SourceMode

    public init(kind: ComponentKind, version: String, installedAt: Date, source: SourceMode) throws {
        _ = try SafeIdentifier(version)
        guard installedAt.timeIntervalSinceReferenceDate.isFinite else { throw LauncherError.io("Invalid installation date") }
        self.kind = kind
        self.version = version
        self.installedAt = installedAt
        self.source = source
    }

    private enum CodingKeys: String, CodingKey { case kind, version, installedAt, source }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(kind: c.decode(ComponentKind.self, forKey: .kind), version: c.decode(String.self, forKey: .version),
            installedAt: c.decode(Date.self, forKey: .installedAt), source: c.decode(SourceMode.self, forKey: .source))
    }
}

public struct RuntimeStore: Sendable {
    private let paths: AppPaths

    public init(paths: AppPaths) { self.paths = paths }

    public func installURL(for c: RuntimeComponent) -> URL {
        paths.runtimes.appendingPathComponent(c.kind.rawValue, isDirectory: true)
            .appendingPathComponent(c.version.rawValue, isDirectory: true)
    }

    public func installed() throws -> [InstalledComponent] {
        let fs = try ContainedFileSystem(root: paths.root)
        guard try fs.itemType(at: SafeRelativePath("Runtimes")) != nil else { return [] }
        var result: [InstalledComponent] = []
        for kind in ComponentKind.allCases {
            let kindPath = try SafeRelativePath("Runtimes/\(kind.rawValue)")
            guard try fs.itemType(at: kindPath) != nil else { continue }
            let entries = try fs.contentsOfDirectory(at: kindPath)
            guard entries.count <= 1024 else { throw LauncherError.io("Too many runtime directory entries") }
            for versionPath in entries {
                // Installer staging and other hidden directories are never installed versions.
                let version = versionPath.components.last!
                guard !version.hasPrefix("."), (try? SafeIdentifier(version)) != nil else { continue }
                guard try fs.itemType(at: versionPath) == .directory else { continue }
                let marker = try SafeRelativePath(versionPath.description + "/.macgacha-component.json")
                guard let data = try RuntimeJSONFile.read(marker, in: fs, limit: 65_536) else { continue }
                let record = try JSONDecoder().decode(InstalledComponent.self, from: data)
                guard record.kind == kind, record.version == version else { throw LauncherError.io("Runtime marker does not match its directory") }
                result.append(record)
            }
        }
        return result.sorted { ($0.kind.rawValue, $0.version) < ($1.kind.rawValue, $1.version) }
    }

    public func remove(_ c: InstalledComponent) throws {
        let fs = try ContainedFileSystem(root: paths.root)
        let version = try SafeRelativePath("Runtimes/\(c.kind.rawValue)/\(c.version)")
        guard let type = try fs.itemType(at: version) else { return }
        guard type == .directory else { throw LauncherError.io("Runtime path is not a directory") }
        try fs.removeItem(at: version)
    }
}
