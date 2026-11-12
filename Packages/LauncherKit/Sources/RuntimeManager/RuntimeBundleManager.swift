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
    public let importedFramework: ImportedD3DMetalIdentity?
    public init(id: SafeIdentifier, root: URL, wineBinary: URL, digest: Digest, source: SourceMode,
        importedFramework: ImportedD3DMetalIdentity? = nil) {
        self.id = id; self.root = root; self.wineBinary = wineBinary; self.digest = digest; self.source = source
        self.importedFramework = importedFramework
    }
}

public struct ImportedD3DMetalIdentity: Codable, Equatable, Sendable {
    public let version: String?
    public let digest: Digest
    public init(version: String?, digest: Digest) { self.version = version; self.digest = digest }
}

private struct BundleMarker: Codable {
    let id: SafeIdentifier
    let digest: Digest
    let componentsDigest: Digest
    let source: SourceMode
    let importedFramework: ImportedD3DMetalIdentity?
}

public struct RuntimeStagedUpdate: Sendable {
    let token: UUID
    let bundle: RuntimeBundle?
    let components: [RuntimeComponent]
    let expected: [SafeIdentifier: InstalledComponent]
    let importedBundle: RuntimeBundle?
    let importedSource: InstalledRuntimeBundle?
    let lifetime: RuntimeAutomaticStageLease
}

final class RuntimeAutomaticStageLease: Sendable {
    let lock: InstallLock
    init(fs: ContainedFileSystem) throws { lock = try InstallLock(fs: fs, path: SafeRelativePath(".stage.lock")) }
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

