// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import LauncherCore
import DownloadEngine
import RuntimeManager

/// Previews never create a network client, process runner, consent file or runtime directory.
final class PreviewRuntimeServices: RuntimeServices, Sendable {
    private struct State: Sendable { var installed: [InstalledComponent] = []; var accepted = false }
    private let state = Mutex(State())

    func scan() async throws -> RuntimeScan { state.withLock { RuntimeScan(components: $0.installed, invalid: []) } }
    func sweepStaging() async throws { }
    func install(_ c: RuntimeComponent, from candidate: GPTKCandidate?) -> AsyncThrowingStream<OperationEvent, any Error> {
        AsyncThrowingStream { continuation in
            do {
                let installed = try InstalledComponent(kind: c.kind, version: c.version.rawValue, installedAt: Date(),
                    source: candidate == nil ? .download : .importFromGPTK)
                state.withLock { $0.installed.removeAll { $0.kind == c.kind && $0.version == c.version.rawValue }; $0.installed.append(installed) }
                continuation.yield(.phase(.completed)); continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
    func remove(_ c: InstalledComponent) async throws { state.withLock { $0.installed.removeAll { $0 == c } } }
    func removeInvalid(_ entry: InvalidRuntimeEntry) async throws { }
    func isConsentAccepted(_ c: RuntimeComponent) -> Bool { state.withLock { c.consent == nil || $0.accepted } }
    func acceptConsent(for c: RuntimeComponent) throws { state.withLock { $0.accepted = true } }
    func locateGPTK(extraRoots: [URL]) async throws -> [GPTKCandidate] { [] }
    func exportDiagnostics(to url: URL) async throws { throw LauncherError.io("Export is unavailable in previews") }
    func recentLogLines(limit: Int) async -> [String] { [] }
}
