// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine
import RuntimeManager
import Diagnostics

protocol RuntimeServices: Sendable {
    func scanBundles(_ manifest: RuntimeManifest) async throws -> [String: InstalledRuntimeBundle]
    func install(_ bundle: RuntimeBundle, manifest: RuntimeManifest, from candidate: GPTKCandidate?) -> RuntimeInstallStream
    func remove(_ bundle: RuntimeBundle, manifest: RuntimeManifest) async throws
    func scan() async throws -> RuntimeScan
    func sweepStaging() async throws
    func install(_ component: RuntimeComponent, from candidate: GPTKCandidate?) -> AsyncThrowingStream<OperationEvent, any Error>
    func remove(_ component: InstalledComponent) async throws
    func removeInvalid(_ entry: InvalidRuntimeEntry) async throws
    func isConsentAccepted(_ component: RuntimeComponent) async -> Bool
    func acceptConsent(for component: RuntimeComponent) async throws
    func locateGPTK(extraRoots: [URL]) async throws -> [GPTKCandidate]
    func exportDiagnostics(to url: URL) async throws
    func makeDiagnosticBundle() async throws -> URL
    func recentLogLines(limit: Int) async -> [String]
}

extension RuntimeServices {
    func scanBundles(_ manifest: RuntimeManifest) async throws -> [String: InstalledRuntimeBundle] { [:] }
    func install(_ bundle: RuntimeBundle, manifest: RuntimeManifest, from candidate: GPTKCandidate?) -> RuntimeInstallStream {
        RuntimeInstallStream(AsyncThrowingStream { $0.finish(throwing: LauncherError.io("Runtime bundle service unavailable")) })
    }
    func remove(_ bundle: RuntimeBundle, manifest: RuntimeManifest) async throws { throw LauncherError.io("Runtime bundle service unavailable") }

    @concurrent func makeDiagnosticBundle() async throws -> URL {
        try await TemporaryDiagnosticBundle.make { try await self.exportDiagnostics(to: $0) }
    }
}

/// Core adapters own error logging, including errors thrown while pulling an install.
/// Expensive entry points explicitly leave the caller's actor; constructing services does no disk I/O.
final class LiveRuntimeServices: RuntimeServices, Sendable {
    private let paths: AppPaths
    private let store: RuntimeStore
    private let consent: ConsentStore
    private let fetcher: ChunkFetcher
    private let installer: ComponentInstaller
    private let eventLog: EventLog
    private let session: OwnedHTTPSession?

    init(paths: AppPaths = .standard(), http: (any HTTPClient)? = nil,
        retry: RetryPolicy = RetryPolicy(), sleeper: any Sleeper = ContinuousSleeper(), log: EventLog? = nil) {
        self.paths = paths
        let store = RuntimeStore(paths: paths)
        let consent = ConsentStore(url: paths.consent, root: paths.root)
        let client: any HTTPClient
        if let http { client = http; session = nil }
        else { let owned = OwnedHTTPSession(); session = owned; client = owned.client }
        self.store = store; self.consent = consent
        let fetcher = ChunkFetcher(http: client, retry: retry, sleeper: sleeper)
        self.fetcher = fetcher
        self.installer = ComponentInstaller(store: store, consent: consent, fetcher: fetcher,
            extractor: ArchiveExtractor(runner: SystemProcessRunner()), disk: SystemDiskSpaceProbe())
        self.eventLog = log ?? EventLog(directory: paths.logs)
    }

    private func bundleManager(_ manifest: RuntimeManifest) -> RuntimeBundleManager {
        RuntimeBundleManager(manifest: manifest, store: store, consent: consent, installer: installer)
    }

    func scanBundles(_ manifest: RuntimeManifest) async throws -> [String: InstalledRuntimeBundle] {
        var result: [String: InstalledRuntimeBundle] = [:]
        let manager = bundleManager(manifest)
        for bundle in manifest.bundles { result[bundle.id.rawValue] = try await manager.installed(bundle) }
        return result
    }

