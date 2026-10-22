// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Dispatch
import Foundation
import LauncherCore
import DownloadEngine

public struct ComponentInstaller: Sendable {
    /// Deterministic failure boundaries for publish/recovery tests. The default is a no-op.
    public enum PublishPoint: Sendable, Equatable { case beforePublish, afterPublish }

    private let store: RuntimeStore
    private let consent: ConsentStore
    private let fetcher: ChunkFetcher?
    private let extractor: ArchiveExtractor?
    private let disk: any DiskSpaceProbe
    private let fileOps: any FileOps
    private let failurePoint: @Sendable (PublishPoint) throws -> Void

    public init(store: RuntimeStore, consent: ConsentStore, fetcher: ChunkFetcher,
        extractor: ArchiveExtractor, disk: any DiskSpaceProbe, fileOps: any FileOps = SystemFileOps(),
        failurePoint: @escaping @Sendable (PublishPoint) throws -> Void = { _ in }) {
        self.store = store; self.consent = consent; self.fetcher = fetcher
        self.extractor = extractor; self.disk = disk; self.fileOps = fileOps; self.failurePoint = failurePoint
    }

    /// Import-only construction: no HTTP client or archive extractor is created.
    public init(store: RuntimeStore, consent: ConsentStore, disk: any DiskSpaceProbe = SystemDiskSpaceProbe(),
        fileOps: any FileOps = SystemFileOps(),
        failurePoint: @escaping @Sendable (PublishPoint) throws -> Void = { _ in }) {
        self.store = store; self.consent = consent; self.fetcher = nil; self.extractor = nil
        self.disk = disk; self.fileOps = fileOps; self.failurePoint = failurePoint
    }

    func install(_ component: RuntimeComponent, lease: RuntimeStoreLease) -> ComponentInstallStream {
        ComponentInstallStream(session: ComponentInstallSession(component: component, candidate: nil, store: store, consent: consent,
            fetcher: fetcher, extractor: extractor, disk: disk, fileOps: fileOps, failurePoint: failurePoint, lease: lease))
    }

    /// Pull-driven: dropping the stream releases the store lock; cancelling its consumer
    /// cancels HTTP/extraction/copy. The only completed event follows successful publication.
    /// An import manifest requires a candidate; downloads require no candidate.
    public func install(_ component: RuntimeComponent, from candidate: GPTKCandidate? = nil) -> ComponentInstallStream {
        let session = ComponentInstallSession(component: component, candidate: candidate, store: store, consent: consent,
            fetcher: fetcher, extractor: extractor, disk: disk, fileOps: fileOps, failurePoint: failurePoint)
        return ComponentInstallStream(session: session)
    }
}

/// A checked iterator deliberately differs from AsyncThrowingStream: cancellation
/// must reach the session and finish cleanup before it throws to the consumer.
public struct ComponentInstallStream: AsyncSequence, Sendable {
    public typealias Element = OperationEvent
    public typealias AsyncIterator = Iterator
    fileprivate let lifetime: ComponentInstallLifetime
    fileprivate init(session: ComponentInstallSession) { lifetime = ComponentInstallLifetime(session) }
    public func makeAsyncIterator() -> Iterator { Iterator(lifetime: lifetime) }
    public struct Iterator: AsyncIteratorProtocol, Sendable {
        fileprivate let lifetime: ComponentInstallLifetime
        public mutating func next() async throws -> OperationEvent? { try await lifetime.session.next() }
    }
}

fileprivate final class ComponentInstallLifetime: Sendable {
    let session: ComponentInstallSession
    init(_ session: ComponentInstallSession) { self.session = session }
    deinit {
        let session = session
        Task { await session.abandon() }
    }
}

