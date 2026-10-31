// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine

public struct InstalledComponent: Codable, Sendable, Equatable {
    public let kind: ComponentKind
    public let version: String
    public let installedAt: Date
    public let source: SourceMode
    public let archiveDigest: Digest?
    public let publicationID: UUID?

    public init(kind: ComponentKind, version: String, installedAt: Date, source: SourceMode, archiveDigest: Digest? = nil, publicationID: UUID? = UUID()) throws {
        _ = try SafeIdentifier(version)
        guard installedAt.timeIntervalSinceReferenceDate.isFinite else { throw LauncherError.io("Invalid installation date") }
        self.kind = kind
        self.version = version
        self.installedAt = installedAt
        self.source = source
        self.archiveDigest = archiveDigest; self.publicationID = publicationID
    }

    private enum CodingKeys: String, CodingKey { case kind, version, installedAt, source, archiveDigest, publicationID }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(kind: c.decode(ComponentKind.self, forKey: .kind), version: c.decode(String.self, forKey: .version),
            installedAt: c.decode(Date.self, forKey: .installedAt), source: c.decode(SourceMode.self, forKey: .source),
            archiveDigest: c.decodeIfPresent(Digest.self, forKey: .archiveDigest), publicationID: c.decodeIfPresent(UUID.self, forKey: .publicationID))
    }
}

public struct InvalidRuntimeEntry: Sendable, Equatable {
    /// Nil identifies an invalid kind entry directly below Runtimes.
    public let kind: ComponentKind?
    /// A single filesystem name, retained verbatim for reporting even when unsafe.
    public let rawName: String
    /// Why the entry is invalid, localized: the Runtimes list shows it to the user.
    public let reason: String
    /// Inspection failures are report-only; true requires a positively identified invalid entry.
    public let removable: Bool

