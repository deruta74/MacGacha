// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine

/// One OS-backed lease covers component acquisition, assembly, publication and cleanup.
final class RuntimeStoreLease: Sendable {
    let lock: InstallLock
    init(store: RuntimeStore) throws {
        let fs = try ContainedFileSystem(root: store.paths.root)
        let path = try RuntimeJSONFile.relativePath(store.paths.runtimes, root: store.paths.root)
        try fs.createDirectory(at: path)
        lock = try InstallLock(fs: fs, path: SafeRelativePath("\(path)/.lock"))
    }
}

public struct InstalledRuntimeBundle: Sendable, Equatable {
    public let id: SafeIdentifier
    public let root: URL
    public let wineBinary: URL
    public let digest: Digest
    public let source: SourceMode
    public init(id: SafeIdentifier, root: URL, wineBinary: URL, digest: Digest, source: SourceMode) {
        self.id = id; self.root = root; self.wineBinary = wineBinary; self.digest = digest; self.source = source
    }
}

private struct BundleMarker: Codable {
    let id: SafeIdentifier
    let digest: Digest
    let componentsDigest: Digest
    let source: SourceMode
}

public struct RuntimeBundleManager: Sendable {
    private let manifest: RuntimeManifest
    private let store: RuntimeStore
    private let consent: ConsentStore
    private let installer: ComponentInstaller
    private let runner: any ProcessRunner
    private let disk: any DiskSpaceProbe
    private let failurePoint: @Sendable (ComponentInstaller.PublishPoint) throws -> Void

    public init(manifest: RuntimeManifest, store: RuntimeStore, consent: ConsentStore, installer: ComponentInstaller,
        runner: any ProcessRunner = SystemProcessRunner(), disk: any DiskSpaceProbe = SystemDiskSpaceProbe(),
        failurePoint: @escaping @Sendable (ComponentInstaller.PublishPoint) throws -> Void = { _ in }) {
        self.manifest = manifest; self.store = store; self.consent = consent; self.installer = installer
        self.runner = runner; self.disk = disk; self.failurePoint = failurePoint
    }

    public func installed(_ bundle: RuntimeBundle) async throws -> InstalledRuntimeBundle? {
        try await BlockingIO.run {
            let lease = try RuntimeStoreLease(store: store)
            defer { withExtendedLifetime(lease) {} }
            return try inspect(bundle)
        }
    }