    func install(_ bundle: RuntimeBundle, manifest: RuntimeManifest, from candidate: GPTKCandidate?) -> RuntimeInstallStream {
        let manager = bundleManager(manifest)
        return RuntimeInstallStream { continuation in
            do {
                _ = try await manager.install(bundle, from: candidate) { event in
                    if event != .phase(.completed) { continuation.yield(event) }
                }
                // The manager's lease is released before the model refreshes readiness.
                continuation.yield(.phase(.completed)); continuation.finish()
            } catch { continuation.finish(throwing: await self.record(error)) }
        }
    }

    func remove(_ bundle: RuntimeBundle, manifest: RuntimeManifest) async throws {
        do { try await bundleManager(manifest).remove(bundle) }
        catch { throw await record(error) }
    }

    @concurrent func scan() async throws -> RuntimeScan {
        do { return try await BlockingIO.run { try self.store.scan() } }
        catch { throw await record(error) }
    }

    @concurrent func sweepStaging() async throws {
        do {
            try await BlockingIO.run { try self.withStoreLock { try self.store.sweepStaging() } }
            await eventLog.log(.info, "runtime", "Startup staging sweep completed")
        } catch { throw await record(error) }
    }

    func install(_ component: RuntimeComponent, from candidate: GPTKCandidate?) -> AsyncThrowingStream<OperationEvent, any Error> {
        let operation = LoggedRuntimeInstall(component: component, candidate: candidate, installer: installer,
            log: eventLog, session: session)
        return AsyncThrowingStream(unfolding: { try await operation.next() })
    }

    @concurrent func remove(_ component: InstalledComponent) async throws {
        do { try await BlockingIO.run { try self.store.remove(component) } }
        catch { throw await record(error) }
    }

    @concurrent func removeInvalid(_ entry: InvalidRuntimeEntry) async throws {
        do { try await BlockingIO.run { try self.withStoreLock { try self.store.removeInvalid(entry) } } }
        catch { throw await record(error) }
    }

    func isConsentAccepted(_ component: RuntimeComponent) async -> Bool {
        guard let kind = component.consent else { return true }
        return await consent.isAccepted(kind, version: component.version.rawValue, termsRevision: component.license.termsRevision)
    }

    func acceptConsent(for component: RuntimeComponent) async throws {
        guard let kind = component.consent else { return }
        do { try await consent.accept(kind, version: component.version.rawValue, termsRevision: component.license.termsRevision) }
        catch { throw await record(error) }
    }

    @concurrent func locateGPTK(extraRoots: [URL]) async throws -> [GPTKCandidate] {
        do {
            return try await BlockingIO.run { try GPTKImporter(searchRoots: [URL(fileURLWithPath: "/Volumes")] + Array(extraRoots.prefix(32))).locate() }
        } catch { throw await record(error) }
    }

    @concurrent func exportDiagnostics(to url: URL) async throws {
        do { try await BlockingIO.run { try await self.writeDiagnosticBundle(to: url) } }
        catch { throw await record(error) }
    }

    @concurrent func makeDiagnosticBundle() async throws -> URL {
        do {
            return try await BlockingIO.run {
                try await TemporaryDiagnosticBundle.make { try await self.writeDiagnosticBundle(to: $0) }
            }
        } catch { throw await record(error) }
    }