fileprivate actor ComponentInstallSession {
    nonisolated private let ioQueue = DispatchSerialQueue(label: "org.macgacha.component-install")
    nonisolated var unownedExecutor: UnownedSerialExecutor { ioQueue.asUnownedSerialExecutor() }

    private enum Step { case start, space, download, extract, publish, cleanup, done }
    private let component: RuntimeComponent
    private let candidate: GPTKCandidate?
    private var importSource: GPTKImportSource?
    private let store: RuntimeStore
    private let consent: ConsentStore
    private let fetcher: ChunkFetcher?
    private let extractor: ArchiveExtractor?
    private let disk: any DiskSpaceProbe
    private let fileOps: any FileOps
    private let failurePoint: @Sendable (ComponentInstaller.PublishPoint) throws -> Void
    private var step = Step.start
    private var fs: ContainedFileSystem?
    private var lock: InstallLock?
    private var lease: RuntimeStoreLease?
    private var download: AsyncThrowingStream<OperationEvent, any Error>.Iterator?
    private var incoming: SafeRelativePath?
    private var downloads: SafeRelativePath?
    private var pulling = false
    private var publicationUncertain = false

    init(component: RuntimeComponent, candidate: GPTKCandidate?, store: RuntimeStore, consent: ConsentStore, fetcher: ChunkFetcher?,
        extractor: ArchiveExtractor?, disk: any DiskSpaceProbe, fileOps: any FileOps,
        failurePoint: @escaping @Sendable (ComponentInstaller.PublishPoint) throws -> Void, lease: RuntimeStoreLease? = nil) {
        self.lease = lease
        self.component = component; self.candidate = candidate; self.store = store; self.consent = consent; self.fetcher = fetcher
        self.extractor = extractor; self.disk = disk; self.fileOps = fileOps; self.failurePoint = failurePoint
    }

    func next() async throws -> OperationEvent? {
        guard !pulling else { throw LauncherError.busy("component stream already in use") }
        pulling = true
        defer { pulling = false }
        if step == .done {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            return nil
        }
        do {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            switch step {
            case .start:
                // Manifest construction/decoding enforces which components require consent.
                // Current notice digest and terms revision are checked before any network I/O.
                if let kind = component.consent,
                    !(await consent.isAccepted(kind, version: component.version.rawValue, termsRevision: component.license.termsRevision)) {
                    throw LauncherError.consentRequired(component.id.rawValue)
                }
                switch component.sourceMode {
                case .download:
                    guard candidate == nil, fetcher != nil, extractor != nil else { throw LauncherError.io("Download requires HTTP and archive extraction") }
                case .importFromGPTK:
                    guard component.kind == .d3dmetal, candidate != nil else { throw LauncherError.io("GPTK import requires a D3DMetal candidate") }
                }
                let fs = try ContainedFileSystem(root: store.paths.root, fileOps: fileOps)
                let runtimes = try RuntimeJSONFile.relativePath(store.paths.runtimes, root: store.paths.root)
                try fs.createDirectory(at: runtimes)
                if lease == nil { lock = try InstallLock(fs: fs, path: SafeRelativePath("\(runtimes)/.lock")) }
                self.fs = fs
                try store.sweepStaging()
                let kind = try SafeRelativePath("\(runtimes)/\(component.kind.rawValue)")
                try fs.createDirectory(at: kind)
                let destination = try RuntimeJSONFile.relativePath(store.installURL(for: component), root: store.paths.root)
                if let type = try fs.itemType(at: destination), type != .directory {
                    throw LauncherError.unsafePath(destination.description)
                }
                step = .space
                return .phase(.checkingSpace)
            case .space:
                let fs = try filesystem()
                if component.sourceMode == .importFromGPTK {
                    guard let candidate else { throw LauncherError.io("Missing GPTK candidate") }
                    let source = try GPTKImportSource(candidate: candidate,
                        maxBytes: min(GPTKImporter.importByteLimit, component.installedSize ?? GPTKImporter.importByteLimit))
                    let available = try disk.availableBytes(at: store.paths.runtimes)
                    guard available >= source.size else { throw LauncherError.insufficientSpace(required: source.size, available: available) }
                    importSource = source; step = .extract
                    return .phase(.staging)
                }
                guard let fetcher else { throw LauncherError.io("Missing archive fetcher") }
                guard let size = component.size, size > 0, let installedSize = component.installedSize,
                    let digest = component.sha256, let url = component.url else { throw LauncherError.io("Invalid download component") }
                let (required, overflow) = size.addingReportingOverflow(installedSize)
                guard !overflow else { throw LauncherError.io("Runtime space budget overflow") }
                // Existing installs already occupy the volume's used space. Never delete them
                // to meet this check; they stay intact until the directory swap.
                let available = try disk.availableBytes(at: store.paths.runtimes)
                guard available >= required else { throw LauncherError.insufficientSpace(required: required, available: available) }
                let runtimes = try RuntimeJSONFile.relativePath(store.paths.runtimes, root: store.paths.root)
                let downloads = try SafeRelativePath("\(runtimes)/.downloads/\(component.id)")
                self.downloads = downloads
                try fs.createDirectory(at: downloads)
                let file = try SafeRelativePath("archive")
                let object = ChunkObject(id: "archive", urls: [url], transferSize: size, transferDigest: digest,
                    decodedSize: size, decodedDigest: digest, codec: .identity)
                var id = "runtime-" + component.id.rawValue
                if id.utf8.count > 128 {
                    var hasher = StreamingHasher(.sha256); hasher.update(Data(component.id.rawValue.utf8))
                    id = "runtime-" + hasher.finalize().hex
                }
                let plan = InstallPlan(id: try SafeIdentifier(id), objects: [object.id: object], files: [
                    FileTask(path: file, size: size, digest: digest,
                        extents: [Extent(source: .chunk(id: object.id), fileOffset: 0, length: size, digest: digest)])
                ])
                let root = try fs.directoryURL(at: downloads)
                download = try InstallOperation(plan: plan, installRoot: root, fetcher: fetcher, disk: disk, fileOps: fileOps).run().makeAsyncIterator()
                step = .download
                return .phase(.staging)
            case .download:
                guard var iterator = download else { throw LauncherError.io("Missing archive download") }
                download = nil
                let event = try await iterator.next(isolation: self)
                download = iterator
                switch event {
                case .progress, .fileVerified: return event
                case .failed(let error): throw error
                case .needsBatchApproval(let required, let available):
                    throw LauncherError.insufficientSpace(required: required, available: available)
                case .phase(.completed):
                    download = nil; step = .extract
                    return .phase(.verifying)
                case .none: throw LauncherError.io("Archive download ended without completion")
                default: return .phase(.staging) // Inner commit/cleanup belong to the download, not publish.
                }
            case .extract:
                let fs = try filesystem()
                let runtimes = try RuntimeJSONFile.relativePath(store.paths.runtimes, root: store.paths.root)
                let incoming = try SafeRelativePath("\(runtimes)/\(component.kind.rawValue)/.incoming-\(UUID().uuidString)")
                self.incoming = incoming
                if component.sourceMode == .importFromGPTK {
                    guard let importSource else { throw LauncherError.io("Missing GPTK source") }
                    try importSource.copy(into: incoming, fs: fs)
                    self.importSource = nil
                } else {
                    guard let downloads, let format = component.archive, let installedSize = component.installedSize, let extractor else {
                        throw LauncherError.io("Missing runtime archive")
                    }
                    let archive = try SafeRelativePath("\(downloads)/archive")
                    try await extractor.extract(archive: archive, archiveFS: fs, archiveURL: archive.resolved(against: store.paths.root),
                        format: format, fs: fs, target: incoming, expandedLimit: installedSize, rootPath: component.rootPath)
                }
                if let binary = component.wineBinary {
                    guard try fs.itemType(at: SafeRelativePath("\(incoming)/\(binary)")) == .regularFile else {
                        throw LauncherError.io("Runtime Wine binary is missing")
                    }
                    if component.kind == .d3dmetal {
                        try await RuntimeBundleManager.verifyMetal(fs: fs, root: incoming, runner: SystemProcessRunner())
                    }
                }
                try RuntimePublication.prepare(component, fs: fs, incoming: incoming)
                step = .publish
                return .phase(.committing)
            case .publish:
                let fs = try filesystem()
                guard let incoming else { throw LauncherError.io("Missing incoming runtime") }
                let destination = try RuntimeJSONFile.relativePath(store.installURL(for: component), root: store.paths.root)
                try RuntimePublication.publish(fs: fs, incoming: incoming, destination: destination,
                    uncertain: &publicationUncertain, failurePoint: failurePoint)
                step = .cleanup
                return .phase(.cleaningUp)
            case .cleanup:
                let fs = try filesystem()
                if let incoming { try fs.removeItem(at: incoming) }
                if let downloads { try fs.removeItem(at: downloads) }
                step = .done; lock = nil; lease = nil
                return .phase(.completed)
            case .done: return nil
            }
        } catch {
            // A cancelled consumer must join the engine before removing its
            // root; otherwise a still-running fetch can recreate .downloads.
            let cancelled = Task.isCancelled || error is CancellationError
            await Task.detached { await self.abandon() }.value
            if cancelled { throw LauncherError.cancelled }
            throw error
        }
    }

    func abandon() async {
        guard step != .done else { return }
        download = nil; importSource = nil
        if let fs {
            if let downloads {
                let root = downloads.resolved(against: store.paths.root)
                if let inner = try? ContainedFileSystem(root: root),
                    let path = try? SafeRelativePath(".macgacha-staging/.lock") {
                    try? await PipelineRootRetention.waitIfDraining(inner.caseFoldedPathKey(for: path))
                }
            }
            // If publish/rollback failed, incoming may hold the old version.
            let abandoned = [publicationUncertain ? nil : incoming, downloads].compactMap { $0 }
            for path in abandoned { try? fs.removeItem(at: path) }
            if let downloads,
                let parent = try? SafeRelativePath(downloads.components.dropLast().joined(separator: "/")),
                (try? fs.contentsOfDirectory(at: parent).isEmpty) == true {
                try? fs.removeItem(at: parent)
            }
        }
        step = .done; lock = nil; lease = nil
    }

    private func filesystem() throws -> ContainedFileSystem {
        guard let fs else { throw LauncherError.io("Runtime store is not open") }
        return fs
    }
}
