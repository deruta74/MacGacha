// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import LauncherCore
import DownloadEngine
import TestSupport
import Testing
@testable import Sophon

@Suite(.serialized) struct SophonPlannerTests {
    @Test func selectsFullScenarioAndVoices() throws {
        let branch = plannerBranch([
            BranchCategory(id: "game", matchingField: "game", isAudio: false, inFullScenario: true),
            BranchCategory(id: "extra", matchingField: "101", isAudio: false, inFullScenario: true),
            BranchCategory(id: "base", matchingField: "102", isAudio: false, inFullScenario: false),
            BranchCategory(id: "en", matchingField: "en-us", isAudio: true, inFullScenario: false),
            BranchCategory(id: "ja", matchingField: "ja-jp", isAudio: true, inFullScenario: true)])
        let build = plannerBuild(["ja", "base", "en", "game", "extra"])
        let selected = try SophonPlanner.selectCategories(branch, build: build, voices: ["en-us"])
        #expect(selected.map(\.id) == ["en", "extra", "game"])
    }

    @Test func ignoresBuildOnlyMiniVoices() throws {
        let branch = plannerBranch([BranchCategory(id: "game", matchingField: "game", isAudio: false, inFullScenario: true)])
        let build = plannerBuild(["game", "mini-en-us"])
        #expect(try SophonPlanner.selectCategories(branch, build: build, voices: []).map(\.id) == ["game"])
    }

