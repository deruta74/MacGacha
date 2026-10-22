// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import TestSupport

@Test(.timeLimit(.minutes(1)))
func cleanTreeIsClean() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let md5 = try ManifestFile(path: SafeRelativePath("Data with spaces/日本語.bin"), size: 3,
        digest: Digest(algorithm: .md5, hex: "900150983cd24fb0d6963f7d28e17f72"))
    let sha = try ManifestFile(path: SafeRelativePath("sha"), size: 3,
        digest: Digest(algorithm: .sha256, hex: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
    let empty = try vManifest("empty", "")
    try fs.writeAtomically(Data("abc".utf8), to: md5.path)
    try fs.writeAtomically(Data("abc".utf8), to: sha.path)
    try fs.writeAtomically(Data(), to: empty.path)
    let progress = Mutex<Int64>(0)
    let report = try await Verifier().verify(fs: fs, files: [md5, sha, empty], maxConcurrent: 2,
        progress: { delta in progress.withLock { $0 += delta } })
    #expect(report.isClean && report.problems.isEmpty)
    #expect(report.checkedFiles == 3 && report.checkedBytes == 6)
    #expect(progress.withLock { $0 } == 6)
}

@Test(.timeLimit(.minutes(1)))
func detectsMissingSizeAndDigestProblems() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let files = try ["missing", "short", "corrupt", "good"].map { try vManifest($0, "abc") }
    try fs.writeAtomically(Data("x".utf8), to: files[1].path)
    try fs.writeAtomically(Data("bad".utf8), to: files[2].path)
    try fs.writeAtomically(Data("abc".utf8), to: files[3].path)
    let report = try await Verifier().verify(fs: fs, files: files)
    #expect(report.problems == [files[0].path: .missing, files[1].path: .sizeMismatch(actual: 1),
        files[2].path: .digestMismatch(actual: opDigest("bad"))])
    #expect(!report.isClean && report.checkedFiles == 4 && report.checkedBytes == 6)
}

@Test(.timeLimit(.minutes(1)))
func quickModeSkipsHashing() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let file = try vManifest("a", "abc"); try fs.writeAtomically(Data("bad".utf8), to: file.path)
    let progress = Mutex<Int64>(0)
    let quick = try await Verifier().verify(fs: fs, files: [file], mode: .quick,
        progress: { delta in progress.withLock { $0 += delta } })
    #expect(quick.isClean && quick.checkedFiles == 1 && quick.checkedBytes == 0)
    #expect(progress.withLock { $0 } == 0)
    let full = try await Verifier().verify(fs: fs, files: [file], mode: .full)
    #expect(full.problems == [file.path: .digestMismatch(actual: opDigest("bad"))])
}

@Test(.timeLimit(.minutes(1)))
func excludedPathsAreNotChecked() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let files = try [vManifest("good", "abc"), vManifest("patched", "original")]
    try fs.writeAtomically(Data("abc".utf8), to: files[0].path)
    let report = try await Verifier().verify(fs: fs, files: files, excluding: [files[1].path])
    #expect(report.isClean && report.checkedFiles == 1 && report.checkedBytes == 3)
}

@Test(.timeLimit(.minutes(1)), arguments: ["directory", "symlink", "ancestor-symlink", "fifo"])
func directoryInPlaceOfFileIsNotRegularFile(kind: String) async throws {
    let temp = try TempDir(); let outside = try TempDir()
    let fs = try ContainedFileSystem(root: temp.url), control = try ContainedFileSystem(root: outside.url)
    try control.writeAtomically(Data("abc".utf8), to: SafeRelativePath("file"))
    let file = try vManifest(kind == "ancestor-symlink" ? "link/file" : "file", "abc")
    switch kind {
    case "directory": try fs.createDirectory(at: file.path)
    case "symlink": try FileManager.default.createSymbolicLink(at: file.path.resolved(against: temp.url), withDestinationURL: outside.url.appendingPathComponent("file"))
    case "ancestor-symlink": try FileManager.default.createSymbolicLink(at: temp.url.appendingPathComponent("link"), withDestinationURL: outside.url)
    default: #expect(mkfifo(file.path.resolved(against: temp.url).path, 0o600) == 0)
    }
    let report = try await Verifier().verify(fs: fs, files: [file])
    #expect(report.problems == [file.path: .notRegularFile])
    #expect(report.checkedFiles == 1 && report.checkedBytes == 0)
    #expect(try control.readFile(at: SafeRelativePath("file"), maxBytes: 3) == Data("abc".utf8))
}

