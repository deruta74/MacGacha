// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import RuntimeManager
import HoYoPlayAPI
@testable import MacGacha

@Suite(.serialized)
@MainActor
struct AppModelTests {
    @Test func gameArtCacheUsesBundleNamespaceAndFallback() {
        let caches = URL(fileURLWithPath: "/test/Library/Caches", isDirectory: true)
        #expect(AppModel.gameArtCacheDirectory(in: caches, bundleIdentifier: "com.deruta.macgacha").path
            == "/test/Library/Caches/com.deruta.macgacha/GameArt")
        for identifier in [nil, ""] as [String?] {
            #expect(AppModel.gameArtCacheDirectory(in: caches, bundleIdentifier: identifier).path
                == "/test/Library/Caches/MacGacha/GameArt")
        }
    }

    @Test func installGatedWithoutConsentSetsPendingConsentAndStartsNothing() async throws {
        let (model, fake, component) = try fixture(kind: .d3dmetal)
        model.install(component.id.rawValue)
        try await eventually { model.consentRequest != nil }
        #expect(model.consentRequest?.id == component.id.rawValue)
        #expect(model.consentRequest?.mode == .download)
        #expect(model.consentRequest?.body == AppleNotice.body)
        #expect(fake.snapshot.installs.isEmpty && fake.snapshot.acceptedCount == 0)
    }

    @Test func declineConsentPersistsNothing() async throws {
        let (model, fake, component) = try fixture(kind: .d3dmetal)
        model.install(component.id.rawValue)
        try await eventually { model.consentRequest != nil }
        model.respondToConsent(accept: false)
        #expect(model.consentRequest == nil)
        #expect(fake.snapshot.acceptedCount == 0 && fake.snapshot.installs.isEmpty)
    }

    @Test func acceptConsentRecordsThenInstalls() async throws {
        let (model, fake, component) = try fixture(kind: .d3dmetal)
        defer { fake.finish() }
        model.install(component.id.rawValue)
        try await eventually { model.consentRequest != nil }
        model.respondToConsent(accept: true)
        try await eventually { fake.snapshot.installs.count == 1 }
        #expect(fake.snapshot.calls.firstIndex(of: "accept")! < fake.snapshot.calls.firstIndex(of: "install")!)
        #expect(model.consentRequest == nil)
        model.respondToConsent(accept: true)
        #expect(fake.snapshot.acceptedCount == 1)
    }

    @Test func progressMapsEventsAndEndsInstalledOnce() async throws {
        let (model, fake, component) = try fixture()
        model.install(component.id.rawValue)
        try await eventually { fake.snapshot.installs.count == 1 }
        fake.emit(.progress(downloaded: 25, totalNetwork: 100, staged: 0, totalStaged: 100))
        try await eventually { model.rows.first?.state == .working(phase: .staging, fraction: 0.25) }
        fake.setInstalled(try InstalledComponent(kind: component.kind, version: component.version.rawValue, installedAt: Date(), source: .download))
        fake.emit(.phase(.completed)); fake.emit(.phase(.completed)); fake.finish()
        try await eventually { model.rows.first?.state == .installed(source: .download) }
        #expect(fake.snapshot.calls.filter { $0 == "scan" }.count == 1)
    }

    @Test func cancelReturnsRowToNotInstalled() async throws {
        let (model, fake, component) = try fixture()
        model.install(component.id.rawValue)
        try await eventually { fake.snapshot.installs.count == 1 }
        model.cancel(component.id.rawValue)
        try await eventually { model.rows.first?.state == .notInstalled }
        #expect(model.lastError == nil)
    }

    @Test func cancelReinstallKeepsPreviouslyInstalledState() async throws {
        let (model, fake, component) = try fixture()
        fake.setInstalled(try InstalledComponent(kind: component.kind, version: component.version.rawValue, installedAt: Date(), source: .importFromGPTK))
        await model.start()
        model.install(component.id.rawValue)
        try await eventually { fake.snapshot.installs.count == 1 }
        model.cancel(component.id.rawValue)
        try await eventually { model.rows.first?.state == .installed(source: .importFromGPTK) }
    }

    @Test func failureSetsReadableLastErrorAndLogs() async throws {
        let (model, fake, component) = try fixture()
        model.install(component.id.rawValue)
        try await eventually { fake.snapshot.installs.count == 1 }
        fake.fail(.unsafePath("/Users/someone-else/private/token=secret"))
        try await eventually { model.lastError != nil }
        #expect(model.lastError == LauncherError.unsafePath("").userMessage)
        #expect(model.rows.first?.state == .failed(message: LauncherError.unsafePath("").userMessage))
        #expect(fake.snapshot.loggedErrors.count == 1)
        #expect(model.lastError?.contains("someone-else") == false)
        model.dismissError(); #expect(model.lastError == nil)
    }

    @Test func importWithNoCandidatesShowsChooseFolder() async throws {
        let (model, fake, component) = try fixture(kind: .d3dmetal)
        model.importGPTK(component.id.rawValue)
        try await eventually { model.consentRequest?.mode == .importGPTK }
        #expect(fake.snapshot.calls.isEmpty)
        model.respondToConsent(accept: true)
        try await eventually { model.importState == .notFound }
        #expect(fake.snapshot.installs.isEmpty)
        model.addGPTKSearchRoot(URL(fileURLWithPath: "/chosen/folder"))
        try await eventually { fake.snapshot.searchRoots.last?.last?.path == "/chosen/folder" }
        model.cancelImport(); #expect(model.importState == nil)
    }

    @Test func importUsesSelectedCandidate() async throws {
        let (model, fake, component) = try fixture(kind: .d3dmetal)
        defer { fake.finish() }
        let candidates = [candidate("one"), candidate("two")]
        fake.state.withLock { $0.accepted = true; $0.candidates = candidates }
        model.importGPTK(component.id.rawValue)
        try await eventually { model.importState == .choose(candidates) }
        #expect(fake.snapshot.installs.isEmpty)
        model.chooseCandidate(candidates[1])
        try await eventually { fake.snapshot.installs.count == 1 }
        #expect(fake.snapshot.installs.first?.candidate == candidates[1])
        #expect(model.importState == nil)
    }

    @Test func singleImportCandidateStartsAutomatically() async throws {
        let (model, fake, component) = try fixture(kind: .d3dmetal)
        defer { fake.finish() }
        let found = candidate("one")
        fake.state.withLock { $0.accepted = true; $0.candidates = [found] }
        model.importGPTK(component.id.rawValue)
        try await eventually { fake.snapshot.installs.count == 1 }
        #expect(fake.snapshot.installs.first?.candidate == found)
    }

    @Test func exportIsNotReentrant() async throws {
        let (model, fake, _) = try fixture()
        let url = URL(fileURLWithPath: "/tmp/not-written-by-fake.zip")
        let first = Task { await model.exportDiagnostics(to: url) }
        try await eventually { fake.snapshot.exportCount == 1 }
        #expect(model.isExporting)
        await model.exportDiagnostics(to: url)
        #expect(fake.snapshot.exportCount == 1)
        fake.releaseExport()
        await first.value
        #expect(!model.isExporting)
    }

    @Test func startupSweepsStagingAndShowsInvalidEntries() async throws {
        let (model, fake, _) = try fixture()
        fake.state.withLock { $0.invalid = [InvalidRuntimeEntry(kind: .wine, rawName: "broken", reason: "Invalid component marker", removable: true)] }
        #expect(model.isStarting)
        await model.start()
        #expect(!model.isStarting)
        #expect(Array(fake.snapshot.calls.prefix(3)) == ["sweep", "scan", "logs"])
        #expect(model.rows.last?.state == .invalid(reason: "Invalid component marker", removable: true))
        #expect(model.logLines == ["sample log"])
        let invalidID = try #require(model.rows.last?.id)
        await model.remove(invalidID)
        #expect(fake.snapshot.calls.contains("removeInvalid"))
        #expect(!model.rows.contains { $0.id == invalidID })
    }

    @Test func bundledManifestDecodesAndUsesSpecifiedPlaceholders() throws {
        let url = try #require(Bundle.main.url(forResource: "runtime-manifest", withExtension: "json"))
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: url))
        #expect(manifest.components.count == 3)
        for c in manifest.components {
            #expect(c.url?.absoluteString == "https://example.invalid/\(c.kind.rawValue).tar.xz")
            #expect(c.sha256?.hex == String(repeating: "0", count: 64))
            #expect(c.installedSize != nil)
        }
        let metal = try #require(manifest.components.first { $0.kind == .d3dmetal })
        #expect(!metal.license.redistributable && metal.consent == .appleGPTK)
    }

    @Test func progressIsThrottledAndPreviewHasNoLiveDependencies() async throws {
        let start = ContinuousClock.now
        let time = Mutex(start)
        let fake = FakeRuntimeServices(); let component = try appComponent()
        let model = AppModel(paths: testPaths(), manifest: try RuntimeManifest(components: [component]), services: fake,
            defaults: nil, now: { time.withLock { $0 } })
        defer { fake.finish() }
        model.install(component.id.rawValue)
        try await eventually { fake.snapshot.installs.count == 1 }
        fake.emit(.progress(downloaded: 1, totalNetwork: 100, staged: 0, totalStaged: 100))
        try await eventually { model.rows.first?.state == .working(phase: .staging, fraction: 0.01) }
        for index in 2...90 { fake.emit(.progress(downloaded: Int64(index), totalNetwork: 100, staged: 0, totalStaged: 100)) }
        fake.emit(.phase(.verifying))
        try await eventually { model.rows.first?.state == .working(phase: .verifying, fraction: nil) }
        time.withLock { $0 = start.advanced(by: .milliseconds(100)) }
        fake.emit(.progress(downloaded: 95, totalNetwork: 100, staged: 0, totalStaged: 100))
        try await eventually { model.rows.first?.state == .working(phase: .staging, fraction: 0.95) }
        let preview = AppModel.preview()
        #expect(preview.rows.count == 3 && !preview.isStarting)
    }

    @Test func runtimesReadyRequiresWineAndATranslator() async throws {
        let (model, fake, _) = try fixture()
        #expect(!model.runtimesReady)
        let wine = try InstalledComponent(kind: .wine, version: "1.0", installedAt: Date(), source: .download)
        let metal = try InstalledComponent(kind: .d3dmetal, version: "3.0", installedAt: Date(), source: .importFromGPTK)
        fake.state.withLock { $0.components = [wine, metal] }
        await model.start()
        #expect(model.runtimesReady)
        await model.remove("wine-1.0")
        #expect(!model.runtimesReady)
        let dxmt = try InstalledComponent(kind: .dxmt, version: "1.0", installedAt: Date(), source: .download)
        fake.state.withLock { $0.components = [wine, dxmt] }
        let second = AppModel(paths: testPaths(), manifest: try RuntimeManifest(components: []), services: fake, defaults: nil)
        await second.start()
        #expect(second.runtimesReady)
    }

    @Test func loadGameArtSeedsCachedThenRefreshesThroughFake() async throws {
        let url = URL(fileURLWithPath: "/fixture/cached.png")
        let fresh = URL(fileURLWithPath: "/fixture/fresh.png")
        let art = FakeGameArt(cachedArt: ["genshin": GameArt(background: url)], freshArt: ["zzz": GameArt(background: fresh)])
        let model = AppModel(paths: testPaths(), manifest: try RuntimeManifest(components: []), services: FakeRuntimeServices(), defaults: nil, artService: art)
        #expect(model.gameArt["genshin"]?.background == url)
        await model.loadGameArt()
        #expect(model.gameArt == ["zzz": GameArt(background: fresh)])
        #expect(art.refreshCount.withLock { $0 } == 1)
        #expect(AppModel.preview().gameArt.isEmpty)
    }

    @Test func installRootPersistsAndUserMessagesNeverExposePayloads() throws {
        let suite = "MacGachaTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(paths: testPaths(), manifest: try RuntimeManifest(components: []), services: FakeRuntimeServices(), defaults: defaults)
        let root = URL(fileURLWithPath: "/chosen/Games")
        model.setInstallRoot(root)
        #expect(model.installRoot.path == root.path)
        #expect(defaults.string(forKey: "installRoot") == root.path)
        let second = AppModel(paths: testPaths(), manifest: try RuntimeManifest(components: []), services: FakeRuntimeServices(), defaults: defaults)
        #expect(second.installRoot.path == root.path)
        #expect(LauncherError.http(status: 500, url: URL(string: "https://example.invalid/?secret=planted")!).userMessage.contains("planted") == false)
    }
}

