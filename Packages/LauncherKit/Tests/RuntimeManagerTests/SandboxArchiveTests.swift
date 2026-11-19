// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
@testable import RuntimeManager
import TestSupport

@Suite struct SandboxArchiveTests {
    private let list = try! SafeRelativePath("beyond_pkg_version")

    @Test func extractsOnlyPackageFilesWithByteProgress() async throws {
        let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url)
        let entries = [ArchiveTestEntry("BeyondAssets/", type: .directory),
            ArchiveTestEntry("BeyondAssets/BeyondAssistEditor/BeyondEditor.exe", body: "editor"),
            ArchiveTestEntry("BeyondAssets/日本語", body: "asset"), ArchiveTestEntry("beyond_pkg_version", body: "list")]
        try fs.writeAtomically(archiveTestData(entries, format: .zip), to: SafeRelativePath("package.zip"))
        let extractor = SandboxArchiveExtractor(), progress = SandboxArchiveProgress()
        #expect(try await extractor.expandedSize(archive: SafeRelativePath("package.zip"), in: fs, listPath: list) == 15)
        try await extractor.extract(archive: SafeRelativePath("package.zip"), in: fs, to: SafeRelativePath("stage"), listPath: list) {
            progress.append($0, $1)
        }
        #expect(try fs.readFile(at: SafeRelativePath("stage/BeyondAssets/BeyondAssistEditor/BeyondEditor.exe"), maxBytes: 6) == Data("editor".utf8))
        #expect(try fs.readFile(at: SafeRelativePath("stage/beyond_pkg_version"), maxBytes: 4) == Data("list".utf8))
        let samples = progress.values
        #expect(samples.first?.0 == 0)
        #expect(samples.last?.0 == 15)
        #expect(samples.allSatisfy { $0.1 == 15 && $0.0 <= 15 })
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0.0 <= $1.0 })
    }

    @Test(arguments: ["extra", "outside", "absolute", "symlink", "collision", "implicitCollision", "unicodeCollision", "fileParent", "missingList", "missingAssets", "rootDirectory"])
    func refusesUnsafePackageBeforeCreatingTarget(_ attack: String) async throws {
        let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url)
        var entries = [ArchiveTestEntry("BeyondAssets/editor.exe", body: "editor"), ArchiveTestEntry("beyond_pkg_version", body: "list")]
        switch attack {
        case "extra": entries.append(ArchiveTestEntry("config.ini", body: "wrong"))
        case "outside": entries.append(ArchiveTestEntry("BeyondAssets/../../outside", body: "wrong"))
        case "absolute": entries.append(ArchiveTestEntry("/BeyondAssets/wrong", body: "wrong"))
        case "symlink": entries.append(ArchiveTestEntry("BeyondAssets/link", type: .symlink, link: "editor.exe"))
        case "collision": entries.append(ArchiveTestEntry("BeyondAssets/EDITOR.EXE", body: "wrong"))
        case "implicitCollision": entries += [ArchiveTestEntry("BeyondAssets/Dir/a"), ArchiveTestEntry("BeyondAssets/dir/b")]
        case "unicodeCollision": entries += [ArchiveTestEntry("BeyondAssets/é/a"), ArchiveTestEntry("BeyondAssets/e\u{301}/b")]
        case "fileParent": entries.append(ArchiveTestEntry("BeyondAssets/editor.exe/child"))
        case "missingList": entries.removeLast()
        case "missingAssets": entries.removeFirst()
        default: entries.append(ArchiveTestEntry("./", type: .directory))
        }
        try fs.writeAtomically(archiveTestData(entries, format: .zip), to: SafeRelativePath("package.zip"))
        await #expect(throws: (any Error).self) {
            try await SandboxArchiveExtractor().expandedSize(archive: SafeRelativePath("package.zip"), in: fs, listPath: list)
        }
        await #expect(throws: (any Error).self) {
            try await SandboxArchiveExtractor().extract(archive: SafeRelativePath("package.zip"), in: fs, to: SafeRelativePath("stage"), listPath: list)
        }
        #expect(try fs.itemType(at: SafeRelativePath("stage")) == nil)
    }

    @Test func configuredListIsOneRootFileAndCanUseAnotherName() async throws {
        let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url)
        try fs.writeAtomically(archiveTestData([ArchiveTestEntry("BeyondAssets/editor"), ArchiveTestEntry("other_list")], format: .zip), to: SafeRelativePath("package.zip"))
        #expect(try await SandboxArchiveExtractor().expandedSize(archive: SafeRelativePath("package.zip"), in: fs, listPath: SafeRelativePath("other_list")) == 0)
        for invalid in ["nested/other_list", "BeyondAssets"] {
            await #expect(throws: (any Error).self) {
                try await SandboxArchiveExtractor().expandedSize(archive: SafeRelativePath("package.zip"), in: fs, listPath: SafeRelativePath(invalid))
            }
        }
    }

    @Test func rejectsHardlinksAndNonZIPArchives() async throws {
        let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url)
        let entries = [ArchiveTestEntry("BeyondAssets/editor", body: "editor"), ArchiveTestEntry("BeyondAssets/link", type: .hardlink, link: "BeyondAssets/editor"), ArchiveTestEntry("beyond_pkg_version")]
        try fs.writeAtomically(archiveTestData(entries, format: .tarGZ), to: SafeRelativePath("package.zip"))
        await #expect(throws: (any Error).self) {
            try await SandboxArchiveExtractor().extract(archive: SafeRelativePath("package.zip"), in: fs, to: SafeRelativePath("stage"), listPath: list)
        }
        #expect(throws: (any Error).self) {
            try SandboxArchiveExtractor.validate([ArchiveEntry(path: "BeyondAssets/editor", kind: .file),
                ArchiveEntry(path: "BeyondAssets/link", kind: .hardlink("BeyondAssets/editor")),
                ArchiveEntry(path: "beyond_pkg_version", kind: .file)], listPath: list)
        }
    }

    @Test func boundsEntriesAndExpandedBytes() async throws {
        let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url)
        let archive = try SafeRelativePath("package.zip")
        try fs.writeAtomically(archiveTestData([ArchiveTestEntry("BeyondAssets/editor", body: "12345"), ArchiveTestEntry("beyond_pkg_version")], format: .zip), to: archive)
        await #expect(throws: LauncherError.fileTooLarge(path: "archive", limit: 4)) {
            try await SandboxArchiveExtractor(maxExpandedBytes: 4).expandedSize(archive: archive, in: fs, listPath: list)
        }
        let entries = (0..<20_000).map { ArchiveTestEntry("BeyondAssets/\($0)") } + [ArchiveTestEntry("beyond_pkg_version")]
        try fs.writeAtomically(archiveTestData(entries, format: .zip), to: archive)
        await #expect(throws: LauncherError.io("Archive entry limit exceeded")) {
            try await SandboxArchiveExtractor().expandedSize(archive: archive, in: fs, listPath: list)
        }
        await #expect(throws: (any Error).self) {
            try await SandboxArchiveExtractor(maxExpandedBytes: (4 << 30) + 1).expandedSize(archive: archive, in: fs, listPath: list)
        }
    }

    @Test func preservesNonemptyTargetAndCancelsExtraction() async throws {
        let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url)
        try fs.writeAtomically(archiveTestData([ArchiveTestEntry("BeyondAssets/editor", body: String(repeating: "x", count: 200_000)), ArchiveTestEntry("beyond_pkg_version")], format: .zip), to: SafeRelativePath("package.zip"))
        try fs.writeAtomically(Data("kept".utf8), to: SafeRelativePath("existing/file"))
        await #expect(throws: LauncherError.io("Extraction target must be empty")) {
            try await SandboxArchiveExtractor().extract(archive: SafeRelativePath("package.zip"), in: fs, to: SafeRelativePath("existing"), listPath: list)
        }
        #expect(try fs.readFile(at: SafeRelativePath("existing/file"), maxBytes: 4) == Data("kept".utf8))
        let task = Task<Void, Never> {
            await #expect(throws: LauncherError.cancelled) {
                try await SandboxArchiveExtractor().extract(archive: SafeRelativePath("package.zip"), in: fs, to: SafeRelativePath("cancelled"), listPath: list) { done, _ in
                    if done > 0 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
        }
        await task.value
        #expect(try fs.itemType(at: SafeRelativePath("cancelled")) == nil)
    }
}

private final class SandboxArchiveProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(Int64, Int64)] = []
    func append(_ done: Int64, _ total: Int64) { lock.lock(); defer { lock.unlock() }; samples.append((done, total)) }
    var values: [(Int64, Int64)] { lock.lock(); defer { lock.unlock() }; return samples }
}
