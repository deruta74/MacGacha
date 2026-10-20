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

public struct InvalidRuntimeEntry: Sendable, Equatable {
    /// Nil identifies an invalid kind entry directly below Runtimes.
    public let kind: ComponentKind?
    /// A single filesystem name, retained verbatim for reporting even when unsafe.
    public let rawName: String
    public let reason: String
    fileprivate let reportOnly: Bool

    public init(kind: ComponentKind?, rawName: String, reason: String) {
        self.init(kind: kind, rawName: rawName, reason: reason, reportOnly: false)
    }

    fileprivate init(kind: ComponentKind?, rawName: String, reason: String, reportOnly: Bool) {
        self.kind = kind
        self.rawName = rawName
        self.reason = reason
        self.reportOnly = reportOnly
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.rawName == rhs.rawName && lhs.reason == rhs.reason
    }
}

public struct RuntimeScan: Sendable, Equatable {
    public let components: [InstalledComponent]
    public let invalid: [InvalidRuntimeEntry]

    public init(components: [InstalledComponent], invalid: [InvalidRuntimeEntry]) {
        self.components = components
        self.invalid = invalid
    }
}

public struct RuntimeStore: Sendable {
    private let paths: AppPaths
    private static let invalidPathReason = "Invalid runtime path component"

    public init(paths: AppPaths) { self.paths = paths }

    public func installURL(for c: RuntimeComponent) -> URL {
        paths.runtimes.appendingPathComponent(c.kind.rawValue, isDirectory: true)
            .appendingPathComponent(c.version.rawValue, isDirectory: true)
    }

    public func installed() throws -> [InstalledComponent] { try scan().components }

    /// Invalid kind entries have kind == nil; invalid versions identify their containing kind.
    public func scan() throws -> RuntimeScan {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        let fs = try ContainedFileSystem(root: paths.root)
        guard let runtimes = try runtimesPath(in: fs) else { return RuntimeScan(components: [], invalid: []) }
        var result: [InstalledComponent] = []
        var invalid: [InvalidRuntimeEntry] = []
        for kind in ComponentKind.allCases {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            let kindPath = try SafeRelativePath(runtimes.description + "/" + kind.rawValue)
            do {
                guard let type = try fs.itemType(at: kindPath) else { continue }
                guard type == .directory else { throw LauncherError.io("Runtime kind path is not a directory") }
                let entries = try fs.contentsOfDirectoryReportingInvalid(at: kindPath)
                guard entries.paths.count + entries.invalid.count <= 1024 else {
                    throw LauncherError.io("Too many runtime directory entries")
                }
                let prefixBytes = (kindPath.description + "/").utf8.count
                for rawPath in entries.invalid {
                    let rawName = String(decoding: rawPath.utf8.dropFirst(prefixBytes), as: UTF8.self)
                    invalid.append(InvalidRuntimeEntry(kind: kind, rawName: rawName, reason: Self.invalidPathReason, reportOnly: true))
                }
                for versionPath in entries.paths {
                    guard !Task.isCancelled else { throw LauncherError.cancelled }
                    let version = versionPath.components.last!
                    // Installer staging and other hidden directories are never installed versions.
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
                        invalid.append(InvalidRuntimeEntry(kind: kind, rawName: version, reason: Self.reason(for: error)))
                    }
                }
            } catch LauncherError.cancelled {
                throw LauncherError.cancelled
            } catch {
                invalid.append(InvalidRuntimeEntry(kind: nil, rawName: kind.rawValue, reason: Self.reason(for: error)))
            }
        }
        result.sort {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            let order = $0.version.compare($1.version, options: .numeric)
            return order == .orderedSame ? $0.version < $1.version : order == .orderedAscending
        }
        invalid.sort { ($0.kind?.rawValue ?? "", $0.rawName) < ($1.kind?.rawValue ?? "", $1.rawName) }
        return RuntimeScan(components: result, invalid: invalid)
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

