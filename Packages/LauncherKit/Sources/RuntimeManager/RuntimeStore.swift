import Darwin
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
        guard try RuntimeJSONFile.directoryExists(paths.runtimes) else { return [] }
        var result: [InstalledComponent] = []
        for kind in ComponentKind.allCases {
            let root = paths.runtimes.appendingPathComponent(kind.rawValue, isDirectory: true)
            guard try RuntimeJSONFile.directoryExists(root) else { continue }
            guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]) else { throw LauncherError.io("Cannot enumerate installed runtimes") }
            var count = 0
            for case let versionURL as URL in entries {
                count += 1
                guard count <= 1024 else { throw LauncherError.io("Too many runtime directory entries") }
                let version = versionURL.lastPathComponent
                guard (try? SafeIdentifier(version)) != nil else { continue }
                var info = stat()
                guard lstat(versionURL.path, &info) == 0 else {
                    if errno == ENOENT { continue }
                    throw LauncherError.io("Cannot inspect installed runtime")
                }
                guard info.st_mode & S_IFMT != S_IFLNK else { throw LauncherError.unsafePath(versionURL.path) }
                guard info.st_mode & S_IFMT == S_IFDIR else { continue }
                let marker = versionURL.appendingPathComponent(".macgacha-component.json")
                guard let data = try RuntimeJSONFile.read(marker, limit: 65_536) else { continue }
                let record = try JSONDecoder().decode(InstalledComponent.self, from: data)
                guard record.kind == kind, record.version == version else { throw LauncherError.io("Runtime marker does not match its directory") }
                result.append(record)
            }
        }
        return result.sorted { ($0.kind.rawValue, $0.version) < ($1.kind.rawValue, $1.version) }
    }

    public func remove(_ c: InstalledComponent) throws {
        let kind = paths.runtimes.appendingPathComponent(c.kind.rawValue, isDirectory: true)
        let version = kind.appendingPathComponent(c.version, isDirectory: true)
        guard try RuntimeJSONFile.directoryExists(paths.runtimes),
              try RuntimeJSONFile.directoryExists(kind), try RuntimeJSONFile.directoryExists(version) else { return }
        try FileManager.default.removeItem(at: version)
    }
}