@MainActor
private func fixture(kind: ComponentKind = .wine) throws -> (AppModel, FakeRuntimeServices, RuntimeComponent) {
    let fake = FakeRuntimeServices(); let component = try appComponent(kind: kind)
    return (AppModel(paths: testPaths(), manifest: try RuntimeManifest(components: [component]), services: fake, defaults: nil), fake, component)
}

private func testPaths() -> AppPaths {
    AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("MacGachaTests-\(UUID().uuidString)"))
}

private func appComponent(kind: ComponentKind = .wine) throws -> RuntimeComponent {
    try RuntimeComponent(id: SafeIdentifier("\(kind.rawValue)-1.0"), kind: kind, version: SafeIdentifier("1.0"), sourceMode: .download,
        url: URL(string: "https://example.invalid/\(kind.rawValue).tar.xz"), size: 1, installedSize: 1,
        sha256: Digest(algorithm: .sha256, hex: String(repeating: "0", count: 64)), archive: .tarXZ,
        license: ComponentLicense(name: "Test license", url: URL(string: "https://example.invalid/license")!,
            redistributable: kind != .d3dmetal, termsRevision: "1"), consent: kind == .d3dmetal ? .appleGPTK : nil)
}

private func candidate(_ name: String) -> GPTKCandidate {
    let root = URL(fileURLWithPath: "/fixture/\(name)")
    return GPTKCandidate(root: root, d3dmetalFramework: root.appendingPathComponent("D3DMetal.framework"), version: "3.0")
}

