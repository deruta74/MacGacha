// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine

public struct ComponentInstaller: Sendable {
    /// Deterministic failure boundaries for publish/recovery tests. The default is a no-op.
    public enum PublishPoint: Sendable, Equatable { case beforePublish, afterPublish }

    private let store: RuntimeStore
    private let consent: ConsentStore
    private let fetcher: ChunkFetcher
    private let extractor: ArchiveExtractor
    private let disk: any DiskSpaceProbe
    private let fileOps: any FileOps
    private let failurePoint: @Sendable (PublishPoint) throws -> Void

    public init(store: RuntimeStore, consent: ConsentStore, fetcher: ChunkFetcher,
        extractor: ArchiveExtractor, disk: any DiskSpaceProbe, fileOps: any FileOps = SystemFileOps(),
        failurePoint: @escaping @Sendable (PublishPoint) throws -> Void = { _ in }) {
        self.store = store; self.consent = consent; self.fetcher = fetcher
        self.extractor = extractor; self.disk = disk; self.fileOps = fileOps; self.failurePoint = failurePoint
    }

    /// Pull-driven: dropping the stream releases the store lock; cancelling its consumer
    /// cancels HTTP/extraction. The only completed event follows successful publication.
    /// This download installer does not implement GPTK import or prefix creation.
    public func install(_ component: RuntimeComponent) -> AsyncThrowingStream<OperationEvent, any Error> {
        let session = ComponentInstallSession(component: component, store: store, consent: consent,
            fetcher: fetcher, extractor: extractor, disk: disk, fileOps: fileOps, failurePoint: failurePoint)
        return AsyncThrowingStream(unfolding: { try await session.next() })
    }
}

private actor ComponentInstallSession {
    private enum Step { case start, space, download, extract, publish, cleanup, done }
    private let component: RuntimeComponent
    private let store: RuntimeStore
    private let consent: ConsentStore
    private let fetcher: ChunkFetcher
    private let extractor: ArchiveExtractor
    private let disk: any DiskSpaceProbe
    private let fileOps: any FileOps
    private let failurePoint: @Sendable (ComponentInstaller.PublishPoint) throws -> Void
    private var step = Step.start
    private var fs: ContainedFileSystem?
    private var lock: InstallLock?
    private var download: AsyncThrowingStream<OperationEvent, any Error>.Iterator?
    private var incoming: SafeRelativePath?
    private var downloads: SafeRelativePath?
    private var pulling = false
    private var publicationUncertain = false

    init(component: RuntimeComponent, store: RuntimeStore, consent: ConsentStore, fetcher: ChunkFetcher,
        extractor: ArchiveExtractor, disk: any DiskSpaceProbe, fileOps: any FileOps,
        failurePoint: @escaping @Sendable (ComponentInstaller.PublishPoint) throws -> Void) {
        self.component = component; self.store = store; self.consent = consent; self.fetcher = fetcher
        self.extractor = extractor; self.disk = disk; self.fileOps = fileOps; self.failurePoint = failurePoint
    }

    func next() async throws -> OperationEvent? {
        guard !pulling else { throw LauncherError.busy("component stream already in use") }
        pulling = true
        defer { pulling = false }
        if step == .done { return nil }
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
                guard component.sourceMode == .download else { throw LauncherError.io("GPTK import requires the GPTK importer") }
                let fs = try ContainedFileSystem(root: store.paths.root, fileOps: fileOps)
                let runtimes = try RuntimeJSONFile.relativePath(store.paths.runtimes, root: store.paths.root)
                try fs.createDirectory(at: runtimes)
                lock = try InstallLock(fs: fs, path: SafeRelativePath("\(runtimes)/.lock"))
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
                guard let downloads, let format = component.archive, let installedSize = component.installedSize else {
                    throw LauncherError.io("Missing runtime archive")
                }
                let runtimes = try RuntimeJSONFile.relativePath(store.paths.runtimes, root: store.paths.root)
                let incoming = try SafeRelativePath("\(runtimes)/\(component.kind.rawValue)/.incoming-\(UUID().uuidString)")
                self.incoming = incoming
                let archive = try SafeRelativePath("\(downloads)/archive")
                try await extractor.extract(archive: archive, archiveFS: fs, archiveURL: archive.resolved(against: store.paths.root),
                    format: format, fs: fs, target: incoming, expandedLimit: installedSize)
                try fs.removeQuarantineRecursively(at: incoming)
                try fs.synchronizeTree(at: incoming)
                let marker = try InstalledComponent(kind: component.kind, version: component.version.rawValue,
                    installedAt: Date(), source: .download)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let markerPath = try SafeRelativePath("\(incoming)/.macgacha-component.json")
                try fs.writeAtomically(encoder.encode(marker), to: markerPath)
                try fs.fullSync(at: markerPath)
                step = .publish
                return .phase(.committing)
            case .publish:
                let fs = try filesystem()
                guard let incoming else { throw LauncherError.io("Missing incoming runtime") }
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                try failurePoint(.beforePublish)
                let destination = try RuntimeJSONFile.relativePath(store.installURL(for: component), root: store.paths.root)
                publicationUncertain = true
                try fs.publishDirectory(at: incoming, to: destination)
                publicationUncertain = false
                try failurePoint(.afterPublish)
                step = .cleanup
                return .phase(.cleaningUp)
            case .cleanup:
                let fs = try filesystem()
                if let incoming { try fs.removeItem(at: incoming) }
                if let downloads { try fs.removeItem(at: downloads) }
                step = .done; lock = nil
                return .phase(.completed)
            case .done: return nil
            }
        } catch {
            download = nil
            if let fs {
                // If publish/rollback failed, incoming might still be the old version.
                // Preserve it for recovery rather than deleting an uncertain tree here.
                let abandoned = [publicationUncertain ? nil : incoming, downloads].compactMap { $0 }
                let downloadRoot = downloads.flatMap { try? SafeRelativePath($0.components.dropLast().joined(separator: "/")) }
                // Cleanup must finish even when the consumer is cancelled. Await this bounded,
                // uncancelled task while retaining the store lock; no producer outlives the stream.
                await Task.detached {
                    for path in abandoned { try? fs.removeItem(at: path) }
                    if let downloadRoot, (try? fs.contentsOfDirectory(at: downloadRoot).isEmpty) == true {
                        try? fs.removeItem(at: downloadRoot)
                    }
                }.value
            }
            step = .done; lock = nil
            if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
            throw error
        }
    }

    private func filesystem() throws -> ContainedFileSystem {
        guard let fs else { throw LauncherError.io("Runtime store is not open") }
        return fs
    }
}
