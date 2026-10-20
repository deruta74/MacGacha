// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine
import RuntimeManager
import Diagnostics

protocol RuntimeServices: Sendable {
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

    @concurrent func scan() async throws -> RuntimeScan {
        do { return try store.scan() }
        catch { throw await record(error) }
    }

    @concurrent func sweepStaging() async throws {
        do {
            try withStoreLock { try store.sweepStaging() }
            await eventLog.log(.info, "runtime", "Startup staging sweep completed")
        } catch { throw await record(error) }
    }

    func install(_ component: RuntimeComponent, from candidate: GPTKCandidate?) -> AsyncThrowingStream<OperationEvent, any Error> {
        let operation = LoggedRuntimeInstall(component: component, candidate: candidate, installer: installer,
            log: eventLog, session: session)
        return AsyncThrowingStream(unfolding: { try await operation.next() })
    }

    @concurrent func remove(_ component: InstalledComponent) async throws {
        do { try withStoreLock { try store.remove(component) } }
        catch { throw await record(error) }
    }

    @concurrent func removeInvalid(_ entry: InvalidRuntimeEntry) async throws {
        do { try withStoreLock { try store.removeInvalid(entry) } }
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
            return try GPTKImporter(searchRoots: [URL(fileURLWithPath: "/Volumes")] + Array(extraRoots.prefix(32))).locate()
        } catch { throw await record(error) }
    }

    @concurrent func exportDiagnostics(to url: URL) async throws {
        do { try await writeDiagnosticBundle(to: url) }
        catch { throw await record(error) }
    }

    @concurrent func makeDiagnosticBundle() async throws -> URL {
        do {
            return try await TemporaryDiagnosticBundle.make { try await self.writeDiagnosticBundle(to: $0) }
        } catch { throw await record(error) }
    }

    @concurrent private func writeDiagnosticBundle(to url: URL) async throws {
        let scan = try store.scan()
        let runtimes = Dictionary(uniqueKeysWithValues: scan.components.map {
            ("\($0.kind.rawValue)-\($0.version)", $0.source.rawValue)
        })
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        try await DiagnosticBundle(logDirectory: paths.logs, runner: SystemProcessRunner())
            .export(to: url, systemInfo: .current(appVersion: version), runtimes: runtimes, failureStage: nil)
    }

    @concurrent func recentLogLines(limit: Int) async -> [String] {
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
    private var iterator: AsyncThrowingStream<OperationEvent, any Error>.Iterator?
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
        case .cancelled: name = "cancelled"
        case .journalCorrupt: name = "journalCorrupt"
        }
        fields["case"] = name
        metadata = fields
    }
}
