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

    /// Reports invalid version paths relative to AppPaths.root without hiding valid runtimes.
    public func installed() throws -> (components: [InstalledComponent], invalid: [String]) {
        let fs = try ContainedFileSystem(root: paths.root)
        let runtimes = try RuntimeJSONFile.relativePath(paths.runtimes, root: paths.root)
        guard try fs.itemType(at: runtimes) != nil else { return ([], []) }
        var result: [InstalledComponent] = []
        var invalid: [String] = []
        for kind in ComponentKind.allCases {
            let kindPath = try SafeRelativePath(runtimes.description + "/" + kind.rawValue)
            guard try fs.itemType(at: kindPath) != nil else { continue }
            let entries = try fs.contentsOfDirectoryReportingInvalid(at: kindPath)
            guard entries.paths.count + entries.invalid.count <= 1024 else { throw LauncherError.io("Too many runtime directory entries") }
            invalid.append(contentsOf: entries.invalid)
            for versionPath in entries.paths {
                // Installer staging and other hidden directories are never installed versions.
                let version = versionPath.components.last!
                guard version.utf8.first != 0x2e else { continue }
                do {
                    _ = try SafeIdentifier(version)
                    guard try fs.itemType(at: versionPath) == .directory else {
                        throw LauncherError.io("Runtime path is not a directory")
                    }
                    let marker = try SafeRelativePath(versionPath.description + "/.macgacha-component.json")
                    guard let data = try RuntimeJSONFile.read(marker, in: fs, limit: 65_536) else {
                        throw LauncherError.io("Runtime marker is missing")
                    }
                    let record = try JSONDecoder().decode(InstalledComponent.self, from: data)
                    guard record.kind == kind, record.version == version else {
                        throw LauncherError.io("Runtime marker does not match its directory")
                    }
                    result.append(record)
                } catch LauncherError.cancelled {
                    throw LauncherError.cancelled
                } catch {
                    invalid.append(versionPath.description)
                }
            }
        }
        result.sort {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            let order = $0.version.compare($1.version, options: .numeric)
            return order == .orderedSame ? $0.version < $1.version : order == .orderedAscending
        }
        return (result, invalid.sorted())
    }

    public func remove(_ c: InstalledComponent) throws {
        try remove(c, deleting: { try $0.removeItem(at: $1) })
    }

    // A synchronous deletion boundary allows deterministic cancellation/failure tests.
    func remove(_ c: InstalledComponent, deleting: (ContainedFileSystem, SafeRelativePath) throws -> Void) throws {
        let fs = try ContainedFileSystem(root: paths.root)
        let runtimes = try RuntimeJSONFile.relativePath(paths.runtimes, root: paths.root)
        let kind = runtimes.description + "/" + c.kind.rawValue
        let version = try SafeRelativePath(kind + "/" + c.version)
        guard let type = try fs.itemType(at: version) else { return }
        guard type == .directory else { throw LauncherError.io("Runtime path is not a directory") }
        let hidden = try SafeRelativePath(kind + "/.removing-" + UUID().uuidString)
        // Persist the hidden name before deleting; interrupted removals cannot appear installed.
        try fs.moveItem(at: version, to: hidden)
        try deleting(fs, hidden)
    }
}