    public init(kind: ComponentKind?, rawName: String, reason: String, removable: Bool = false) {
        self.kind = kind
        self.rawName = rawName
        self.reason = reason
        self.removable = removable
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
    let paths: AppPaths
    private static let invalidPathReason = String(localized: "Invalid runtime path component", bundle: .module)

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
        let kinds = try fs.contentsOfDirectoryReportingInvalid(at: runtimes)
        let kindPrefixBytes = (runtimes.description + "/").utf8.count
        for rawPath in kinds.invalid {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            let rawName = String(decoding: rawPath.utf8.dropFirst(kindPrefixBytes), as: UTF8.self)
            guard rawName.utf8.first != 0x2e else { continue }
            invalid.append(InvalidRuntimeEntry(kind: nil, rawName: rawName, reason: Self.invalidPathReason))
        }
        for kindPath in kinds.paths {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            let rawName = kindPath.components.last!
            guard rawName.utf8.first != 0x2e else { continue }
            if ["bundles", "GameMode"].contains(rawName) { continue }
            guard let kind = ComponentKind(rawValue: rawName) else {
                invalid.append(InvalidRuntimeEntry(kind: nil, rawName: rawName, reason: String(localized: "Unknown runtime kind", bundle: .module)))
                continue
            }
            do {
                guard let type = try fs.itemType(at: kindPath, allowingLeafSymlink: true) else { continue }
                guard type == .directory else {
                    invalid.append(InvalidRuntimeEntry(kind: nil, rawName: kind.rawValue,
                        reason: String(localized: "Runtime kind path is not a directory", bundle: .module), removable: true))
                    continue
                }
                let entries = try fs.contentsOfDirectoryReportingInvalid(at: kindPath)
                guard entries.paths.count + entries.invalid.count <= 1024 else {
                    throw LauncherError.io(String(localized: "Too many runtime directory entries", bundle: .module))
                }
                let prefixBytes = (kindPath.description + "/").utf8.count
                for rawPath in entries.invalid {
                    let rawName = String(decoding: rawPath.utf8.dropFirst(prefixBytes), as: UTF8.self)
                    invalid.append(InvalidRuntimeEntry(kind: kind, rawName: rawName, reason: Self.invalidPathReason))
                }
                for versionPath in entries.paths {
                    guard !Task.isCancelled else { throw LauncherError.cancelled }
                    let version = versionPath.components.last!
                    // Installer staging and other hidden directories are never installed versions.
                    guard version.utf8.first != 0x2e else { continue }
                    do {
                        result.append(try inspectVersion(at: versionPath, kind: kind, version: version, in: fs))
                    } catch LauncherError.cancelled {
                        throw LauncherError.cancelled
                    } catch let failure as BadVersion {
                        invalid.append(InvalidRuntimeEntry(kind: kind, rawName: version, reason: failure.reason, removable: true))
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

    /// The shared pin and exclusive removal paths must use identical stable files.
    /// Validate every ID before creating anything; a failed multi-lock attempt
    /// releases its earlier locks. Sorting gives every caller the same order.
    package static func componentLocks(paths: AppPaths, componentIDs: [String], mode: InstallLock.Mode) throws -> [InstallLock] {
        let ids = try Set(componentIDs.map { try SafeIdentifier($0).rawValue }).sorted()
        let fs = try ContainedFileSystem(root: paths.root)
        return try ids.map { try InstallLock(fs: fs, path: SafeRelativePath("Runtimes/.pin-\($0).lock"), mode: mode) }
    }

    public func remove(_ c: InstalledComponent) throws {
        let lease = try RuntimeStoreLease(store: self)
        defer { withExtendedLifetime(lease) {} }
        try removeUnderLease(c)
    }

    func removeUnderLease(_ c: InstalledComponent, componentLease: RuntimeRemovalLease? = nil) throws {
        try remove(c, componentLease: componentLease, deleting: { try $0.removeItem(at: $1) })
    }

    // A synchronous deletion boundary allows deterministic cancellation/failure tests.
    func remove(_ c: InstalledComponent, deleting: (ContainedFileSystem, SafeRelativePath) throws -> Void) throws {
        try remove(c, componentLease: nil, deleting: deleting)
    }

    private func remove(_ c: InstalledComponent, componentLease: RuntimeRemovalLease?,
        deleting: (ContainedFileSystem, SafeRelativePath) throws -> Void) throws {
        let id = "\(c.kind.idPrefix)-\(c.version)"
        let pins = try componentLease ?? RuntimeRemovalLease(paths: paths, componentIDs: [id])
        guard pins.componentIDs.contains(id) else { throw LauncherError.io("Missing runtime removal exclusion") }
        defer { withExtendedLifetime(pins) {} }
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

    /// Unsafe names throw unsafePath; inspection failures throw io. Repaired/missing entries are ignored.
    public func removeInvalid(_ entry: InvalidRuntimeEntry) throws {
        try LaunchMutationBarrier.requireNoJournals(paths: paths)
        let name = try SafeRelativePath(entry.rawName)
        guard name.components.count == 1 else { throw LauncherError.unsafePath(entry.rawName) }
        guard entry.removable else { throw LauncherError.io("Runtime entry is report-only") }
        let current = try scan().invalid.first { $0.kind == entry.kind && $0.rawName == entry.rawName }
        guard let current else { return }
        guard current.removable else { throw LauncherError.io("Runtime entry is report-only") }
        let componentLease: RuntimeRemovalLease?
        if let kind = entry.kind, let version = try? SafeIdentifier(entry.rawName) {
            componentLease = try RuntimeRemovalLease(paths: paths, componentIDs: ["\(kind.idPrefix)-\(version)"])
        } else { componentLease = nil }
        defer { withExtendedLifetime(componentLease) {} }
        let fs = try ContainedFileSystem(root: paths.root)
        let runtimes = try RuntimeJSONFile.relativePath(paths.runtimes, root: paths.root)
        let parent = entry.kind.map { runtimes.description + "/" + $0.rawValue } ?? runtimes.description
        let source = try SafeRelativePath(parent + "/" + entry.rawName)
        if entry.kind == nil {
            guard let type = try fs.itemType(at: source, allowingLeafSymlink: true) else { return }
            guard type != .directory else { throw LauncherError.io("Runtime kind directories cannot be removed as invalid entries") }
        }
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

    func sweepStaging(holding pins: RuntimeRemovalLease? = nil, deleting: (ContainedFileSystem, SafeRelativePath) throws -> Void) throws {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        try LaunchMutationBarrier.requireNoJournals(paths: paths)
        let fs = try ContainedFileSystem(root: paths.root)
        guard let runtimes = try runtimesPath(in: fs) else { return }
        // Invalid kind cleanup stages directly under Runtimes.
        try sweepDirectory(runtimes, in: fs, incoming: false, deleting: deleting)
        let downloads = try SafeRelativePath("\(runtimes)/.downloads")
        if let type = try fs.itemType(at: downloads) {
            guard type == .directory else { throw LauncherError.unsafePath(downloads.description) }
            let abandoned = try SafeRelativePath("\(runtimes)/.removing-\(UUID().uuidString)")
            try fs.moveItem(at: downloads, to: abandoned)
            try deleting(fs, abandoned)
        }
        for name in ComponentKind.allCases.map(\.rawValue) + ["bundles"] {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            let path = try SafeRelativePath(runtimes.description + "/" + name)
            do {
                guard try fs.itemType(at: path) == .directory else { continue }
            } catch LauncherError.unsafePath {
                continue // Invalid kinds are reported by scan(), never traversed by the sweep.
            }
            try sweepDirectory(path, in: fs, incoming: true, deleting: deleting)
        }
        try GameModeSweep.run(paths: paths, fs: fs, holding: pins, deleting: deleting)
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

    private struct BadVersion: Error {
        let reason: String
    }

    private func inspectVersion(at path: SafeRelativePath, kind: ComponentKind, version: String,
        in fs: ContainedFileSystem) throws -> InstalledComponent {
        do { _ = try SafeIdentifier(version) }
        catch { throw BadVersion(reason: String(localized: "Invalid runtime version identifier", bundle: .module)) }
        guard let type = try fs.itemType(at: path, allowingLeafSymlink: true) else {
            throw LauncherError.io(String(localized: "Runtime entry disappeared during inspection", bundle: .module))
        }
        guard type == .directory else { throw BadVersion(reason: String(localized: "Runtime path is not a directory", bundle: .module)) }
        let marker = try SafeRelativePath(path.description + "/.macgacha-component.json")
        let data: Data?
        do { data = try RuntimeJSONFile.read(marker, in: fs, limit: 65_536) }
        catch LauncherError.fileTooLarge { throw BadVersion(reason: String(localized: "Runtime marker exceeds size limit", bundle: .module)) }
        catch LauncherError.unsafePath { throw BadVersion(reason: String(localized: "Unsafe runtime marker path", bundle: .module)) }
        guard let data else { throw BadVersion(reason: String(localized: "Runtime marker is missing", bundle: .module)) }
        let record: InstalledComponent
        do { record = try JSONDecoder().decode(InstalledComponent.self, from: data) }
        catch { throw BadVersion(reason: String(localized: "Invalid runtime marker JSON", bundle: .module)) }
        guard record.kind == kind, record.version == version else {
            throw BadVersion(reason: String(localized: "Runtime marker does not match its directory", bundle: .module))
        }
        return record
    }

    private func runtimesPath(in fs: ContainedFileSystem) throws -> SafeRelativePath? {
        let path = try RuntimeJSONFile.relativePath(paths.runtimes, root: paths.root)
        guard let type = try fs.itemType(at: path) else { return nil }
        guard type == .directory else { throw LauncherError.unsafePath(path.resolved(against: paths.root).path) }
        return path
    }

    private static func reason(for error: any Error) -> String {
        switch error {
        case LauncherError.fileTooLarge: return String(localized: "Runtime marker exceeds size limit", bundle: .module)
        case LauncherError.unsafePath: return String(localized: "Unsafe path or symbolic link", bundle: .module)
        case LauncherError.io(let message): return message
        case is DecodingError: return String(localized: "Invalid runtime marker JSON", bundle: .module)
        default: return String(localized: "Cannot inspect runtime entry", bundle: .module)
        }
    }
}

/// A bundle preflights every component before removing any published tree and
/// passes this exclusion through component cleanup without relocking itself.
final class RuntimeRemovalLease: Sendable {
    let componentIDs: Set<String>
    private let locks: [InstallLock]
    init(paths: AppPaths, componentIDs: [String]) throws {
        locks = try RuntimeStore.componentLocks(paths: paths, componentIDs: componentIDs, mode: .exclusive)
        try LaunchMutationBarrier.requireNoJournals(paths: paths)
        self.componentIDs = Set(componentIDs)
    }
}
