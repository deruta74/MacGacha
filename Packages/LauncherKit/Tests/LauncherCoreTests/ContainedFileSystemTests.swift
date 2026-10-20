// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import TestSupport

@Test
func containedFileHandlesSupportResumeTruncateSyncAndRemoval() throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let path = try SafeRelativePath("parts/nested/object.part")
    #expect(try fs.size(at: path) == nil)
    let first = try fs.openForWriting(at: path, truncate: false)
    try first.write(contentsOf: Data("abc".utf8))
    try first.close()
    let append = try fs.openForWriting(at: path, truncate: false)
    #expect(try append.seekToEnd() == 3)
    try append.write(contentsOf: Data("def".utf8))
    try append.close()
    try fs.fullSync(at: path)
    #expect(try fs.size(at: path) == 6)
    let read = try fs.openForReading(at: path)
    #expect(try read.readToEnd() == Data("abcdef".utf8))
    try read.close()
    let truncated = try fs.openForWriting(at: path, truncate: true)
    try truncated.close()
    #expect(try fs.size(at: path) == 0)
    try fs.removeFile(at: path)
    #expect(try fs.size(at: path) == nil)
    try fs.removeFile(at: path)
    #expect(try fs.itemType(at: try SafeRelativePath("parts/nested")) == .directory)
}

@Test
func containedFilePrimitivesRefuseSymlinksAndNonRegularLeaves() throws {
    let directory = try TempDir()
    let outside = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let control = outside.url.appendingPathComponent("control")
    try Data("preserved".utf8).write(to: control)
    try FileManager.default.createSymbolicLink(at: directory.url.appendingPathComponent("link"), withDestinationURL: outside.url)
    try FileManager.default.createSymbolicLink(at: directory.url.appendingPathComponent("leaf"), withDestinationURL: control)
    try FileManager.default.createDirectory(at: directory.url.appendingPathComponent("folder"), withIntermediateDirectories: false)
    for raw in ["link/control", "leaf", "folder"] {
        let path = try SafeRelativePath(raw)
        let rejected = raw == "link/control" ? "link" : raw
        let error = LauncherError.unsafePath(directory.url.appendingPathComponent(rejected).path)
        #expect(throws: error) { try fs.openForWriting(at: path, truncate: true) }
        #expect(throws: error) { try fs.openForReading(at: path) }
        #expect(throws: error) { try fs.size(at: path) }
        #expect(throws: error) { try fs.fullSync(at: path) }
        #expect(throws: error) { try fs.removeFile(at: path) }
        #expect(try Data(contentsOf: control) == Data("preserved".utf8))
    }
    let hardlink = directory.url.appendingPathComponent("hardlink")
    try FileManager.default.linkItem(at: control, to: hardlink)
    #expect(throws: LauncherError.unsafePath(hardlink.path)) {
        try fs.openForWriting(at: try SafeRelativePath("hardlink"), truncate: true)
    }
    #expect(try Data(contentsOf: control) == Data("preserved".utf8))
}

@Test
func containedFileSystemReadsWritesListsAndRemoves() throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url.appendingPathComponent("root"))
    let folder = try SafeRelativePath("Data/nested")
    let file = try SafeRelativePath("Data/nested/file with spaces-日.bin")
    try fs.createDirectory(at: folder)
    try fs.writeAtomically(Data("old".utf8), to: file)
    try fs.writeAtomically(Data("new".utf8), to: file)
    #expect(try fs.readFile(at: file, maxBytes: 3) == Data("new".utf8))
    #expect(try fs.itemType(at: file) == .regularFile)
    #expect(try fs.itemType(at: folder) == .directory)
    #expect(try fs.contentsOfDirectory(at: folder) == [file])
    #expect(throws: LauncherError.fileTooLarge(path: file.resolved(against: directory.url.appendingPathComponent("root")).path, limit: 2)) { try fs.readFile(at: file, maxBytes: 2) }
    #expect(throws: LauncherError.io("Negative read limit")) { try fs.readFile(at: file, maxBytes: -1) }
    try fs.removeItem(at: try SafeRelativePath("Data"))
    #expect(try fs.itemType(at: file) == nil)
    try fs.removeItem(at: try SafeRelativePath("Data"))
}