    @discardableResult
    public func install(_ bundle: RuntimeBundle, from candidate: GPTKCandidate? = nil,
        progress: @escaping @Sendable (OperationEvent) -> Void = { _ in }) async throws -> InstalledRuntimeBundle {
        try await BlockingIO.run {
            let components = try selected(bundle)
            // Check even when all components are already installed, including the import path.
            for c in components where c.consent != nil {
                guard await consent.isAccepted(.appleGPTK, version: c.version.rawValue, termsRevision: c.license.termsRevision) else {
                    throw LauncherError.consentRequired(c.id.rawValue)
                }
            }
            guard candidate == nil || bundle.backend == .d3dmetal else { throw LauncherError.io("Only D3DMetal supports GPTK import") }
            let lease = try RuntimeStoreLease(store: store)
            defer { withExtendedLifetime(lease) {} }
            try store.sweepStaging()
            for c in components {
                if try componentRecord(c) == nil {
                    guard candidate == nil && c.sourceMode == .download else {
                        throw LauncherError.io("Install the base Wine bundle before importing D3DMetal")
                    }
                    for try await event in installer.install(c, lease: lease) {
                        if event != .phase(.completed) { progress(event) }
                    }
                }
            }
            if candidate == nil, let ready = try inspect(bundle) { progress(.phase(.completed)); return ready }
            let fs = try ContainedFileSystem(root: store.paths.root)
            let digest = try fingerprint(bundle, components: components)
            guard let wine = components.first(where: { $0.wineBinary != nil }), let binary = wine.wineBinary else {
                throw LauncherError.io("Bundle Wine component is missing")
            }
            let winePath = try RuntimeJSONFile.relativePath(store.installURL(for: wine), root: store.paths.root)
            if bundle.backend == .d3dmetal, candidate == nil {
                let stale = try bundlePath(bundle)
                if try fs.itemType(at: stale) != nil {
                    let hidden = try SafeRelativePath("\(bundleParent())/.removing-\(UUID().uuidString)")
                    try fs.moveItem(at: stale, to: hidden); try fs.removeItem(at: hidden)
                }
                try await Self.verifyMetal(fs: fs, root: winePath, runner: runner)
                progress(.phase(.completed))
                return InstalledRuntimeBundle(id: bundle.id, root: store.installURL(for: wine),
                    wineBinary: binary.resolved(against: store.installURL(for: wine)), digest: digest, source: .download)
            }
            let parent = try bundleParent()
            try fs.createDirectory(at: parent)
            let incoming = try SafeRelativePath("\(parent)/.incoming-\(UUID().uuidString)")
            let destination = try bundlePath(bundle)
            var uncertain = false
            do {
                let source = try RuntimeTree(fs: fs, root: winePath)
                var overlays: [(RuntimeTree, SafeRelativePath)] = []
                var runtimeDigest = digest
                for c in components {
                    let root = try RuntimeJSONFile.relativePath(store.installURL(for: c), root: store.paths.root)
                    for overlay in c.overlay {
                        overlays.append((try RuntimeTree(fs: fs, root: SafeRelativePath("\(root)/\(overlay.source)")), overlay.destination))
                    }
                }
                if let candidate {
                    let sourceFS = try ContainedFileSystem(root: candidate.root)
                    let framework = try RuntimeTree(fs: sourceFS, root: SafeRelativePath("D3DMetal.framework"))
                    overlays.append((framework, try SafeRelativePath("lib/external/D3DMetal.framework")))
                    var hash = StreamingHasher(.sha256); hash.update(Data(digest.hex.utf8)); hash.update(Data(try framework.digest().hex.utf8))
                    runtimeDigest = hash.finalize()
                }
                var required = source.bytes
                for (tree, _) in overlays {
                    let (sum, overflow) = required.addingReportingOverflow(tree.bytes)
                    guard !overflow else { throw LauncherError.io("Runtime space budget overflow") }
                    required = sum
                }
                // Reserve a complete copy: APFS cloning is an optimization, never a space promise.
                let available = try disk.availableBytes(at: store.paths.runtimes)
                guard available >= required else { throw LauncherError.insufficientSpace(required: required, available: available) }
                progress(.phase(.staging))
                try source.copy(to: incoming, in: fs)
                for (tree, path) in overlays {
                    let target = try SafeRelativePath("\(incoming)/\(path)")
                    // DXMT directories merge; framework import replaces the complete framework.
                    if candidate != nil { try fs.removeItem(at: target) }
                    try tree.copy(to: target, in: fs, overlay: candidate == nil)
                }
                _ = try RuntimeTree(fs: fs, root: incoming)
                if bundle.backend == .d3dmetal { try await Self.verifyMetal(fs: fs, root: incoming, runner: runner) }
                try fs.removeQuarantineRecursively(at: incoming)
                try fs.synchronizeTree(at: incoming)
                let marker = BundleMarker(id: bundle.id, digest: runtimeDigest, componentsDigest: digest, source: candidate == nil ? .download : .importFromGPTK)
                let markerPath = try SafeRelativePath("\(incoming)/.macgacha-bundle.json")
                try fs.writeAtomically(JSONEncoder().encode(marker), to: markerPath)
                try fs.fullSync(at: markerPath)
                progress(.phase(.committing))
                try RuntimePublication.publish(fs: fs, incoming: incoming, destination: destination,
                    uncertain: &uncertain, failurePoint: failurePoint)
                try fs.removeItem(at: incoming)
                guard let result = try inspect(bundle) else { throw LauncherError.io("Bundle publication failed") }
                progress(.phase(.completed))
                return result
            } catch {
                if !uncertain { try? await BlockingIO.finish { try fs.removeItem(at: incoming) } }
                if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
                throw error
            }
        }
    }

