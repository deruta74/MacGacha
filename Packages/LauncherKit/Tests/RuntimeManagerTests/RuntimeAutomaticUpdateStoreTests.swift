// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
@testable import RuntimeManager
import TestSupport

@Suite struct RuntimeAutomaticUpdateStoreTests {
    @Test func graphicsDeclinePersistsPerVersionAndTheNextVersionIsNotDeclined() throws {
        let temp = try TempDir(), paths = AppPaths(root: temp.url)
        try RuntimeAutomaticUpdateStore(paths: paths).declineGraphics(version: "4.0b4")
        let reopened = try RuntimeAutomaticUpdateStore(paths: paths).load()
        #expect(reopened.declinedGraphicsVersions.contains("4.0b4"))
        #expect(!reopened.declinedGraphicsVersions.contains("4.0b5"))
    }
    @Test func pendingReplacementSurvivesRestartAndNeedsVerifiedNormalSession() throws {
        let temp = try TempDir(), paths = AppPaths(root: temp.url)
        let store = RuntimeAutomaticUpdateStore(paths: paths)
        try store.retain(familyID: "bundle-d3dmetal", previousID: "old-wine", replacementID: "new-wine")
        #expect(try RuntimeAutomaticUpdateStore(paths: paths).load().replacements.count == 1)
        #expect(try store.load().replacements.first?.verified == false)
        try store.recordVerifiedSession(bundleID: "unrelated", componentIDs: [], confirmedRunningSeconds: 120, sessionID: UUID())
        #expect(try store.load().replacements.first?.verified == false)
        try store.recordVerifiedSession(bundleID: "new-wine", componentIDs: [], confirmedRunningSeconds: 120, sessionID: UUID())
        #expect(try RuntimeAutomaticUpdateStore(paths: paths).load().replacements.first?.verified == true)
    }
    @Test func helperProofRequiresThatExactComponentAndPinCancelsCleanup() throws {
        let temp = try TempDir(), store = RuntimeAutomaticUpdateStore(paths: AppPaths(root: temp.url))
        try store.retain(familyID: "component-surroundAudio", previousID: "old-helper", replacementID: "new-helper")
        try store.recordVerifiedSession(bundleID: "new-helper", componentIDs: [], confirmedRunningSeconds: 120, sessionID: UUID())
        #expect(try store.load().replacements.first?.verified == false)
        try store.recordVerifiedSession(bundleID: "game-runtime", componentIDs: ["new-helper"], confirmedRunningSeconds: 120, sessionID: UUID())
        #expect(try store.load().replacements.first?.verified == true)
        try store.cancelCleanup(familyID: "component-surroundAudio")
        #expect(try store.load().replacements.isEmpty)
    }
    @Test func chainedUpdatesRetainEveryPreviousVersionUntilCurrentIsProven() throws {
        let temp = try TempDir(), store = RuntimeAutomaticUpdateStore(paths: AppPaths(root: temp.url))
        try store.retain(familyID: "bundle-dxmt", previousID: "wine-a", replacementID: "wine-b")
        try store.retain(familyID: "bundle-dxmt", previousID: "wine-b", replacementID: "wine-c")
        try store.recordVerifiedSession(bundleID: "wine-c", componentIDs: [], confirmedRunningSeconds: 120, sessionID: UUID())
        #expect(try store.load().replacements.count == 2)
        #expect(try store.load().replacements.allSatisfy(\.verified))
    }
    @Test func storeRejectsSymlinkAndDoesNotOverwriteItsTarget() throws {
        let temp = try TempDir(), outside = try TempDir(), paths = AppPaths(root: temp.url)
        let target = outside.url.appendingPathComponent("private.json")
        try Data("unchanged".utf8).write(to: target)
        try FileManager.default.createDirectory(at: paths.root.appendingPathComponent("RuntimeCatalog"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: paths.root.appendingPathComponent("RuntimeCatalog/automatic-updates.json"), withDestinationURL: target)
        let store = RuntimeAutomaticUpdateStore(paths: paths)
        #expect(throws: (any Error).self) { try store.retain(familyID: "bundle-dxmt", previousID: "old", replacementID: "new") }
        #expect(try String(contentsOf: target, encoding: .utf8) == "unchanged")
    }
}