@Test
func containedFileSystemRejectsDeepAncestorSymlinks() throws {
    let directory = try TempDir()
    let outside = try TempDir()
    let control = outside.url.appendingPathComponent("nested/deeper/control")
    try FileManager.default.createDirectory(at: control.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("preserved".utf8).write(to: control)
    try FileManager.default.createDirectory(at: directory.url.appendingPathComponent("safe"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: directory.url.appendingPathComponent("safe/link"), withDestinationURL: outside.url)
    let fs = try ContainedFileSystem(root: directory.url)
    let file = try SafeRelativePath("safe/link/nested/deeper/control")
    let folder = try SafeRelativePath("safe/link/nested/deeper")
    let operations: [() throws -> Void] = [
        { try fs.removeItem(at: file) }, { try fs.writeAtomically(Data("changed".utf8), to: file) },
        { _ = try fs.contentsOfDirectory(at: folder) }, { _ = try fs.readFile(at: file, maxBytes: 100) },
        { _ = try fs.itemType(at: file) }, { try fs.createDirectory(at: try SafeRelativePath("safe/link/new/directory")) },
    ]
    for operation in operations {
        do { try operation(); Issue.record("A symlink below the trusted root must be refused") }
        catch LauncherError.unsafePath {}
        #expect(try Data(contentsOf: control) == Data("preserved".utf8))
    }
    #expect(!FileManager.default.fileExists(atPath: outside.url.appendingPathComponent("new").path))
}

@Test
func containedFileSystemUnlinksSymlinksInsideRemovedTree() throws {
    let directory = try TempDir()
    let outside = try TempDir()
    let control = outside.url.appendingPathComponent("control")
    try Data("preserved".utf8).write(to: control)
    let fs = try ContainedFileSystem(root: directory.url)
    try fs.createDirectory(at: try SafeRelativePath("tree/nested"))
    try FileManager.default.createSymbolicLink(at: directory.url.appendingPathComponent("tree/nested/link"), withDestinationURL: outside.url)
    try fs.removeItem(at: try SafeRelativePath("tree"))
    #expect(try fs.itemType(at: try SafeRelativePath("tree")) == nil)
    #expect(try Data(contentsOf: control) == Data("preserved".utf8))
}

@Test
func containedFileSystemRejectsNonDirectoryAncestorsAndTrustsAboveRoot() throws {
    let directory = try TempDir()
    let real = directory.url.appendingPathComponent("real", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let alias = directory.url.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
    let fs = try ContainedFileSystem(root: alias.appendingPathComponent("root"))
    try fs.writeAtomically(Data("file".utf8), to: try SafeRelativePath("plain"))
    do {
        try fs.writeAtomically(Data(), to: try SafeRelativePath("plain/child"))
        Issue.record("A regular file cannot be an ancestor")
    } catch LauncherError.unsafePath {}
    #expect(try fs.readFile(at: try SafeRelativePath("plain"), maxBytes: 4) == Data("file".utf8))
}

@Test
func containedFileSystemRefusesLeafSymlinksAndPreservesAtomicWritesOnCancellation() async throws {
    let directory = try TempDir()
    let outside = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let control = outside.url.appendingPathComponent("control")
    let original = Data("preserved".utf8)
    try original.write(to: control)
    try FileManager.default.createSymbolicLink(at: directory.url.appendingPathComponent("link"), withDestinationURL: control)
    let link = try SafeRelativePath("link")
    let operations: [() throws -> Void] = [
        { try fs.removeItem(at: link) }, { try fs.writeAtomically(Data(), to: link) },
        { _ = try fs.readFile(at: link, maxBytes: 100) }, { _ = try fs.itemType(at: link) },
        { try fs.createDirectory(at: link) }, { _ = try fs.contentsOfDirectory(at: link) },
    ]
    for operation in operations {
        do { try operation(); Issue.record("Leaf symlinks must be refused") }
        catch LauncherError.unsafePath {}
    }
    #expect(try Data(contentsOf: control) == original)
    #expect(try fs.itemType(at: link, allowingLeafSymlink: true) == .other)
    do {
        _ = try fs.itemType(at: SafeRelativePath("link/child"), allowingLeafSymlink: true)
        Issue.record("Allowing a leaf symlink must still refuse symlink ancestors")
    } catch LauncherError.unsafePath {}
    let path = try SafeRelativePath("Data/control")
    try fs.writeAtomically(original, to: path)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try fs.writeAtomically(Data("changed".utf8), to: path)
    }
    do { try await task.value; Issue.record("Cancelled writes must throw") }
    catch LauncherError.cancelled {}
    #expect(try fs.readFile(at: path, maxBytes: 100) == original)
    #expect(try fs.contentsOfDirectory(at: SafeRelativePath("Data")) == [path])
}

@Test
func containedFileSystemMovesWithoutReplacingOrFollowingSymlinks() throws {
    let directory = try TempDir()
    let outside = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    try fs.writeAtomically(Data("preserved".utf8), to: SafeRelativePath("source/nested/control"))
    try fs.moveItem(at: SafeRelativePath("source"), to: SafeRelativePath(".removing-test"))
    #expect(try fs.itemType(at: SafeRelativePath("source")) == nil)
    #expect(try fs.readFile(at: SafeRelativePath(".removing-test/nested/control"), maxBytes: 100) == Data("preserved".utf8))
    try fs.writeAtomically(Data("existing".utf8), to: SafeRelativePath("existing"))
    #expect(throws: LauncherError.io("Move destination already exists")) {
        try fs.moveItem(at: SafeRelativePath(".removing-test/nested/control"), to: SafeRelativePath("existing"))
    }
    #expect(try fs.readFile(at: SafeRelativePath("existing"), maxBytes: 100) == Data("existing".utf8))
    #expect(try fs.readFile(at: SafeRelativePath(".removing-test/nested/control"), maxBytes: 100) == Data("preserved".utf8))
    try FileManager.default.createSymbolicLink(at: directory.url.appendingPathComponent("link"), withDestinationURL: outside.url)
    for (from, to) in [("link/nested/file", "moved"), ("existing", "link/nested/file"), ("existing", "link"), ("link", "moved")] {
        do { try fs.moveItem(at: SafeRelativePath(from), to: SafeRelativePath(to)); Issue.record("Moves must refuse symlinks") }
        catch LauncherError.unsafePath {}
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.url.path).isEmpty)
    try fs.createDirectory(at: SafeRelativePath(".removing-link"))
    try fs.moveItem(at: SafeRelativePath("link"), to: SafeRelativePath(".removing-link/entry"), allowingNonRegularSource: true)
    try fs.removeItem(at: SafeRelativePath(".removing-link"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.url.path).isEmpty)
}

@Test
func containedFileSystemReportsInvalidDirectoryEntriesSeparately() throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    try fs.createDirectory(at: SafeRelativePath("versions/valid"))
    let invalid = "versions/bad\\name"
    try FileManager.default.createDirectory(at: directory.url.appendingPathComponent(invalid), withIntermediateDirectories: true)
    let result = try fs.contentsOfDirectoryReportingInvalid(at: SafeRelativePath("versions"))
    #expect(result.paths == [try SafeRelativePath("versions/valid")])
    #expect(result.invalid == [invalid])
    #expect(throws: LauncherError.unsafePath(invalid)) { try fs.contentsOfDirectory(at: SafeRelativePath("versions")) }

}