    public func createPrefix(game: String, bundle: RuntimeBundle) async throws -> URL {
        try await BlockingIO.run {
            let lease = try RuntimeStoreLease(store: store)
            defer { withExtendedLifetime(lease) {} }
            guard let installed = try inspect(bundle) else { throw LauncherError.io("Runtime bundle is not ready") }
            return try await PrefixManager(paths: store.paths, runner: runner).createPrefix(game: game, bundle: installed)
        }
    }

    public func remove(_ bundle: RuntimeBundle) async throws {
        try await BlockingIO.run {
            let components = try selected(bundle)
            let lease = try RuntimeStoreLease(store: store)
            let pins = try RuntimeRemovalLease(paths: store.paths, componentIDs: components.map { $0.id.rawValue })
            defer { withExtendedLifetime((lease, pins)) {} }
            let fs = try ContainedFileSystem(root: store.paths.root)
            let path = try bundlePath(bundle)
            if try fs.itemType(at: path) != nil {
                let hidden = try SafeRelativePath("\(bundleParent())/.removing-\(UUID().uuidString)")
                try fs.moveItem(at: path, to: hidden); try fs.removeItem(at: hidden)
            }
            let shared = Set(manifest.bundles.filter { $0.id != bundle.id }.flatMap(\.components))
            for c in components where !shared.contains(c.id) {
                if let installed = try componentRecord(c) { try store.removeUnderLease(installed, componentLease: pins) }
            }
        }
    }

    private func selected(_ bundle: RuntimeBundle) throws -> [RuntimeComponent] {
        guard let authoritative = manifest.bundles.first(where: { $0.id == bundle.id }) else { throw LauncherError.io("Unknown runtime bundle") }
        // Always use the manifest's components, not a caller-supplied selection.
        guard bundle == authoritative else {
            throw LauncherError.io("Runtime bundle mismatch")
        }
        return authoritative.components.compactMap { id in manifest.components.first { $0.id == id } }
    }

    private func componentRecord(_ c: RuntimeComponent) throws -> InstalledComponent? {
        guard let record = try store.installed().first(where: { $0.kind == c.kind && $0.version == c.version.rawValue }),
            record.archiveDigest == c.sha256, record.publicationID != nil else { return nil }
        return record
    }

    private func fingerprint(_ bundle: RuntimeBundle, components: [RuntimeComponent]) throws -> Digest {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var hash = StreamingHasher(.sha256)
        hash.update(try encoder.encode(bundle))
        for c in components {
            guard let record = try componentRecord(c) else { throw LauncherError.io("Bundle component is missing") }
            hash.update(try encoder.encode(c)); hash.update(try encoder.encode(record))
        }
        return hash.finalize()
    }

    private func inspect(_ bundle: RuntimeBundle) throws -> InstalledRuntimeBundle? {
        let components = try selected(bundle)
        for c in components { if try componentRecord(c) == nil { return nil } }
        let digest = try fingerprint(bundle, components: components)
        let fs = try ContainedFileSystem(root: store.paths.root)
        let assembled = try bundlePath(bundle)
        var root: URL
        var source = SourceMode.download
        var runtimeDigest = digest
        if try fs.itemType(at: assembled) != nil {
            guard let data = try RuntimeJSONFile.read(SafeRelativePath("\(assembled)/.macgacha-bundle.json"), in: fs, limit: 65_536),
                let marker = try? JSONDecoder().decode(BundleMarker.self, from: data), marker.id == bundle.id,
                marker.componentsDigest == digest else { return nil }
            root = assembled.resolved(against: store.paths.root); source = marker.source; runtimeDigest = marker.digest
        } else if bundle.backend == .d3dmetal, let component = components.first {
            root = store.installURL(for: component)
        } else { return nil }
        guard let binary = components.first(where: { $0.wineBinary != nil })?.wineBinary else { return nil }
        let path = try RuntimeJSONFile.relativePath(binary.resolved(against: root), root: store.paths.root)
        guard try fs.itemType(at: path) == .regularFile else { return nil }
        return InstalledRuntimeBundle(id: bundle.id, root: root, wineBinary: binary.resolved(against: root), digest: runtimeDigest, source: source)
    }