    @concurrent private func writeDiagnosticBundle(to url: URL) async throws {
        let scan = try store.scan()
        let runtimes = Dictionary(uniqueKeysWithValues: scan.components.map {
            ("\($0.kind.idPrefix)-\($0.version)", $0.source.rawValue)
        })
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let logsEnabled = try GlobalLaunchSettingsStore(paths: paths).load().sessionLogsEnabled
        var discoveryFailures: [String] = []
        func discover<Value>(_ scope: String, _ body: () throws -> Value) throws -> Value? {
            do {
                try Task.checkCancellation()
                let value = try body()
                try Task.checkCancellation()
                return value
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? LauncherError) == .cancelled {
                    throw LauncherError.cancelled
                }
                // Optional discovery must not prevent diagnostics. Use a fixed scope,
                // never an error payload that could contain paths or account data.
                discoveryFailures.append(scope)
                return nil
            }
        }
        let sessionLogs = logsEnabled ? try discover("session logs") {
            try LaunchLogFiles.latestSessionLogURLs(in: paths.logs)
        } ?? [] : []
        let gameLogs = logsEnabled ? try discover("game logs") {
            try LaunchLogFiles.gameLogCandidates(in: paths.prefixes)
        } ?? [:] : [:]
        try await DiagnosticBundle(logDirectory: paths.logs, runner: SystemProcessRunner(), sessionLogURLs: sessionLogs,
            gameLogRoot: paths.prefixes, gameLogCandidates: gameLogs, sessionLogsEnabled: logsEnabled,
            logDiscoveryFailures: discoveryFailures)
            .export(to: url, systemInfo: .current(appVersion: version), runtimes: runtimes, failureStage: nil)
    }

    func recentLogLines(limit: Int) async -> [String] {
        (try? await BlockingIO.run { await self.readLogLines(limit: limit) }) ?? []
    }

    private func readLogLines(limit: Int) async -> [String] {
        let count = min(200, max(0, limit))
        guard count > 0 else { return [] }
        do {
            let fs = try ContainedFileSystem(root: paths.root)
            let log = try relativePath(paths.logs.appendingPathComponent("macgacha.log"))
            let handle = try fs.openForReading(at: log)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            let offset = size > 256 << 10 ? size - UInt64(256 << 10) : 0
            try handle.seek(toOffset: offset)
            var data = try handle.read(upToCount: 256 << 10) ?? Data()
            if offset > 0 {
                guard let newline = data.firstIndex(of: 10) else { return [] }
                data = Data(data.suffix(from: data.index(after: newline)))
            }
            let text = Redactor.redact(String(decoding: data, as: UTF8.self))
            return text.split(whereSeparator: \.isNewline).suffix(count).map(String.init)
        } catch { return [] }
    }

    private func withStoreLock<T>(_ body: () throws -> T) throws -> T {
        let fs = try ContainedFileSystem(root: paths.root)
        let runtimes = try relativePath(paths.runtimes)
        try fs.createDirectory(at: runtimes)
        let lock = try InstallLock(fs: fs, path: SafeRelativePath("\(runtimes)/.lock"))
        return try withExtendedLifetime(lock) { try body() }
    }

    private func relativePath(_ url: URL) throws -> SafeRelativePath {
        let base = paths.root.pathComponents; let target = url.pathComponents
        guard target.count > base.count, target.starts(with: base) else { throw LauncherError.unsafePath("runtime path") }
        return try SafeRelativePath(target.dropFirst(base.count).joined(separator: "/"))
    }

    private func record(_ error: any Error) async -> LauncherError {
        let error = launcherError(error)
        let entry = RuntimeErrorLog(error)
        await eventLog.log(error == .cancelled ? .info : .error, "runtime", entry.message, metadata: entry.metadata)
        return error
    }
}

/// AsyncThrowingStream can end immediately on cancellation, before its producer
/// releases the store lease. The checked iterator joins that producer first.
struct RuntimeInstallStream: AsyncSequence, Sendable {
    typealias Element = OperationEvent
    private let stream: AsyncThrowingStream<OperationEvent, any Error>
    private let lifetime: RuntimeInstallLifetime

    init(_ stream: AsyncThrowingStream<OperationEvent, any Error>) {
        self.stream = stream; lifetime = RuntimeInstallLifetime(worker: nil)
    }

    init(operation: @escaping @Sendable (AsyncThrowingStream<OperationEvent, any Error>.Continuation) async -> Void) {
        let (stream, continuation) = AsyncThrowingStream<OperationEvent, any Error>.makeStream()
        let worker = Task { await operation(continuation) }
        continuation.onTermination = { _ in worker.cancel() }
        self.stream = stream; lifetime = RuntimeInstallLifetime(worker: worker)
    }

    func cancelAndWait() async {
        lifetime.worker?.cancel()
        await lifetime.worker?.value
    }

    func makeAsyncIterator() -> Iterator { Iterator(iterator: stream.makeAsyncIterator(), lifetime: lifetime) }

    struct Iterator: AsyncIteratorProtocol {
        var iterator: AsyncThrowingStream<OperationEvent, any Error>.Iterator
        fileprivate let lifetime: RuntimeInstallLifetime
        mutating func next() async throws -> OperationEvent? {
            do {
                let event = try await iterator.next()
                if Task.isCancelled {
                    lifetime.worker?.cancel()
                    await lifetime.worker?.value
                    throw LauncherError.cancelled
                }
                if event == nil { await lifetime.worker?.value }
                return event
            } catch {
                lifetime.worker?.cancel()
                await lifetime.worker?.value
                if Task.isCancelled { throw LauncherError.cancelled }
                throw error
            }
        }
    }
}