    /// Unsafe raw names remain report-only and throw unsafePath. Already repaired/missing entries are ignored.
    public func removeInvalid(_ entry: InvalidRuntimeEntry) throws {
        let name = try SafeRelativePath(entry.rawName)
        guard name.components.count == 1 else { throw LauncherError.unsafePath(entry.rawName) }
        let current = try scan().invalid.first { $0.kind == entry.kind && $0.rawName == entry.rawName }
        guard let current else { return }
        guard !current.reportOnly else { throw LauncherError.unsafePath(entry.rawName) }
        let fs = try ContainedFileSystem(root: paths.root)
        let runtimes = try RuntimeJSONFile.relativePath(paths.runtimes, root: paths.root)
        let parent = entry.kind.map { runtimes.description + "/" + $0.rawValue } ?? runtimes.description
        let source = try SafeRelativePath(parent + "/" + entry.rawName)
        let hidden = try SafeRelativePath(parent + "/.removing-" + UUID().uuidString)
        // A directory container also allows a source leaf symlink to be unlinked safely inside the tree.
        try fs.createDirectory(at: hidden)
        try fs.moveItem(at: source, to: SafeRelativePath(hidden.description + "/entry"), allowingNonRegularSource: true)
        try fs.removeItem(at: hidden)
    }

    /// Run at startup under the store lock. Incoming directories are then abandoned, not active installs.
    /// Repeating after cancellation or a failed deletion resumes cleanup of the remaining directories.
    public func sweepStaging() throws {
        try sweepStaging(deleting: { try $0.removeItem(at: $1) })
    }

    func sweepStaging(deleting: (ContainedFileSystem, SafeRelativePath) throws -> Void) throws {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        let fs = try ContainedFileSystem(root: paths.root)
        guard let runtimes = try runtimesPath(in: fs) else { return }
        // Invalid kind cleanup stages directly under Runtimes.
        try sweepDirectory(runtimes, in: fs, incoming: false, deleting: deleting)
        for kind in ComponentKind.allCases {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            let path = try SafeRelativePath(runtimes.description + "/" + kind.rawValue)
            do {
                guard try fs.itemType(at: path) == .directory else { continue }
            } catch LauncherError.unsafePath {
                continue // Invalid kinds are reported by scan(), never traversed by the sweep.
            }
            try sweepDirectory(path, in: fs, incoming: true, deleting: deleting)
        }
    }

    private func sweepDirectory(_ path: SafeRelativePath, in fs: ContainedFileSystem, incoming: Bool,
        deleting: (ContainedFileSystem, SafeRelativePath) throws -> Void) throws {
        let entries = try fs.contentsOfDirectoryReportingInvalid(at: path)
        guard entries.paths.count + entries.invalid.count <= 1024 else { throw LauncherError.io("Too many runtime directory entries") }
        for child in entries.paths {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            let name = child.components.last!
            guard name.utf8.starts(with: ".removing-".utf8) || (incoming && name.utf8.starts(with: ".incoming-".utf8)) else { continue }
            do {
                guard try fs.itemType(at: child) == .directory else { continue }
            } catch LauncherError.unsafePath { continue }
            try deleting(fs, child)
        }
    }

    private func runtimesPath(in fs: ContainedFileSystem) throws -> SafeRelativePath? {
        let path = try RuntimeJSONFile.relativePath(paths.runtimes, root: paths.root)
        guard let type = try fs.itemType(at: path) else { return nil }
        guard type == .directory else { throw LauncherError.unsafePath(path.resolved(against: paths.root).path) }
        return path
    }

    private static func reason(for error: any Error) -> String {
        switch error {
        case LauncherError.fileTooLarge: return "Runtime marker exceeds size limit"
        case LauncherError.unsafePath: return "Unsafe path or symbolic link"
        case LauncherError.io(let message): return message
        case is DecodingError: return "Invalid runtime marker JSON"
        default: return "Cannot inspect runtime entry"
        }
    }
}
