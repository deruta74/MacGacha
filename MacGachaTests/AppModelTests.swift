// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Observation
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
    @Test func recoveryDeferredCleanupStillLoadsInstalledRuntimeRows() async throws {
        let (model, fake, component) = try fixture()
        fake.setInstalled(try InstalledComponent(kind: component.kind, version: component.version.rawValue,
            installedAt: Date(), source: .download))
        fake.state.withLock { $0.sweepError = .busy("Launch recovery is required") }
        await model.start()
        #expect(model.rows.first?.state == .installed(source: .download))
        #expect(fake.snapshot.calls.contains("scan"))
    }
    @Test(arguments: [false, true]) func refusedBusyRemovalKeepsInstalledRow(bundleRemoval: Bool) async throws {
        if bundleRemoval {
            let url = try #require(Bundle.main.url(forResource: "runtime-manifest", withExtension: "json"))
            let manifest = try RuntimeManifest.load(from: url)
            let bundle = try #require(manifest.bundles.first { $0.backend == .d3dmetal })
            let fake = FakeRuntimeServices(), paths = testPaths()
            let installed = InstalledRuntimeBundle(id: bundle.id, root: paths.runtimes,
                wineBinary: paths.runtimes.appendingPathComponent("bin/wine"),
                digest: try Digest(algorithm: .sha256, hex: String(repeating: "a", count: 64)), source: .importFromGPTK)
            fake.state.withLock { $0.bundles[bundle.id.rawValue] = installed; $0.removeError = .busy("Game running") }
            let model = AppModel(paths: paths, manifest: manifest, services: fake, defaults: nil)
            await model.start(); await model.remove(bundle.id.rawValue)
            #expect(model.rows.first { $0.id == bundle.id.rawValue }?.state == .installed(source: .importFromGPTK))
            #expect(model.lastError != nil)
            #expect(fake.snapshot.bundles[bundle.id.rawValue] == installed)
            return
        }
        let (model, fake, component) = try fixture()
        let installed = try InstalledComponent(kind: component.kind, version: component.version.rawValue,
            installedAt: Date(), source: .download)
        fake.setInstalled(installed)
        await model.start()
        fake.state.withLock { $0.removeError = .busy("Game running") }
        await model.remove(component.id.rawValue)
        #expect(model.rows.first?.state == .installed(source: .download))
        #expect(model.lastError != nil)
        #expect(fake.snapshot.components == [installed])
    }
    @Test func gameArtCacheUsesBundleNamespaceAndFallback() {
        let caches = URL(fileURLWithPath: "/test/Library/Caches", isDirectory: true)
        #expect(AppModel.gameArtCacheDirectory(in: caches, bundleIdentifier: "com.lo7ted.macgacha").path
            == "/test/Library/Caches/com.lo7ted.macgacha/GameArt")
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

    @Test func diagnosticBundleIsCompleteFreshAndNotReentrant() async throws {
        let (model, fake, _) = try fixture()
        let first = Task { try await model.makeDiagnosticBundle() }
        try await eventually { fake.snapshot.exportCount == 1 }
        #expect(model.isExporting)
        await #expect(throws: LauncherError.busy("Diagnostics export already in progress")) {
            try await model.makeDiagnosticBundle()
        }
        #expect(fake.snapshot.exportCount == 1)
        fake.releaseExport()
        let url = try await first.value
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Data(contentsOf: url) == completedDiagnosticBytes)
        #expect(!model.isExporting)
        let second = Task { try await model.makeDiagnosticBundle() }
        try await eventually { fake.snapshot.exportCount == 2 }
        fake.releaseExport()
        let other = try await second.value
        defer { try? FileManager.default.removeItem(at: other) }
        #expect(other != url)
        #expect(try Data(contentsOf: other) == completedDiagnosticBytes)
    }

    @Test func diagnosticFailureRemovesPartialTemporaryFile() async throws {
        let (model, fake, _) = try fixture()
        let failure = LauncherError.io("injected failure")
        fake.state.withLock { $0.exportError = failure }
        let export = Task { try await model.makeDiagnosticBundle() }
        try await eventually { fake.snapshot.exportCount == 1 }
        let partial = try #require(fake.snapshot.exportURLs.first)
        #expect(FileManager.default.fileExists(atPath: partial.path))
        fake.releaseExport()
        await #expect(throws: failure) { try await export.value }
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(!model.isExporting && model.lastError == failure.userMessage)
    }

    @Test func diagnosticCancellationRemovesPartialTemporaryFile() async throws {
        let (model, fake, _) = try fixture()
        let export = Task { try await model.makeDiagnosticBundle() }
        try await eventually { fake.snapshot.exportCount == 1 }
        let partial = try #require(fake.snapshot.exportURLs.first)
        export.cancel(); fake.releaseExport()
        await #expect(throws: LauncherError.cancelled) { try await export.value }
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(!model.isExporting && model.lastError == nil)
    }

    @Test func emptyDiagnosticResultIsRejectedAndRemoved() async throws {
        let (model, fake, _) = try fixture()
        fake.state.withLock { $0.exportData = Data() }
        let export = Task { try await model.makeDiagnosticBundle() }
        try await eventually { fake.snapshot.exportCount == 1 }
        let output = try #require(fake.snapshot.exportURLs.first)
        fake.releaseExport()
        await #expect(throws: LauncherError.io("Diagnostics export produced no bundle")) { try await export.value }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(!model.isExporting)
    }

    @Test func legacyDiagnosticExportPreservesDestinationOnFailureThenPublishesCompleteFile() async throws {
        let (model, fake, _) = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacGachaExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("saved.zip")
        let original = Data("previous bundle".utf8)
        try original.write(to: destination)
        fake.state.withLock { $0.exportError = .io("injected") }
        let failed = Task { await model.exportDiagnostics(to: destination) }
        try await eventually { fake.snapshot.exportCount == 1 }
        let partial = try #require(fake.snapshot.exportURLs.first)
        #expect(partial != destination)
        #expect(try Data(contentsOf: destination) == original)
        fake.releaseExport(); await failed.value
        #expect(try Data(contentsOf: destination) == original)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        fake.state.withLock { $0.exportError = nil }
        let retry = Task { await model.exportDiagnostics(to: destination) }
        try await eventually { fake.snapshot.exportCount == 2 }
        #expect(try Data(contentsOf: destination) == original)
        fake.releaseExport(); await retry.value
        #expect(try Data(contentsOf: destination) == completedDiagnosticBytes)
        for url in fake.snapshot.exportURLs { #expect(!FileManager.default.fileExists(atPath: url.path)) }
    }

    @Test func refreshRuntimesScansWithoutSweepAndPreservesActiveWork() async throws {
        let (model, fake, component) = try fixture()
        defer { fake.finish() }
        await model.start()
        model.install(component.id.rawValue)
        try await eventually { fake.snapshot.installs.count == 1 }
        fake.emit(.phase(.verifying))
        try await eventually { model.rows.first?.state == .working(phase: .verifying, fraction: nil) }
        let dxmt = try InstalledComponent(kind: .dxmt, version: "1.0", installedAt: Date(), source: .download)
        fake.setInstalled(dxmt)
        await model.refreshRuntimes()
        #expect(model.rows.first?.state == .working(phase: .verifying, fraction: nil))
        #expect(model.rows.contains { $0.id == "dxmt-1.0" && $0.state == .installed(source: .download) })
        await model.start()
        #expect(fake.snapshot.calls.filter { $0 == "sweep" }.count == 1)
        #expect(fake.snapshot.calls.filter { $0 == "scan" }.count == 2)
        fake.state.withLock { $0.scanError = .io("https://example.invalid/?cursor=private-value") }
        await model.refreshRuntimes()
        #expect(model.lastError == LauncherError.io("").userMessage)
        #expect(model.rows.first?.state == .working(phase: .verifying, fraction: nil))
    }

    @Test func staleRefreshCannotUndoCompletedInstall() async throws {
        let (model, fake, component) = try fixture()
        model.install(component.id.rawValue)
        try await eventually { fake.snapshot.installs.count == 1 }
        fake.state.withLock { $0.holdNextScan = true }
        let refresh = Task { await model.refreshRuntimes() }
        try await eventually { fake.snapshot.scanWaiter != nil }
        fake.setInstalled(try InstalledComponent(kind: .wine, version: component.version.rawValue,
            installedAt: Date(), source: .download))
        fake.emit(.phase(.completed)); fake.finish()
        try await eventually { model.rows.first?.state == .installed(source: .download) }
        fake.releaseScan()
        await refresh.value
        #expect(model.rows.first?.state == .installed(source: .download))
    }

    @Test func startRemainsOneShotAfterFailureAndRefreshCanRetryScan() async throws {
        let (model, fake, component) = try fixture()
        fake.state.withLock { $0.scanError = .io("injected scan failure") }
        await model.start()
        #expect(!model.isStarting && model.lastError == LauncherError.io("").userMessage)
        await model.start()
        #expect(fake.snapshot.calls == ["sweep", "scan"])
        fake.state.withLock { $0.scanError = nil }
        fake.setInstalled(try InstalledComponent(kind: component.kind, version: component.version.rawValue,
            installedAt: Date(), source: .download))
        await model.refreshRuntimes()
        #expect(model.rows.first?.state == .installed(source: .download))
        #expect(fake.snapshot.calls == ["sweep", "scan", "scan"])
    }

    @Test func currentProcessFactoryIsInertUnderXCTest() async throws {
        try #require(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)
        for model in [AppModel.forCurrentProcess(), AppModel.live()] {
            #expect(model.rows.isEmpty && model.gameArt.isEmpty && model.logLines.isEmpty)
            #expect(model.installRoot.path.hasPrefix(FileManager.default.temporaryDirectory.path))
            let root = model.installRoot.deletingLastPathComponent()
            await model.start()
            await model.refreshRuntimes()
            await model.loadGameArt()
            #expect(!FileManager.default.fileExists(atPath: root.path))
            #expect(model.rows.isEmpty && !model.isStarting && model.lastError == nil)
        }
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

    @Test func bundledManifestDecodesPinnedBundles() throws {
        let url = try #require(Bundle.main.url(forResource: "runtime-manifest", withExtension: "json"))
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: url))
        #expect(manifest.schemaVersion == 3)
        #expect(manifest.components.count == 9)
        let fps = try #require(manifest.components.first { $0.id.rawValue == GenshinFps.componentID })
        #expect(fps.kind == .genshinFps && fps.archive == .zip)
        #expect(fps.license.name == "GPL-3.0-only" && fps.license.redistributable && fps.consent == nil)
        #expect(fps.rootPath == (try SafeRelativePath("x86_64-windows")))
        #expect(fps.size == 223200 && fps.installedSize == 220360)
        #expect(fps.sha256?.hex == "4ee7c3920370e3369f8256132817de0dd9b4b553cc086a2d0eafdacf3de0312c")
        #expect(fps.url?.absoluteString == "https://github.com/deruta74/MacGacha/releases/download/genshin-fps-unlock-1/genshin-fps-unlock-1.zip")
        #expect(manifest.bundles.allSatisfy { !$0.components.contains(fps.id) })
        let surround = try #require(manifest.components.first { $0.id.rawValue == SurroundAudio.componentID })
        #expect(surround.kind == .surroundAudio && surround.archive == .zip)
        #expect(surround.license.name == "LGPL-2.1-or-later" && surround.license.redistributable)
        #expect(manifest.bundles.allSatisfy { !$0.components.contains(surround.id) })
        let crypt32 = try #require(manifest.components.first { $0.id.rawValue == Crypt32Fix.componentID })
        #expect(crypt32.kind == .crypt32Fix && crypt32.archive == .zip)
        #expect(crypt32.license.name == "LGPL-2.1-or-later" && crypt32.license.redistributable)
        #expect(crypt32.url?.absoluteString == "https://github.com/deruta74/MacGacha/releases/download/crypt32-fix-wine-11.20-1/crypt32-fix-wine-11.20-1.zip")
        for c in manifest.components {
            #expect(["github.com", "codeberg.org"].contains(c.url?.host ?? ""))
            #expect(c.sha256?.hex != String(repeating: "0", count: 64))
            #expect(c.installedSize != nil)
        }
        let metal = try #require(manifest.components.first { $0.kind == .d3dmetal })
        #expect(!metal.license.redistributable && metal.consent == .appleGPTK)
    }

    @Test func bundleRowsInstallAndRemoveThroughExistingPanelAPI() async throws {
        let url = try #require(Bundle.main.url(forResource: "runtime-manifest", withExtension: "json"))
        let manifest = try RuntimeManifest.load(from: url)
        let model = AppModel(paths: testPaths(), manifest: manifest, services: PreviewRuntimeServices(), defaults: nil)
        await model.start()
        #expect(model.rows.map(\.id) == manifest.bundles.map { $0.id.rawValue } + ["jadeite-4.1.0", "steam-shim-proton-10.0-4", Crypt32Fix.componentID, SurroundAudio.componentID, GenshinFps.componentID])
        #expect(manifest.bundles.first?.id.rawValue == "dxmt-wine11.0cx-dxmt0.80")
        #expect(model.rows.contains { $0.id == "dxmt-wine11.0-dxmt0.80" })
        let dxmt = manifest.bundles[0].id.rawValue
        model.install(dxmt)
        try await eventually { model.rows.first?.state == .installed(source: .download) }
        #expect(model.runtimesReady)
        await model.remove(dxmt)
        #expect(model.rows.first?.state == .notInstalled)
        #expect(!model.runtimesReady)
        let metal = try #require(manifest.bundles.first { $0.backend == .d3dmetal })
        model.install(metal.id.rawValue)
        try await eventually { model.consentRequest != nil }
        #expect(model.consentRequest?.body == AppleNotice.body)
        model.respondToConsent(accept: false)
        #expect(model.rows.first { $0.id == metal.id.rawValue }?.state == .notInstalled)
    }

    @Test func compatibilityRowsInstallRemoveAndSurviveRefresh() async throws {
        let url = try #require(Bundle.main.url(forResource: "runtime-manifest", withExtension: "json"))
        let manifest = try RuntimeManifest.load(from: url)
        let services = PreviewRuntimeServices()
        let model = AppModel(paths: testPaths(), manifest: manifest, services: services, defaults: nil)
        await model.start()
        for (id, name, license, size) in [("jadeite-4.1.0", "Jadeite", "MIT", Int64(48115)),
            ("steam-shim-proton-10.0-4", "Steam shim", "BSD-3-Clause", Int64(44476))] {
            let row = try #require(model.rows.first { $0.id == id })
            #expect(row.kindName == name && row.licenseName == license && row.downloadSize == size)
            #expect(!row.needsConsent && !row.canImportGPTK)
            model.install(id)
            try await eventually { model.rows.first { $0.id == id }?.state == .installed(source: .download) }
            await model.refreshRuntimes()
            #expect(model.rows.filter { $0.id == id }.count == 1)
            #expect(model.rows.first { $0.id == id }?.state == .installed(source: .download))
            await model.remove(id)
            #expect(model.rows.first { $0.id == id }?.state == .notInstalled)
        }
    }

    @Test(.timeLimit(.minutes(1))) func genshinFpsRowInstallsRefreshesAndRemovesWithoutChangingReadiness() async throws {
        let url = try #require(Bundle.main.url(forResource: "runtime-manifest", withExtension: "json"))
        let manifest = try RuntimeManifest.load(from: url), services = PreviewRuntimeServices()
        let model = AppModel(paths: testPaths(), manifest: manifest, services: services, defaults: nil)
        await model.start()
        let row = try #require(model.rows.first { $0.id == GenshinFps.componentID })
        let plans = GameDefinition.all.map { model.runtimeSetupPlan(for: $0.id) }
        #expect(plans.allSatisfy { $0?.items.contains { $0.id == GenshinFps.componentID } != true })
        #expect(row.kindName == String(localized: "Genshin FPS unlocker"))
        #expect(row.licenseName == "GPL-3.0-only" && row.downloadSize == 223200)
        #expect(!row.needsConsent && !row.canImportGPTK)
        model.install(GenshinFps.componentID)
        let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { changes.continuation.finish() }
        var iterator = changes.stream.makeAsyncIterator()
        while model.rows.first(where: { $0.id == GenshinFps.componentID })?.state != .installed(source: .download) {
            withObservationTracking { _ = model.rows } onChange: { changes.continuation.yield(()) }
            _ = await iterator.next()
        }
        await model.refreshRuntimes()
        #expect(model.rows.filter { $0.id == GenshinFps.componentID }.count == 1)
        #expect(model.rows.first { $0.id == GenshinFps.componentID }?.state == .installed(source: .download))
        #expect(!model.runtimesReady)
        #expect(GameDefinition.all.map { model.runtimeSetupPlan(for: $0.id) } == plans)
        await model.remove(GenshinFps.componentID)
        #expect(model.rows.first { $0.id == GenshinFps.componentID }?.state == .notInstalled)
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
        try await eventually { model.rows.first?.state == .working(phase: .verifying, fraction: 0.95) }
        let preview = AppModel.preview()
        #expect(preview.rows.count == AppModel.sampleRows.count && !preview.isStarting)
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
        var bundleInstalls: [String] = []
        var components: [InstalledComponent] = []
        var bundles: [String: InstalledRuntimeBundle] = [:]
        var invalid: [InvalidRuntimeEntry] = []
        var candidates: [GPTKCandidate] = []
        var searchRoots: [[URL]] = []
        var continuation: AsyncThrowingStream<OperationEvent, any Error>.Continuation?
        var loggedErrors: [LauncherError] = []
        var exportCount = 0
        var exporter: CheckedContinuation<Void, Never>?
        var exportURLs: [URL] = []
        var exportError: LauncherError?
        var exportData = completedDiagnosticBytes
        var scanError: LauncherError?
        var sweepError: LauncherError?
        var removeError: LauncherError?
        var acceptError: LauncherError?
        var holdNextScan = false
        var scanWaiter: CheckedContinuation<RuntimeScan, any Error>?
        var heldScan: RuntimeScan?
    }
    let state = Mutex(State())
    let installEvents = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(32))
    let heldScanEvents = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var snapshot: State { state.withLock { $0 } }
    func scanBundles(_ manifest: RuntimeManifest) async throws -> [String: InstalledRuntimeBundle] { snapshot.bundles }
    func remove(_ bundle: RuntimeBundle, manifest: RuntimeManifest) async throws {
        try state.withLock {
            if let error = $0.removeError { throw error }
            $0.bundles[bundle.id.rawValue] = nil
        }
    }
    func scan() async throws -> RuntimeScan {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<RuntimeScan, any Error>? = state.withLock {
                $0.calls.append("scan")
                if let error = $0.scanError { return .failure(error) }
                let scan = RuntimeScan(components: $0.components, invalid: $0.invalid)
                if $0.holdNextScan {
                    $0.holdNextScan = false; $0.scanWaiter = continuation; $0.heldScan = scan
                    return nil
                }
                return .success(scan)
            }
            if let result { continuation.resume(with: result) }
            else { heldScanEvents.continuation.yield(()) }
        }
    }
    func sweepStaging() async throws {
        try state.withLock {
            $0.calls.append("sweep")
            if let error = $0.sweepError { throw error }
        }
    }
    func install(_ c: RuntimeComponent, from candidate: GPTKCandidate?) -> AsyncThrowingStream<OperationEvent, any Error> {
        AsyncThrowingStream { continuation in
            state.withLock { $0.calls.append("install"); $0.installs.append(Install(component: c, candidate: candidate)); $0.continuation = continuation }
            installEvents.continuation.yield(c.id.rawValue)
        }
    }
    func install(_ bundle: RuntimeBundle, manifest: RuntimeManifest, from candidate: GPTKCandidate?) -> RuntimeInstallStream {
        RuntimeInstallStream(AsyncThrowingStream { continuation in
            state.withLock { $0.bundleInstalls.append(bundle.id.rawValue); $0.continuation = continuation }
            installEvents.continuation.yield(bundle.id.rawValue)
        })
    }
    func remove(_ c: InstalledComponent) async throws {
        try state.withLock {
            $0.calls.append("remove")
            if let error = $0.removeError { throw error }
            $0.components.removeAll { $0 == c }
        }
    }
    func removeInvalid(_ entry: InvalidRuntimeEntry) async throws {
        state.withLock { $0.calls.append("removeInvalid"); $0.invalid.removeAll { $0 == entry } }
    }
    func isConsentAccepted(_ c: RuntimeComponent) -> Bool { state.withLock { c.consent == nil || $0.accepted } }
    func acceptConsent(for c: RuntimeComponent) throws {
        try state.withLock {
            if let error = $0.acceptError { throw error }
            $0.calls.append("accept"); $0.accepted = true; $0.acceptedCount += 1
        }
    }
    func locateGPTK(extraRoots: [URL]) async throws -> [GPTKCandidate] {
        state.withLock { $0.calls.append("locate"); $0.searchRoots.append(extraRoots); return $0.candidates }
    }
    @concurrent func exportDiagnostics(to url: URL) async throws {
        #expect(!exporterIsOnMainThread())
        try Data("partial".utf8).write(to: url)
        await withCheckedContinuation { continuation in
            state.withLock { $0.exportCount += 1; $0.exportURLs.append(url); $0.exporter = continuation }
        }
        try Task.checkCancellation()
        if let error = snapshot.exportError { throw error }
        try snapshot.exportData.write(to: url)
    }
    func recentLogLines(limit: Int) async -> [String] { state.withLock { $0.calls.append("logs") }; return ["sample log"] }
    func setInstalled(_ c: InstalledComponent) { state.withLock { $0.components = [c] } }
    func emit(_ event: OperationEvent) { snapshot.continuation?.yield(event) }
    func finish() { snapshot.continuation?.finish() }
    func fail(_ error: LauncherError) { state.withLock { $0.loggedErrors.append(error) }; snapshot.continuation?.finish(throwing: error) }
    func releaseExport() { state.withLock { let c = $0.exporter; $0.exporter = nil; return c }?.resume() }
    func releaseScan() {
        let held = state.withLock { value in
            let pair = (value.scanWaiter, value.heldScan)
            value.scanWaiter = nil; value.heldScan = nil
            return pair
        }
        if let waiter = held.0, let scan = held.1 { waiter.resume(returning: scan) }
    }
}

private let completedDiagnosticBytes = Data("PK complete synthetic bundle".utf8)
private func exporterIsOnMainThread() -> Bool { Thread.isMainThread }

private final class FakeGameArt: GameArtProviding, Sendable {
    let cachedArt: [String: GameArt]
    let freshArt: [String: GameArt]
    let refreshCount = Mutex(0)
    init(cachedArt: [String: GameArt], freshArt: [String: GameArt]) { self.cachedArt = cachedArt; self.freshArt = freshArt }
    func cached() -> [String: GameArt] { cachedArt }
    func refresh() async -> [String: GameArt] { refreshCount.withLock { $0 += 1 }; return freshArt }
}