    @Test func unknownVoiceThrows() {
        #expect(throws: LauncherError.io("unknown voice")) {
            try SophonPlanner.selectCategories(plannerBranch([]), build: plannerBuild(["mini-en-us"]), voices: ["mini-en-us"])
        }
    }

    @Test func missingBranchCategoryThrowsEvenWhenNotSelected() {
        let branch = plannerBranch([BranchCategory(id: "missing", matchingField: "ja-jp", isAudio: true, inFullScenario: true)])
        #expect(throws: LauncherError.io("missing build category")) {
            try SophonPlanner.selectCategories(branch, build: plannerBuild([]), voices: [])
        }
    }

    @Test func fullInstallCoversEveryChunk() throws {
        let file = try plannerFile("Data/a", [("first", "abc"), ("second", "defg")])
        let plan = try SophonPlanner.fullPlan(id: plannerID, target: [planned([file])])
        try plan.validate()
        #expect(plan.files.count == 1)
        #expect(plan.files[0].extents.map(\.fileOffset) == [0, 3])
        #expect(plan.files[0].extents.map(\.length) == [3, 4])
        #expect(plan.files[0].extents.map(\.source) == [.chunk(id: "first"), .chunk(id: "second")])
        #expect(plan.files[0].extents.allSatisfy { $0.fallbackChunkID == nil })
        let object = try #require(plan.objects["second"])
        #expect(object.codec == .zstd)
        #expect(object.transferSize == 14)
        #expect(object.decodedSize == 4)
        #expect(object.decodedDigest == md5(Data("defg".utf8)))
        #expect(object.transferDigest == md5(Data("compressed:defg".utf8)))
        #expect(object.urls.map(\.absoluteString) == ["https://cdn.hoyoverse.com/chunks/second"])
    }

    @Test func sharedChunkAcrossFilesIsOneObject() throws {
        let a = try plannerFile("a", [("shared", "abc")]); let b = try plannerFile("b", [("shared", "abc")])
        let plan = try makePlan([planned([a, b])])
        #expect(plan.objects.count == 1)
        #expect(plan.files.count == 2)
    }

    @Test func sameChunkTwoPrefixesBecomesMirrors() throws {
        let file = try plannerFile("a", [("shared", "abc")])
        let plan = try makePlan([planned([file], prefix: "https://z.hoyoverse.com/chunks"),
            planned([file], prefix: "https://a.yuanshen.com/chunks"), planned([file], prefix: "https://z.hoyoverse.com/chunks")])
        #expect(plan.objects["shared"]?.urls.map(\.absoluteString) == ["https://a.yuanshen.com/chunks/shared", "https://z.hoyoverse.com/chunks/shared"])
    }

    @Test func mirrorLimitKeepsCanonicalFirstSixteen() throws {
        let file = try plannerFile("a", [("shared", "abc")])
        let targets = (0..<20).reversed().map { planned([file], prefix: String(format: "https://cdn%02d.hoyoverse.com/chunks", $0)) }
        let plan = try makePlan(targets)
        #expect(plan.objects["shared"]?.urls.map(\.absoluteString) == (0..<16).map { String(format: "https://cdn%02d.hoyoverse.com/chunks/shared", $0) })
    }

    @Test(arguments: [0, 1, 2, 3, 4])
    func conflictingChunkMetadataThrows(variant: Int) throws {
        let file = try plannerFile("a", [("shared", "abc")]); let first = file.chunks[0]
        let other = SophonChunkRef(id: first.id, decodedMD5: variant == 2 ? md5(Data("bad".utf8)) : first.decodedMD5,
            fileOffset: 0, compressedSize: first.compressedSize + (variant == 0 ? 1 : 0),
            decodedSize: first.decodedSize + (variant == 1 ? 1 : 0),
            compressedMD5: variant == 3 ? md5(Data("bad".utf8)) : variant == 4 ? nil : first.compressedMD5)
        let second = SophonFile(path: try SafeRelativePath("b"), size: other.decodedSize, md5: file.md5, chunks: [other])
        let target = [planned([file]), planned([second])]
        // Both files would be skipped as unchanged. Metadata must still be checked before pruning.
        #expect(throws: LauncherError.io("conflicting chunk metadata")) {
            try makePlan(target, installed: InstalledSnapshot(categories: target))
        }
    }

    @Test func duplicatePathAcrossCategoriesIdenticalIsKeptOnce() throws {
        let file = try plannerFile("a", [("a", "aa"), ("b", "bb")])
        let reversed = SophonFile(path: file.path, size: file.size, md5: file.md5, chunks: Array(file.chunks.reversed()))
        #expect(try makePlan([planned([file]), planned([reversed])]).files.count == 1)
    }

    @Test func duplicatePathConflictThrows() throws {
        let a = try plannerFile("a", [("a", "abc")]); let b = try plannerFile("a", [("b", "def")])
        #expect(throws: LauncherError.io("conflicting file path")) { try makePlan([planned([a]), planned([b])]) }
    }

    @Test func caseVariantPathsAcrossCategoriesAreRejected() throws {
        let a = try plannerFile("Data/a", [("a", "abc")]); let b = try plannerFile("data/A", [("a", "abc")])
        #expect(throws: LauncherError.io("conflicting file path")) { try makePlan([planned([a]), planned([b])]) }
    }

    @Test func unchangedFilesAreSkipped() throws {
        let keep = try plannerFile("keep", [("keep", "abc")]); let add = try plannerFile("add", [("add", "def")])
        let plan = try makePlan([planned([keep, add])], installed: InstalledSnapshot(categories: [planned([keep])]))
        #expect(plan.files.map(\.path.description) == ["add"])
        #expect(Set(plan.objects.keys) == ["add"])
    }

    @Test func changedFileReusesLocalChunksWithFallback() throws {
        let old = try plannerFile("data", [("old-a", "abc"), ("old-b", "def")])
        let new = try plannerFile("data", [("new-a", "abc"), ("new-b", "xyz")])
        let plan = try makePlan([planned([new])], installed: InstalledSnapshot(categories: [planned([old])]))
        let file = try #require(plan.files.first)
        #expect(file.extents[0].source == .local(path: old.path, offset: 0))
        #expect(file.extents[0].fallbackChunkID == "new-a")
        #expect(file.extents[1].source == .chunk(id: "new-b"))
        #expect(Set(plan.objects.keys) == ["new-a", "new-b"])
    }

    @Test func localSourcePreferenceIsDeterministic() throws {
        let same = try plannerFile("same", [("b", "b"), ("a", "aa"), ("a", "aa")])
        let earlier = try plannerFile("0-removed", [("a", "aa")])
        let stable = try plannerFile("b-stable", [("a", "aa")])
        let laterStable = try plannerFile("c-stable", [("a", "aa")])
        let changed = try plannerFile("same", [("a", "aa"), ("new", "x")])
        let fresh = try plannerFile("fresh", [("a", "aa")])
        let installed = InstalledSnapshot(categories: [planned([laterStable, same, earlier, stable])])
        let plan = try makePlan([planned([fresh, changed, stable, laterStable])], installed: installed)
        #expect(plan.files.first { $0.path.description == "same" }?.extents[0].source == .local(path: same.path, offset: 1))
        #expect(plan.files.first { $0.path.description == "fresh" }?.extents[0].source == .local(path: stable.path, offset: 0))
        let noStable = try makePlan([planned([fresh])], installed: installed)
        #expect(noStable.files[0].extents[0].source == .local(path: earlier.path, offset: 0))
    }

    @Test func deletesFilesGoneFromTarget() throws {
        let a = try plannerFile("z", [("z", "z")]); let b = try plannerFile("a", [("a", "a")])
        let plan = try makePlan([], installed: InstalledSnapshot(categories: [planned([a, b])]))
        #expect(plan.deletions.map(\.description) == ["a", "z"])
        #expect(plan.files.isEmpty && plan.objects.isEmpty)
    }

    @Test func voiceRemovalKeepsSharedFiles() throws {
        let shared = try plannerFile("common", [("shared", "s")]); let voice = try plannerFile("voice/en", [("voice", "v")])
        let base = planned([shared], id: "base"); let audio = planned([shared, voice], id: "audio")
        let plan = try makePlan([base], installed: InstalledSnapshot(categories: [audio, base]))
        #expect(plan.deletions.map(\.description) == ["voice/en"])
        #expect(plan.files.isEmpty && plan.objects.isEmpty)
    }

    @Test func voiceAdditionKeepsSharedFiles() throws {
        let shared = try plannerFile("common", [("shared", "s")]); let voice = try plannerFile("voice/en", [("voice", "v")])
        let base = planned([shared], id: "base"); let audio = planned([shared, voice], id: "audio")
        let plan = try makePlan([audio, base], installed: InstalledSnapshot(categories: [base]))
        #expect(plan.files.map(\.path.description) == ["voice/en"])
        #expect(plan.deletions.isEmpty)
        #expect(Set(plan.objects.keys) == ["voice"])
    }

    @Test func sameVersionGivesEmptyPlan() throws {
        let target = [planned([try plannerFile("a", [("a", "a")])])]
        let plan = try makePlan(target, installed: InstalledSnapshot(categories: target))
        #expect(plan.files.isEmpty && plan.objects.isEmpty && plan.deletions.isEmpty)
    }

    @Test func deletionOnlyUpdateHasNoObjects() throws {
        let keep = planned([try plannerFile("keep", [("keep", "a")])])
        let remove = planned([try plannerFile("remove", [("remove", "b")])])
        let plan = try makePlan([keep], installed: InstalledSnapshot(categories: [keep, remove]))
        #expect(plan.deletions.map(\.description) == ["remove"])
        #expect(plan.files.isEmpty && plan.objects.isEmpty)
    }

    @Test func unreferencedTargetChunksArePruned() throws {
        let old = try plannerFile("keep", [("old", "a")])
        let sameContentDifferentChunks = try plannerFile("keep", [("different-id", "a")])
        let add = try plannerFile("new", [("new", "b")])
        let plan = try makePlan([planned([sameContentDifferentChunks, add])], installed: InstalledSnapshot(categories: [planned([old])]))
        #expect(Set(plan.objects.keys) == ["new"])
    }

    @Test func canonicalPathsUseUTF8ByteOrder() throws {
        let files = try ["f", "e\u{301}", "z"].map { try plannerFile($0, [("chunk", "a")]) }
        #expect(try makePlan([planned(files)]).files.map(\.path.description) == ["e\u{301}", "f", "z"])
        #expect(try makePlan([], installed: InstalledSnapshot(categories: [planned(files)])).deletions.map(\.description) == ["e\u{301}", "f", "z"])
    }

    @Test func planIsDeterministicUnderShuffle() throws {
        let same = try plannerFile("keep", [("shared", "aa")])
        let old = try plannerFile("change", [("shared", "aa"), ("old", "bb")])
        let changed = try plannerFile("change", [("shared", "aa"), ("new", "cc")])
        let fresh = try plannerFile("fresh", [("shared", "aa")])
        let goneA = try plannerFile("gone/a", [("shared", "aa")]); let goneZ = try plannerFile("gone/z", [("shared", "aa")])
        let installed = [planned([old, same, goneA]), planned([goneZ, same])]
        let target = [planned([changed, fresh, same], prefix: "https://z.hoyoverse.com/c"),
            planned([changed, same], prefix: "https://a.hoyoverse.com/c")]
        let expected = try makePlan(target, installed: InstalledSnapshot(categories: installed)).planDigest
        for seed in 0..<20 {
            var rng = PlannerRNG(state: UInt64(seed))
            let shuffledTarget = shufflePlanned(target, using: &rng)
            let shuffledInstalled = shufflePlanned(installed, using: &rng)
            let plan = try makePlan(shuffledTarget, installed: InstalledSnapshot(categories: shuffledInstalled))
            #expect(plan.planDigest == expected, "seed \(seed)")
        }
    }

    @Test func planValidatesAndRejectsEnginePathConflicts() throws {
        let reserved = try plannerFile(".macgacha-staging/x", [("a", "a")])
        #expect(throws: LauncherError.unsafePath(reserved.path.description)) { try makePlan([planned([reserved])]) }
        let ancestor = try plannerFile("Data", [("a", "a")]); let child = try plannerFile("data/x", [("b", "b")])
        #expect(throws: LauncherError.io("invalid plan: file path is an ancestor of another destination")) {
            try makePlan([planned([ancestor, child])])
        }
        #expect(throws: LauncherError.io("invalid plan: deletion overlaps installed path")) {
            try makePlan([planned([child])], installed: InstalledSnapshot(categories: [planned([ancestor])]))
        }
    }

    @Test func updateRejectsAncestorHiddenByUnchangedFile() throws {
        let ancestor = try plannerFile("Data", [("a", "a")])
        let child = try plannerFile("data/x", [("b", "b")])
        #expect(throws: LauncherError.io("invalid plan: file path is an ancestor of another destination")) {
            try makePlan([planned([ancestor, child])], installed: InstalledSnapshot(categories: [planned([ancestor])]))
        }
    }

    @Test func installedAncestorCollisionCannotDeleteRetainedDescendant() throws {
        let ancestor = try plannerFile("Data", [("a", "a")])
        let child = try plannerFile("data/x", [("b", "b")])
        #expect(throws: LauncherError.io("invalid plan: file path is an ancestor of another destination")) {
            try makePlan([planned([child])], installed: InstalledSnapshot(categories: [planned([ancestor, child])]))
        }
    }

    @Test func unchangedFilesCannotHideEngineReservedPaths() throws {
        let file = try plannerFile(".macgacha-staging/x", [("a", "a")])
        let categories = [planned([file])]
        #expect(throws: LauncherError.unsafePath(file.path.description)) {
            try makePlan(categories, installed: InstalledSnapshot(categories: categories))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACGACHA_SPIKE_FIXTURES"] != nil, "Set MACGACHA_SPIKE_FIXTURES for local update analysis"))
    func realUpdateDiffMatchesAnalysis() async throws {
        let old = try await realPlanned(game: "zzz", build: "main", fields: ["game"])
        let new = try await realPlanned(game: "zzz", build: "pre_download", fields: ["game"])
        let oldFiles = Dictionary(uniqueKeysWithValues: old.flatMap(\.manifest.files).map { ($0.path, $0) })
        let newFiles = new.flatMap(\.manifest.files)
        let newPaths = Set(newFiles.map(\.path))
        let unchanged = Set(newFiles.filter { oldFiles[$0.path]?.size == $0.size && oldFiles[$0.path]?.md5 == $0.md5 }.map(\.path))
        let added = newPaths.subtracting(oldFiles.keys).count
        let deleted = Set(oldFiles.keys).subtracting(newPaths).count
        let keys = Set(oldFiles.values.flatMap(\.chunks).map { PlannerContent(md5: $0.decodedMD5, size: $0.decodedSize) })
        let targetRefs = newFiles.flatMap(\.chunks)
        let reusable = targetRefs.filter { keys.contains(PlannerContent(md5: $0.decodedMD5, size: $0.decodedSize)) }.count
        #expect(unchanged.count == 9_867); #expect(added == 843); #expect(deleted == 710)
        #expect(targetRefs.count == 59_307); #expect(reusable == 52_061)
        let plan = try makePlan(new, installed: InstalledSnapshot(categories: old))
        #expect(plan.files.count == newFiles.count - unchanged.count)
        #expect(plan.deletions.count == 710)
        let plannedLocal = plan.files.flatMap(\.extents).filter { if case .local = $0.source { true } else { false } }.count
        let expectedLocal = newFiles.filter { !unchanged.contains($0.path) }.flatMap(\.chunks).filter {
            keys.contains(PlannerContent(md5: $0.decodedMD5, size: $0.decodedSize))
        }.count
        #expect(plannedLocal == expectedLocal)
        print("PLANNER ZZZ: unchanged=\(unchanged.count), added=\(added), deleted=\(deleted), reusable_target_refs=\(reusable)/\(targetRefs.count), planned_local=\(plannedLocal)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACGACHA_SPIKE_FIXTURES"] != nil, "Set MACGACHA_SPIKE_FIXTURES for Genshin scale measurement"))
    func realGenshinPlanMeasured() async throws {
        let target = try await realPlanned(game: "genshin", build: "main", fields: ["game", "en-us"])
        let before = try peakRSS(); let start = ContinuousClock.now
        let plan = try SophonPlanner.fullPlan(id: plannerID, target: target)
        let planned = ContinuousClock.now
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(plan)
        let end = ContinuousClock.now; let after = try peakRSS()
        try plan.validate()
        print("PLANNER GENSHIN: files=\(plan.files.count), objects=\(plan.objects.count), plan_seconds=\(seconds(start.duration(to: planned))), wall_seconds=\(seconds(start.duration(to: end))), encoded_bytes=\(encoded.count), peak_rss_before=\(before), peak_rss_after=\(after) bytes")
    }
}