@MainActor
private func eventually(_ condition: () -> Bool, timeout: Duration = .seconds(5)) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(condition())
}

final class FakeRuntimeServices: RuntimeServices, Sendable {
    struct Install: Sendable { let component: RuntimeComponent; let candidate: GPTKCandidate? }
    struct State: Sendable {
        var accepted = false
        var acceptedCount = 0
        var calls: [String] = []
        var installs: [Install] = []
        var components: [InstalledComponent] = []
        var invalid: [InvalidRuntimeEntry] = []
        var candidates: [GPTKCandidate] = []
        var searchRoots: [[URL]] = []
        var continuation: AsyncThrowingStream<OperationEvent, any Error>.Continuation?
        var loggedErrors: [LauncherError] = []
        var exportCount = 0
        var exporter: CheckedContinuation<Void, Never>?
    }
    let state = Mutex(State())
    var snapshot: State { state.withLock { $0 } }
    func scan() async throws -> RuntimeScan {
        state.withLock { $0.calls.append("scan"); return RuntimeScan(components: $0.components, invalid: $0.invalid) }
    }
    func sweepStaging() async throws { state.withLock { $0.calls.append("sweep") } }
    func install(_ c: RuntimeComponent, from candidate: GPTKCandidate?) -> AsyncThrowingStream<OperationEvent, any Error> {
        AsyncThrowingStream { continuation in
            state.withLock { $0.calls.append("install"); $0.installs.append(Install(component: c, candidate: candidate)); $0.continuation = continuation }
        }
    }
    func remove(_ c: InstalledComponent) async throws {
        state.withLock { $0.calls.append("remove"); $0.components.removeAll { $0 == c } }
    }
    func removeInvalid(_ entry: InvalidRuntimeEntry) async throws {
        state.withLock { $0.calls.append("removeInvalid"); $0.invalid.removeAll { $0 == entry } }
    }
    func isConsentAccepted(_ c: RuntimeComponent) -> Bool { state.withLock { c.consent == nil || $0.accepted } }
    func acceptConsent(for c: RuntimeComponent) throws { state.withLock { $0.calls.append("accept"); $0.accepted = true; $0.acceptedCount += 1 } }
    func locateGPTK(extraRoots: [URL]) async throws -> [GPTKCandidate] {
        state.withLock { $0.calls.append("locate"); $0.searchRoots.append(extraRoots); return $0.candidates }
    }
    func exportDiagnostics(to url: URL) async throws {
        await withCheckedContinuation { continuation in state.withLock { $0.exportCount += 1; $0.exporter = continuation } }
    }
    func recentLogLines(limit: Int) async -> [String] { state.withLock { $0.calls.append("logs") }; return ["sample log"] }
    func setInstalled(_ c: InstalledComponent) { state.withLock { $0.components = [c] } }
    func emit(_ event: OperationEvent) { snapshot.continuation?.yield(event) }
    func finish() { snapshot.continuation?.finish() }
    func fail(_ error: LauncherError) { state.withLock { $0.loggedErrors.append(error) }; snapshot.continuation?.finish(throwing: error) }
    func releaseExport() { state.withLock { let c = $0.exporter; $0.exporter = nil; return c }?.resume() }
}

private final class FakeGameArt: GameArtProviding, Sendable {
    let cachedArt: [String: GameArt]
    let freshArt: [String: GameArt]
    let refreshCount = Mutex(0)
    init(cachedArt: [String: GameArt], freshArt: [String: GameArt]) { self.cachedArt = cachedArt; self.freshArt = freshArt }
    func cached() -> [String: GameArt] { cachedArt }
    func refresh() async -> [String: GameArt] { refreshCount.withLock { $0 += 1 }; return freshArt }
}