private final class RuntimeInstallLifetime: Sendable {
    let worker: Task<Void, Never>?
    init(worker: Task<Void, Never>?) { self.worker = worker }
    deinit { worker?.cancel() }
}

private final class OwnedHTTPSession: Sendable {
    let client = URLSessionHTTPClient()
    deinit { client.invalidate() }
}

private actor LoggedRuntimeInstall {
    private let component: RuntimeComponent
    private let candidate: GPTKCandidate?
    private let installer: ComponentInstaller
    private let log: EventLog
    // Keep the shared HTTP session alive until this pull-driven operation is released.
    private let session: OwnedHTTPSession?
    private var iterator: ComponentInstallStream.Iterator?
    private var started = false
    private var done = false
    private var pulling = false

    init(component: RuntimeComponent, candidate: GPTKCandidate?, installer: ComponentInstaller, log: EventLog, session: OwnedHTTPSession?) {
        self.component = component; self.candidate = candidate; self.installer = installer; self.log = log; self.session = session
    }

    func next() async throws -> OperationEvent? {
        guard !pulling else { throw LauncherError.busy("Runtime stream already in use") }
        pulling = true
        defer { pulling = false }
        if done { return nil }
        do {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            if !started {
                var component = component
                if candidate != nil {
                    component = try RuntimeComponent(id: component.id, kind: component.kind, version: component.version,
                        sourceMode: .importFromGPTK, license: component.license, consent: component.consent)
                }
                iterator = installer.install(component, from: candidate).makeAsyncIterator()
                started = true
            }
            guard var next = iterator else { throw LauncherError.io("Missing runtime operation") }
            iterator = nil
            let event = try await next.next(isolation: self)
            iterator = next
            switch event {
            case .none: throw LauncherError.transport("Runtime stream ended before completion")
            case .failed(let error): throw error
            case .needsBatchApproval(let required, let available): throw LauncherError.insufficientSpace(required: required, available: available)
            case .phase(.failed): throw LauncherError.io("Runtime operation failed")
            case .phase(.cancelled): throw LauncherError.cancelled
            case .phase(.completed): done = true; iterator = nil
            default: break
            }
            return event
        } catch {
            done = true; iterator = nil
            let error = launcherError(error)
            let entry = RuntimeErrorLog(error)
            await log.log(error == .cancelled ? .info : .error, "runtime", entry.message, metadata: entry.metadata)
            throw error
        }
    }
}

/// Associated free text is untrusted; only fixed case names and approved structured values are logged.
struct RuntimeErrorLog {
    let message: String
    let metadata: [String: String]

    init(_ error: LauncherError) {
        message = error == .cancelled ? "Runtime operation cancelled" : "Runtime operation failed"
        var fields: [String: String] = [:]
        let name: String
        switch error {
        case .unsafePath: name = "unsafePath"
        case .invalidDigest: name = "invalidDigest"
        case .sizeMismatch(_, let expected, let actual):
            name = "sizeMismatch"; fields = ["expectedSize": String(expected), "actualSize": String(actual)]
        case .digestMismatch: name = "digestMismatch"
        case .insufficientSpace(let required, let available):
            name = "insufficientSpace"; fields = ["required": String(required), "available": String(available)]
        case .http(let status, let url):
            name = "http"; fields = ["host": url.host ?? "unknown", "status": String(status)]
        case .transport: name = "transport"
        case .io: name = "io"
        case .busy: name = "busy"
        case .fileTooLarge(_, let limit): name = "fileTooLarge"; fields = ["limit": String(limit)]
        case .consentRequired: name = "consentRequired"
        case .processFailed(_, let exitCode, _): name = "processFailed"; fields = ["exitCode": String(exitCode)]
        case .gameEditionMismatch: name = "gameEditionMismatch"
        case .gameEditionUnknown: name = "gameEditionUnknown"
        case .gameDistributionUnsupported: name = "gameDistributionUnsupported"
        case .cancelled: name = "cancelled"
        case .journalCorrupt: name = "journalCorrupt"
        }
        fields["case"] = name
        metadata = fields
    }
}