    private func bundleParent() throws -> SafeRelativePath {
        try SafeRelativePath("\(RuntimeJSONFile.relativePath(store.paths.runtimes, root: store.paths.root))/bundles")
    }
    private func bundlePath(_ bundle: RuntimeBundle) throws -> SafeRelativePath { try SafeRelativePath("\(bundleParent())/\(bundle.id)") }

    static func verifyMetal(fs: ContainedFileSystem, root: SafeRelativePath, runner: any ProcessRunner) async throws {
        try await BlockingIO.run { try await verifyMetalOnIO(fs: fs, root: root, runner: runner) }
    }

    private static func verifyMetalOnIO(fs: ContainedFileSystem, root: SafeRelativePath, runner: any ProcessRunner) async throws {
        let framework = try SafeRelativePath("\(root)/lib/external/D3DMetal.framework")
        guard try fs.itemType(at: framework) == .directory else { throw LauncherError.io("D3DMetal framework is missing") }
        let result = try await runner.run(URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--strict", try fs.directoryURL(at: framework).path], environment: [:], currentDirectory: nil)
        guard result.exitCode == 0 else { throw LauncherError.io("D3DMetal signature verification failed") }
    }
}

/// A bounded, no-follow tree snapshot. Clone files individually through pinned descriptors;
/// overlay writes replace cloned inodes rather than changing the source component.
private struct RuntimeTree {
    let fs: ContainedFileSystem
    let root: SafeRelativePath
    let entries: [ContainedFileSystem.TreeEntry]
    let bytes: Int64
    init(fs: ContainedFileSystem, root: SafeRelativePath) throws {
        self.fs = fs; self.root = root
        entries = try fs.inspectTree(at: root)
        try ArchivePolicy.validate(entries.map { ArchiveEntry(path: $0.path.description,
            kind: $0.linkTarget.map { .symlink($0) } ?? ($0.type == .directory ? .directory : .file)) })
        var size: Int64 = 0
        for entry in entries where entry.type == .regularFile {
            let count = try fs.size(at: SafeRelativePath("\(root)/\(entry.path)")) ?? 0
            guard count <= (64 << 30) - size else { throw LauncherError.io("Runtime tree exceeds size limit") }
            size += count
        }
        bytes = size
    }
    func digest() throws -> Digest {
        var hash = StreamingHasher(.sha256)
        for entry in entries.sorted(by: { $0.path.description < $1.path.description }) {
            hash.update(Data(entry.path.description.utf8)); hash.update(Data([0]))
            if let link = entry.linkTarget { hash.update(Data(link.utf8)) }
            else if entry.type == .regularFile { try fs.readFile(at: SafeRelativePath("\(root)/\(entry.path)")) { hash.update($0) } }
        }
        return hash.finalize()
    }
    func copy(to target: SafeRelativePath, in destination: ContainedFileSystem, overlay: Bool = false) throws {
        try destination.createDirectory(at: target)
        for entry in entries {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            if entry.path.description == ".macgacha-component.json" { continue }
            let output = try SafeRelativePath("\(target)/\(entry.path)")
            if entry.type == .directory { try destination.createDirectory(at: output) }
            else {
                if overlay { try destination.removeItem(at: output) }
                if let link = entry.linkTarget { try destination.createSymbolicLink(at: output, target: link) }
                else { _ = try fs.copyRegularFile(at: SafeRelativePath("\(root)/\(entry.path)"), to: output,
                    in: destination, maxBytes: bytes, preferClone: true) }
            }
        }
    }
}