@Test(.timeLimit(.minutes(1)))
func verifierCancellationBeforeAndDuringHashingThrowsCancelled() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let bytes = String(repeating: "a", count: 1 << 20); let file = try vManifest("large", bytes)
    try fs.writeAtomically(Data(bytes.utf8), to: file.path)
    let before = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        await #expect(throws: LauncherError.cancelled) { _ = try await Verifier().verify(fs: fs, files: []) }
    }
    await before.value
    let progress = Mutex<Int64>(0)
    await #expect(throws: LauncherError.cancelled) {
        _ = try await Verifier().verify(fs: fs, files: [file], maxConcurrent: 1, progress: { delta in
            progress.withLock { $0 += delta }
            withUnsafeCurrentTask { $0?.cancel() }
        })
    }
    #expect(progress.withLock { $0 } > 0 && progress.withLock { $0 } < Int64(bytes.utf8.count))
}

@Test(.timeLimit(.minutes(1)))
func verifierRejectsUpdatingMarkerAndBadInputs() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    for limit in [0, -1] {
        await #expect(throws: LauncherError.io("maxConcurrent must be positive")) {
            _ = try await Verifier().verify(fs: fs, files: [], maxConcurrent: limit)
        }
    }
    let invalid = try ManifestFile(path: SafeRelativePath("a"), size: -1, digest: opDigest(""))
    await #expect(throws: LauncherError.io("invalid manifest file size")) {
        _ = try await Verifier().verify(fs: fs, files: [invalid])
    }
    let huge = try ManifestFile(path: SafeRelativePath("huge"), size: Int64.max, digest: opDigest(""))
    let one = try ManifestFile(path: SafeRelativePath("one"), size: 1, digest: opDigest(""))
    await #expect(throws: LauncherError.io("verification byte count overflow")) {
        _ = try await Verifier().verify(fs: fs, files: [huge, one])
    }
    let upper = try vManifest("A", ""), lower = try vManifest("a", "")
    await #expect(throws: LauncherError.io("duplicate manifest path: a")) {
        _ = try await Verifier().verify(fs: fs, files: [upper, lower])
    }
    let file = try vManifest("a", "abc")
    try fs.writeAtomically(Data("abc".utf8), to: file.path)
    #expect(try await Verifier().verify(fs: fs, files: [file], maxConcurrent: Int.max).isClean)
    try InstallStateMarker(planID: SafeIdentifier("updating")).write(fs: fs)
    await #expect(throws: LauncherError.busy("install is updating")) {
        _ = try await Verifier().verify(fs: fs, files: [])
    }
}

@Test
func manifestFileAdaptsTasksAndRejectsInvalidDecodedSizes() throws {
    let task = try opPlan("adapt", [("a", "abc")]).files[0]
    let manifest = ManifestFile(task)
    #expect(manifest.path == task.path && manifest.size == 3 && manifest.digest == task.digest)
    let encoded = try JSONEncoder().encode(manifest)
    let decoded = try JSONDecoder().decode(ManifestFile.self, from: encoded)
    #expect(decoded.path == manifest.path && decoded.size == 3 && decoded.digest == manifest.digest)
    let malformed = String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: "\"size\":3", with: "\"size\":-1")
    #expect(throws: LauncherError.io("invalid manifest file size")) {
        _ = try JSONDecoder().decode(ManifestFile.self, from: Data(malformed.utf8))
    }
}