private let plannerID = try! SafeIdentifier("planner-test")
private struct PlannerContent: Hashable { let md5: Digest; let size: Int64 }
private func makePlan(_ target: [PlannedCategory], installed: InstalledSnapshot? = nil) throws -> InstallPlan {
    let plan = try SophonPlanner.plan(id: plannerID, target: target, installed: installed)
    try plan.validate(); return plan
}
private func plannerFile(_ path: String, _ segments: [(String, String)]) throws -> SophonFile {
    var data = Data(); var chunks: [SophonChunkRef] = []
    for (id, text) in segments {
        let bytes = Data(text.utf8)
        chunks.append(SophonChunkRef(id: id, decodedMD5: md5(bytes), fileOffset: Int64(data.count),
            compressedSize: Int64(bytes.count + 10), decodedSize: Int64(bytes.count), compressedMD5: md5(Data(("compressed:" + text).utf8))))
        data.append(bytes)
    }
    return SophonFile(path: try SafeRelativePath(path), size: Int64(data.count), md5: md5(data), chunks: chunks)
}
private func planned(_ files: [SophonFile], id: String = "category", prefix: String = "https://cdn.hoyoverse.com/chunks") -> PlannedCategory {
    PlannedCategory(category: plannerCategory(id, prefix: prefix), manifest: SophonManifest(files: files))
}
private func plannerCategory(_ id: String, prefix: String = "https://cdn.hoyoverse.com/chunks", matching: String? = nil) -> BuildCategory {
    BuildCategory(id: id, matchingField: matching ?? id, manifest: ManifestRef(id: "manifest", decodedMD5: md5(Data()), compressedSize: 9, decodedSize: 0),
        manifestPrefix: URL(string: "https://cdn.hoyoverse.com/manifests")!, manifestSuffix: "", chunkPrefix: URL(string: prefix)!,
        chunkSuffix: "", compressedSize: 0, decodedSize: 0)
}
private func plannerBranch(_ categories: [BranchCategory]) -> GameBranch {
    GameBranch(gameID: "test", biz: "test_global", packageID: "package", password: "public", branch: "main", tag: "1", categories: categories)
}
private func plannerBuild(_ ids: [String]) -> SophonBuild {
    let fields = ["en": "en-us", "ja": "ja-jp", "extra": "101", "base": "102"]
    return SophonBuild(buildID: "test", tag: "1", categories: ids.map { plannerCategory($0, matching: fields[$0]) })
}
private struct PlannerRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return state }
}
private func shufflePlanned(_ values: [PlannedCategory], using rng: inout PlannerRNG) -> [PlannedCategory] {
    values.map { value in
        let files = value.manifest.files.map { file in
            SophonFile(path: file.path, size: file.size, md5: file.md5, chunks: file.chunks.shuffled(using: &rng))
        }.shuffled(using: &rng)
        return PlannedCategory(category: value.category, manifest: SophonManifest(files: files))
    }.shuffled(using: &rng)
}
private func realPlanned(game: String, build: String, fields: [String]) async throws -> [PlannedCategory] {
    let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MACGACHA_SPIKE_FIXTURES"]))
    let dir = root.appendingPathComponent(game)
    let data = try Data(contentsOf: dir.appendingPathComponent(build + "-getBuild.json"))
    let resolved = try await DeliveryAPI(http: deliveryHTTP(build: data)).build(testBranch())
    return try fields.map { field in
        let category = try #require(resolved.categories.first { $0.matchingField == field })
        let compressed = try Data(contentsOf: dir.appendingPathComponent(build + "-" + field + "-manifest.zst"))
        return PlannedCategory(category: category, manifest: try DeliveryAPI.decodeManifest(compressed, ref: category.manifest))
    }
}
private func peakRSS() throws -> Int {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw LauncherError.io("getrusage failed") }
    return usage.ru_maxrss // Bytes on Darwin, not the KiB used by Linux.
}
private func seconds(_ duration: Duration) -> Double { Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18 }