    /// All downloads, extraction, assembly and signature checks use an isolated
    /// store. No active-store publication lease survives into that work.
    public func stage(_ bundle: RuntimeBundle, carryingImportedFrameworkFrom previous: RuntimeBundle? = nil,
        progress: @escaping @Sendable (OperationEvent) -> Void = { _ in }) async throws -> RuntimeStagedUpdate {
        try await stage(bundle: bundle, components: selected(bundle), previous: previous, progress: progress)
    }
    public func stage(_ component: RuntimeComponent, progress: @escaping @Sendable (OperationEvent) -> Void = { _ in }) async throws -> RuntimeStagedUpdate {
        guard let authoritative = manifest.component(id: component.id), try catalogBytes(authoritative) == catalogBytes(component) else {
            throw LauncherError.io("Unknown automatic component")
        }
        return try await stage(bundle: nil, components: [component], previous: nil, progress: progress)
    }
    private func stage(bundle: RuntimeBundle?, components: [RuntimeComponent], previous: RuntimeBundle?,
        progress: @escaping @Sendable (OperationEvent) -> Void) async throws -> RuntimeStagedUpdate {
        let token = UUID(), relative = try automaticStagePath(token)
        let stagePaths = AppPaths(root: relative.resolved(against: store.paths.root))
        let stageStore = RuntimeStore(paths: stagePaths)
        let prepared = try await BlockingIO.run { () throws -> (RuntimeAutomaticStageLease, [SafeIdentifier: InstalledComponent]) in
            let sourceFS = try ContainedFileSystem(root: store.paths.root).pinRoot()
            try sourceFS.createDirectory(at: relative)
            var prepared = false
            defer { if !prepared { try? sourceFS.removeItem(at: relative) } }
            let targetFS = try ContainedFileSystem(root: stagePaths.root).pinRoot()
            let lifetime = try RuntimeAutomaticStageLease(fs: targetFS)
            var expected: [SafeIdentifier: InstalledComponent] = [:]
            // Shared component pins permit the active runtime's launch/session
            // readers while preserving each immutable source during cloning.
            let pins = try RuntimeStore.componentLocks(paths: store.paths, componentIDs: components.map { $0.id.rawValue }, mode: .shared)
            defer { withExtendedLifetime(pins) {} }
            var copies: [(RuntimeTree, SafeRelativePath, SafeRelativePath)] = []
            var required: Int64 = 0
            for component in components {
                guard let record = try componentRecord(component) else { continue }
                expected[component.id] = record
                let source = try RuntimeJSONFile.relativePath(store.installURL(for: component), root: store.paths.root)
                let destination = try RuntimeJSONFile.relativePath(stageStore.installURL(for: component), root: stagePaths.root)
                let tree = try RuntimeTree(fs: sourceFS, root: source, allowingExternalHardLinks: true)
                let (sum, overflow) = required.addingReportingOverflow(tree.bytes)
                guard !overflow else { throw LauncherError.io("Automatic staging budget overflow") }
                required = sum; copies.append((tree, source, destination))
            }
            let available = try disk.availableBytes(at: stagePaths.root)
            guard available >= required else { throw LauncherError.insufficientSpace(required: required, available: available) }
            for (tree, source, destination) in copies {
                try tree.copy(to: destination, in: targetFS)
                let receipt = try sourceFS.readFile(at: SafeRelativePath("\(source)/.macgacha-component.json"), maxBytes: 65_536)
                try targetFS.writeAtomically(receipt, to: SafeRelativePath("\(destination)/.macgacha-component.json"))
            }
            prepared = true
            return (lifetime, expected)
        }
        let staged = RuntimeStagedUpdate(token: token, bundle: bundle, components: components, expected: prepared.1,
            importedBundle: nil, importedSource: nil, lifetime: prepared.0)
        var capturedImport: InstalledRuntimeBundle?
        do {
            let stageManager = RuntimeBundleManager(manifest: manifest, store: stageStore, consent: consent,
                installer: installer.relocated(to: stageStore), runner: runner, disk: disk, failurePoint: failurePoint)
            if let bundle {
                if let previous {
                    guard let imported = try await installed(previous), imported.source == .importFromGPTK,
                        let identity = imported.importedFramework,
                        let graphics = components.first(where: { $0.kind == .d3dmetal }), identity.version == graphics.version.rawValue else {
                        throw LauncherError.io("Imported graphics cannot be staged for this recommendation")
                    }
                    let source = imported.root.appendingPathComponent("lib/external")
                    capturedImport = imported
                    _ = try await stageManager.install(bundle, from: GPTKCandidate(root: source,
                        d3dmetalFramework: source.appendingPathComponent("D3DMetal.framework"), version: identity.version), progress: progress)
                } else { _ = try await stageManager.install(bundle, progress: progress) }
            } else if let component = components.first, prepared.1[component.id] == nil {
                for try await event in installer.relocated(to: stageStore).install(component) { progress(event) }
            }
            try Task.checkCancellation()
            return RuntimeStagedUpdate(token: token, bundle: bundle, components: components, expected: prepared.1,
                importedBundle: previous, importedSource: capturedImport, lifetime: prepared.0)
        } catch {
            try? await discard(staged)
            throw error
        }
    }