@Test
func repairPlanContainsOnlyBrokenFiles() throws {
    let base = try opPlan("repair-model", [("broken", "abc"), ("good", "def")])
    let fallbackDigest = vDigest("sha", algorithm: .sha256)
    let fallback = ChunkObject(id: "sha-fallback", urls: [URL(string: "https://cdn.test/sha-fallback")!],
        transferSize: 3, transferDigest: fallbackDigest, decodedSize: 3, decodedDigest: fallbackDigest)
    let local = FileTask(path: try SafeRelativePath("local"), size: 3, digest: fallbackDigest, extents: [
        Extent(source: .local(path: try SafeRelativePath("untrusted"), offset: 9), fileOffset: 0, length: 3,
            digest: fallbackDigest, fallbackChunkID: fallback.id),
    ])
    var objects = base.objects; objects[fallback.id] = fallback
    let plan = InstallPlan(id: base.id, objects: objects, files: base.files + [local], deletions: [try SafeRelativePath("obsolete")])
    let report = VerifyReport(problems: [base.files[0].path: .missing, local.path: .sizeMismatch(actual: 0)], checkedFiles: 3, checkedBytes: 0)
    let repair = try repairPlan(from: report, plan: plan, id: SafeIdentifier("repair-only"))
    #expect(repair.id.description == "repair-only")
    #expect(repair.files.map(\.path) == [base.files[0].path, local.path])
    #expect(Set(repair.objects.keys) == ["repair-model-0", "sha-fallback"])
    #expect(repair.files[0] == base.files[0])
    #expect(repair.files[1].extents == [Extent(source: .chunk(id: fallback.id), fileOffset: 0, length: 3, digest: fallbackDigest)])
    #expect(repair.deletions.isEmpty)
    try repair.validate()
}

@Test
func repairRejectsAllUnrepairablePathsAndUnknownReportEntries() throws {
    let digest = opDigest("abc")
    let tasks = try ["b", "a"].map { name in try FileTask(path: SafeRelativePath(name), size: 3, digest: digest, extents: [
        Extent(source: .local(path: SafeRelativePath("source"), offset: 0), fileOffset: 0, length: 3, digest: digest),
    ]) }
    let plan = InstallPlan(id: try SafeIdentifier("local-only"), objects: [:], files: tasks)
    let report = VerifyReport(problems: Dictionary(uniqueKeysWithValues: tasks.map { ($0.path, FileProblem.missing) }), checkedFiles: 2, checkedBytes: 0)
    #expect(throws: LauncherError.io("unrepairable: a, b")) {
        _ = try repairPlan(from: report, plan: plan, id: SafeIdentifier("cannot-repair"))
    }
    let unknown = VerifyReport(problems: [try SafeRelativePath("unknown"): .missing], checkedFiles: 1, checkedBytes: 0)
    #expect(throws: LauncherError.io("repair report contains unknown paths: unknown")) {
        _ = try repairPlan(from: unknown, plan: plan, id: SafeIdentifier("unknown"))
    }
    let clean = VerifyReport(problems: [:], checkedFiles: 2, checkedBytes: 6)
    let empty = try repairPlan(from: clean, plan: plan, id: SafeIdentifier("clean"))
    #expect(empty.files.isEmpty && empty.objects.isEmpty && empty.deletions.isEmpty)
    try empty.validate()
}

@Test(.timeLimit(.minutes(1)))
func corruptInstalledFileRepairsThroughInstallOperationAndVerifiesClean() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let plan = try opPlan("installed", [("a", "one"), ("b", "two")]); let cdn = MockCDN(); opServe(cdn, plan, ["one", "two"])
    _ = try await opCollect(opEngine(plan, temp.url, cdn).run())
    let files = plan.files.map(ManifestFile.init)
    #expect(try await Verifier().verify(fs: fs, files: files).isClean)
    try fs.writeAtomically(Data("bad".utf8), to: plan.files[0].path)
    let broken = try await Verifier().verify(fs: fs, files: files)
    #expect(broken.problems == [plan.files[0].path: .digestMismatch(actual: opDigest("bad"))])
    let repair = try repairPlan(from: broken, plan: plan, id: SafeIdentifier("repair"))
    let repairCDN = MockCDN(); repairCDN.serve("installed-0", data: Data("one".utf8))
    let events = try await opCollect(opEngine(repair, temp.url, repairCDN).run())
    #expect(events.last == .phase(.completed))
    #expect(repairCDN.requestLog.map(\.path) == ["installed-0"])
    #expect(try fs.readFile(at: plan.files[1].path, maxBytes: 3) == Data("two".utf8))
    #expect(try await Verifier().verify(fs: fs, files: files).isClean)
}

private func vDigest(_ body: String, algorithm: DigestAlgorithm = .md5) -> Digest {
    var hasher = StreamingHasher(algorithm); hasher.update(Data(body.utf8)); return hasher.finalize()
}
private func vManifest(_ path: String, _ body: String) throws -> ManifestFile {
    ManifestFile(path: try SafeRelativePath(path), size: Int64(body.utf8.count), digest: vDigest(body))
}