    /// Short, idle-only publication. Recheck all source receipts under the
    /// same exclusions as manual runtime publication before moving any tree.
    public func publish(_ staged: RuntimeStagedUpdate) async throws {
        try await BlockingIO.run {
            let lease = try RuntimeStoreLease(store: store)
            let pins = try RuntimeRemovalLease(paths: store.paths, componentIDs: staged.components.map { $0.id.rawValue })
            defer { withExtendedLifetime((lease, pins, staged.lifetime)) {} }
            let fs = try ContainedFileSystem(root: store.paths.root).pinRoot()
            let root = try automaticStagePath(staged.token)
            for component in staged.components {
                guard try componentRecord(component) == staged.expected[component.id] else { throw LauncherError.busy("Automatic source changed") }
            }
            if let previous = staged.importedBundle, let expected = staged.importedSource {
                let source = try RuntimeJSONFile.relativePath(expected.root, root: store.paths.root)
                let bytes = try fs.readFile(at: SafeRelativePath("\(source)/.macgacha-bundle.json"), maxBytes: 65_536)
                let marker = try JSONDecoder().decode(BundleMarker.self, from: bytes)
                guard marker.id == previous.id, marker.source == .importFromGPTK, marker.digest == expected.digest,
                    marker.componentsDigest == (try fingerprint(previous, components: selected(previous))) else {
                    throw LauncherError.busy("Imported graphics source changed")
                }
            }
            try fs.writeAtomically(Data("publication".utf8), to: SafeRelativePath("\(root)/.publication-in-progress"))
            for component in staged.components where staged.expected[component.id] == nil {
                let destination = try RuntimeJSONFile.relativePath(store.installURL(for: component), root: store.paths.root)
                let incoming = try SafeRelativePath("\(root)/\(destination)")
                try fs.createDirectory(at: SafeRelativePath(destination.components.dropLast().joined(separator: "/")))
                let marker = try fs.readFile(at: SafeRelativePath("\(incoming)/.macgacha-component.json"), maxBytes: 65_536)
                let receipt = try JSONDecoder().decode(InstalledComponent.self, from: marker)
                guard receipt.kind == component.kind, receipt.version == component.version.rawValue,
                    receipt.archiveDigest == component.sha256, receipt.publicationID != nil else { throw LauncherError.io("Invalid staged component receipt") }
                var uncertain = false
                try RuntimePublication.publish(fs: fs, incoming: incoming, destination: destination, uncertain: &uncertain, failurePoint: failurePoint)
            }
            if let bundle = staged.bundle {
                try fs.createDirectory(at: bundleParent())
                let incoming = try SafeRelativePath("\(root)/\(bundlePath(bundle))")
                if try fs.itemType(at: incoming) != nil {
                    try GameModeHelper.remove(bundleID: bundle.id, paths: store.paths, fs: fs)
                    var uncertain = false
                    try RuntimePublication.publish(fs: fs, incoming: incoming, destination: bundlePath(bundle), uncertain: &uncertain, failurePoint: failurePoint)
                }
                guard try inspect(bundle) != nil else { throw LauncherError.io("Staged runtime publication is incomplete") }
            }
            try fs.removeItem(at: root)
        }
    }
    public func discard(_ staged: RuntimeStagedUpdate) async throws {
        try await BlockingIO.finish {
            let fs = try ContainedFileSystem(root: store.paths.root)
            let path = try automaticStagePath(staged.token)
            guard try fs.itemType(at: path) != nil else { return }
            if try fs.itemType(at: SafeRelativePath("\(path)/.publication-in-progress")) == nil { try fs.removeItem(at: path) }
            withExtendedLifetime(staged.lifetime) {}
        }
    }
    private func automaticStagePath(_ token: UUID) throws -> SafeRelativePath {
        try SafeRelativePath("Runtimes/.automatic-staging/\(token.uuidString)")
    }
    public static func sweepAutomaticStaging(paths: AppPaths) async throws {
        try await BlockingIO.run {
            let store = RuntimeStore(paths: paths), lease = try RuntimeStoreLease(store: store)
            defer { withExtendedLifetime(lease) {} }
            let fs = try ContainedFileSystem(root: paths.root).pinRoot()
            let parent = try SafeRelativePath("Runtimes/.automatic-staging")
            guard try fs.itemType(at: parent) == .directory else { return }
            let entries = try fs.contentsOfDirectory(at: parent)
            guard entries.count <= 4096 else { throw LauncherError.io("Too many automatic staging entries") }
            for entry in entries {
                guard let name = entry.components.last, UUID(uuidString: name) != nil,
                    try fs.itemType(at: entry) == .directory,
                    try fs.itemType(at: SafeRelativePath("\(entry)/.publication-in-progress")) == nil else { continue }
                let stageFS = try ContainedFileSystem(root: fs.directoryURL(at: entry)).pinRoot()
                guard let lock = try? RuntimeAutomaticStageLease(fs: stageFS) else { continue }
                defer { withExtendedLifetime(lock) {} }
                try fs.removeItem(at: entry)
            }
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
            let pins = try RuntimeRemovalLease(paths: store.paths, componentIDs: components.map { $0.id.rawValue })
            defer { withExtendedLifetime((lease, pins)) {} }
            try store.sweepStaging(holding: pins, deleting: { try $0.removeItem(at: $1) })
            for c in components {
                if try componentRecord(c) == nil {
                    guard c.sourceMode == .download else {
                        throw LauncherError.io("Install the base Wine bundle before importing D3DMetal")
                    }
                    for try await event in installer.install(c, lease: lease, pins: pins) {
                        if event != .phase(.completed) { progress(event) }
                    }
                }
            }
            if candidate == nil, let ready = try inspect(bundle) { progress(.phase(.completed)); return ready }
            let fs = try ContainedFileSystem(root: store.paths.root)
            let digest = try fingerprint(bundle, components: components)
            guard let wine = components.first(where: { $0.kind == .wine }) ?? components.first(where: { $0.wineBinary != nil }), let binary = wine.wineBinary else {
                throw LauncherError.io("Bundle Wine component is missing")
            }
            let winePath = try RuntimeJSONFile.relativePath(store.installURL(for: wine), root: store.paths.root)
            if bundle.backend == .d3dmetal, components.count == 1, candidate == nil {
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
                let source = try RuntimeTree(fs: fs, root: winePath, allowingExternalHardLinks: true)
                var overlays: [(RuntimeTree, SafeRelativePath)] = []
                var runtimeDigest = digest
                var importedFramework: ImportedD3DMetalIdentity?
                let graphics: RuntimeTree?
                if bundle.backend == .d3dmetal, components.count == 2,
                    let component = components.first(where: { $0.kind == .d3dmetal }) {
                    let root = try RuntimeJSONFile.relativePath(store.installURL(for: component), root: store.paths.root)
                    graphics = try RuntimeTree(fs: fs, root: root, allowingExternalHardLinks: true, including: D3DMetalGraphics.paths)
                    guard try fs.itemType(at: SafeRelativePath("\(winePath)/bin/wine.real")) == .regularFile else {
                        throw LauncherError.io("Wine real loader is missing")
                    }
                } else { graphics = nil }
                for c in components {
                    let root = try RuntimeJSONFile.relativePath(store.installURL(for: c), root: store.paths.root)
                    for overlay in c.overlay {
                        overlays.append((try RuntimeTree(fs: fs, root: SafeRelativePath("\(root)/\(overlay.source)"), allowingExternalHardLinks: true), overlay.destination))
                    }
                }
                if let candidate {
                    let sourceFS = try ContainedFileSystem(root: candidate.root)
                    let framework = try RuntimeTree(fs: sourceFS, root: SafeRelativePath("D3DMetal.framework"))
                    importedFramework = try framework.frameworkIdentity()
                    overlays.append((framework, try SafeRelativePath("lib/external/D3DMetal.framework")))
                    var hash = StreamingHasher(.sha256); hash.update(Data(digest.hex.utf8)); hash.update(Data(try framework.digest().hex.utf8))
                    runtimeDigest = hash.finalize()
                }
                var required = source.bytes
                if let graphics {
                    let (sum, overflow) = required.addingReportingOverflow(graphics.bytes)
                    guard !overflow else { throw LauncherError.io("Runtime space budget overflow") }
                    required = sum
                }
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
                try graphics?.copy(to: incoming, in: fs, overlay: true)
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
                let marker = BundleMarker(id: bundle.id, digest: runtimeDigest, componentsDigest: digest,
                    source: candidate == nil ? .download : .importFromGPTK, importedFramework: importedFramework)
                let markerPath = try SafeRelativePath("\(incoming)/.macgacha-bundle.json")
                try fs.writeAtomically(JSONEncoder().encode(marker), to: markerPath)
                try fs.fullSync(at: markerPath)
                progress(.phase(.committing))
                try GameModeHelper.remove(bundleID: bundle.id, paths: store.paths, fs: fs)
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

    /// Preserve the user's imported framework for a Wine-only recommendation.
    /// Both installations retain normal consent, source validation and publication exclusions.
    @discardableResult
    public func install(_ bundle: RuntimeBundle, carryingImportedFrameworkFrom previous: RuntimeBundle,
        progress: @escaping @Sendable (OperationEvent) -> Void = { _ in }) async throws -> InstalledRuntimeBundle {
        let targetComponents = try selected(bundle), oldComponents = try selected(previous)
        guard bundle.backend == .d3dmetal, previous.backend == .d3dmetal,
            let graphics = targetComponents.first(where: { $0.kind == .d3dmetal }),
            let oldGraphics = oldComponents.first(where: { $0.kind == .d3dmetal }),
            oldGraphics.kind == .d3dmetal,
            let imported = try await installed(previous), imported.source == .importFromGPTK,
            imported.importedFramework?.version == graphics.version.rawValue else {
            throw LauncherError.io("Imported graphics cannot be carried to this bundle")
        }
        _ = try await install(bundle) { event in if event != .phase(.completed) { progress(event) } }
        try Task.checkCancellation()
        guard let verified = try await installed(previous), verified == imported else {
            throw LauncherError.io("Imported graphics source changed")
        }
        let root = imported.root.appendingPathComponent("lib/external")
        return try await install(bundle, from: GPTKCandidate(root: root,
            d3dmetalFramework: root.appendingPathComponent("D3DMetal.framework"), version: graphics.version.rawValue), progress: progress)
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
            try GameModeHelper.remove(bundleID: bundle.id, paths: store.paths, fs: fs)
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
        var importedFramework: ImportedD3DMetalIdentity?
        if try fs.itemType(at: assembled) != nil {
            guard let data = try RuntimeJSONFile.read(SafeRelativePath("\(assembled)/.macgacha-bundle.json"), in: fs, limit: 65_536),
                let marker = try? JSONDecoder().decode(BundleMarker.self, from: data), marker.id == bundle.id,
                marker.componentsDigest == digest else { return nil }
            root = assembled.resolved(against: store.paths.root); source = marker.source; runtimeDigest = marker.digest
            importedFramework = marker.importedFramework
            if source == .importFromGPTK, importedFramework == nil {
                importedFramework = try RuntimeTree(fs: fs, root: SafeRelativePath("\(assembled)/lib/external/D3DMetal.framework"), allowingExternalHardLinks: true).frameworkIdentity()
            }
        } else if bundle.backend == .d3dmetal, components.count == 1, let component = components.first {
            root = store.installURL(for: component)
        } else { return nil }
        guard let binary = components.first(where: { $0.wineBinary != nil })?.wineBinary else { return nil }
        let path = try RuntimeJSONFile.relativePath(binary.resolved(against: root), root: store.paths.root)
        guard try fs.itemType(at: path) == .regularFile else { return nil }
        return InstalledRuntimeBundle(id: bundle.id, root: root, wineBinary: binary.resolved(against: root), digest: runtimeDigest,
            source: source, importedFramework: importedFramework)
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
    init(fs: ContainedFileSystem, root: SafeRelativePath, allowingExternalHardLinks: Bool = false,
        including paths: [SafeRelativePath]? = nil) throws {
        self.fs = fs; self.root = root
        let all = try fs.inspectTree(at: root, allowingExternalHardLinks: allowingExternalHardLinks)
        try ArchivePolicy.validate(all.map { ArchiveEntry(path: $0.path.description,
            kind: $0.linkTarget.map { .symlink($0) } ?? ($0.type == .directory ? .directory : .file)) })
        if let paths {
            guard paths.allSatisfy({ path in all.contains { $0.path == path } }) else {
                throw LauncherError.io("D3DMetal graphics path is missing")
            }
            entries = all.filter { entry in paths.contains { path in
                entry.path.components.starts(with: path.components)
                    || (entry.type == .directory && path.components.starts(with: entry.path.components))
            } }
        } else { entries = all }
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
    func frameworkIdentity() throws -> ImportedD3DMetalIdentity {
        var version: String?
        for name in ["Info.plist", "Versions/A/Resources/Info.plist", "Resources/Info.plist"] {
            let path = try SafeRelativePath("\(root)/\(name)")
            guard (try? fs.itemType(at: path)) == .regularFile,
                let data = try? fs.readFile(at: path, maxBytes: 65_536),
                let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                let value = (plist["CFBundleShortVersionString"] ?? plist["CFBundleVersion"]) as? String,
                !value.isEmpty, value.utf8.count <= 128, !value.utf8.contains(0) else { continue }
            version = value; break
        }
        return try ImportedD3DMetalIdentity(version: version, digest: digest())
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
