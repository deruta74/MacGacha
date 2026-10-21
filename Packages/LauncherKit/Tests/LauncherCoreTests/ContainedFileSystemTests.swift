// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Darwin
import Testing
import Synchronization
import LauncherCore
import TestSupport

@Test(arguments: ["missing", "parent/missing", "absent/missing"])
func containedRenameReportsMissingSource(source: String) throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    try fs.createDirectory(at: SafeRelativePath("parent"))
    let target = try SafeRelativePath("new/target")
    #expect(throws: LauncherError.io("Rename source is missing")) {
        try fs.rename(from: SafeRelativePath(source), to: target)
    }
    #expect(try fs.itemType(at: SafeRelativePath("new")) == nil)
}

@Test(arguments: ["directory", "symlink", "fifo"])
func containedRenameRejectsNonRegularSource(kind: String) throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let source = try SafeRelativePath("source"); let url = temp.url.appendingPathComponent("source")
    if kind == "directory" { try fs.createDirectory(at: source) }
    else if kind == "symlink" {
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: temp.url.appendingPathComponent("missing"))
    } else { try #require(mkfifo(url.path, 0o600) == 0) }
    #expect(throws: LauncherError.unsafePath(url.path)) { try fs.rename(from: source, to: SafeRelativePath("target")) }
    #expect(try fs.itemType(at: SafeRelativePath("target")) == nil)
}

@Test
func containedDirectoryTraversalClosesDescriptorsOnFailure() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let safe = temp.url.appendingPathComponent("safe")
    try fs.createDirectory(at: SafeRelativePath("safe"))
    try FileManager.default.createSymbolicLink(at: safe.appendingPathComponent("link"), withDestinationURL: temp.url)
    func openDescriptors(at url: URL) throws -> Int {
        var expected = stat(); try #require(stat(url.path, &expected) == 0)
        return (0..<getdtablesize()).filter { fd in
            var actual = stat()
            return fstat(fd, &actual) == 0 && actual.st_dev == expected.st_dev && actual.st_ino == expected.st_ino
        }.count
    }
    let before = try [openDescriptors(at: temp.url), openDescriptors(at: safe)]
    for _ in 0..<16 {
        #expect(throws: LauncherError.unsafePath(safe.appendingPathComponent("link").path)) {
            try fs.createDirectory(at: SafeRelativePath("safe/link/new"))
        }
        #expect(throws: LauncherError.unsafePath(safe.appendingPathComponent("link").path)) {
            try fs.size(at: SafeRelativePath("safe/link/file"))
        }
        #expect(try fs.size(at: SafeRelativePath("safe/absent/file")) == nil)
    }
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        #expect(throws: LauncherError.cancelled) { try fs.createDirectory(at: SafeRelativePath("safe/new")) }
    }
    await cancelled.value
    #expect(try [openDescriptors(at: temp.url), openDescriptors(at: safe)] == before)
}

@Test
func containedRenameReplacesOnlyRegularFileDestinations() throws {
    let temp = try TempDir(); let outside = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let source = try SafeRelativePath("stage/source")
    let target = try SafeRelativePath("Data/target")
    try fs.writeAtomically(Data("new".utf8), to: source)
    try fs.writeAtomically(Data("old".utf8), to: target)
    try fs.rename(from: source, to: target)
    #expect(try fs.size(at: source) == nil)
    #expect(try fs.readFile(at: target, maxBytes: 3) == Data("new".utf8))
    try fs.writeAtomically(Data("kept".utf8), to: source)
    try fs.createDirectory(at: try SafeRelativePath("directory"))
    #expect(throws: LauncherError.unsafePath(temp.url.appendingPathComponent("directory").path)) {
        try fs.rename(from: source, to: SafeRelativePath("directory"))
    }
    let control = outside.url.appendingPathComponent("control")
    try Data("outside".utf8).write(to: control)
    try FileManager.default.createSymbolicLink(at: temp.url.appendingPathComponent("link"), withDestinationURL: outside.url)
    #expect(throws: LauncherError.unsafePath(temp.url.appendingPathComponent("link").path)) {
        try fs.rename(from: source, to: SafeRelativePath("link/control"))
    }
    #expect(try Data(contentsOf: control) == Data("outside".utf8))
}

@Test
func containedAppendTruncateAndStreamingRead() throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let path = try SafeRelativePath("journal/nested/records.jsonl")
    try fs.append(Data("one\n".utf8), to: path)
    try fs.append(Data("two\n".utf8), to: path, durable: true)
    var pieces: [Data] = []
    try fs.readFile(at: path, chunkSize: 3) { pieces.append($0) }
    #expect(pieces.allSatisfy { $0.count <= 3 })
    #expect(pieces.reduce(into: Data(), { $0.append($1) }) == Data("one\ntwo\n".utf8))
    try fs.truncateFile(at: path, toByteCount: 4)
    #expect(try fs.readFile(at: path, maxBytes: 10) == Data("one\n".utf8))
    #expect(throws: LauncherError.io("Invalid truncation length")) { try fs.truncateFile(at: path, toByteCount: 5) }
    #expect(throws: LauncherError.io("Invalid truncation length")) { try fs.truncateFile(at: path, toByteCount: -1) }
    #expect(throws: LauncherError.io("Invalid read chunk size")) { try fs.readFile(at: path, chunkSize: 0) { _ in } }
    #expect(throws: LauncherError.io("Invalid read chunk size")) { try fs.readFile(at: path, chunkSize: Int.max) { _ in } }
}

@Test
func streamingReadStopsAtItsInitialFileSize() throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let path = try SafeRelativePath("file")
    try fs.writeAtomically(Data("abcd".utf8), to: path)
    var read = Data()
    try fs.readFile(at: path, chunkSize: 2) { piece in
        read.append(piece)
        try fs.append(Data("extra".utf8), to: path)
    }
    #expect(read == Data("abcd".utf8))
    #expect(try fs.readFile(at: path, maxBytes: 20) == Data("abcdextraextra".utf8))
}

@Test
func journalFilePrimitivesRefuseAncestorAndLeafSymlinksAndHardlinks() throws {
    let directory = try TempDir()
    let outside = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let control = outside.url.appendingPathComponent("control")
    try Data("preserved".utf8).write(to: control)
    try FileManager.default.createDirectory(at: directory.url.appendingPathComponent("safe"), withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: directory.url.appendingPathComponent("safe/link"), withDestinationURL: outside.url)
    try FileManager.default.createSymbolicLink(at: directory.url.appendingPathComponent("leaf"), withDestinationURL: control)
    try FileManager.default.linkItem(at: control, to: directory.url.appendingPathComponent("hardlink"))
    for (raw, rejected) in [("safe/link/control", "safe/link"), ("leaf", "leaf"), ("hardlink", "hardlink")] {
        let path = try SafeRelativePath(raw)
        let error = LauncherError.unsafePath(directory.url.appendingPathComponent(rejected).path)
        #expect(throws: error) { try fs.append(Data("new".utf8), to: path) }
        #expect(throws: error) { try fs.truncateFile(at: path, toByteCount: 0) }
        if raw != "hardlink" {
            #expect(throws: error) { try fs.readFile(at: path, chunkSize: 1) { _ in } }
        }
        #expect(try Data(contentsOf: control) == Data("preserved".utf8))
    }
}

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
func journalAppendsAndSeekableHandlesPreserveTheirWriteModes() throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let path = try SafeRelativePath("shared/file")
    try fs.append(Data("abcd".utf8), to: path)
    let handle = try fs.openForWriting(at: path, truncate: false)
    defer { try? handle.close() }
    try handle.seek(toOffset: 1)
    try handle.write(contentsOf: Data("X".utf8))
    try handle.close()
    try fs.append(Data("Y".utf8), to: path, durable: true)
    try fs.fullSync(at: path)
    var contents = Data()
    try fs.readFile(at: path, chunkSize: 2) { contents.append($0) }
    #expect(contents == Data("aXcdY".utf8))
    #expect(try fs.size(at: path) == 5)
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

@Test
func containedPublishSwapsNonemptyDirectoriesAndRejectsSymlinkAncestors() throws {
    let temp = try TempDir(); let outside = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let incoming = try SafeRelativePath("kind/.incoming-test"); let version = try SafeRelativePath("kind/1.0")
    try fs.writeAtomically(Data("new".utf8), to: SafeRelativePath("kind/.incoming-test/new"))
    #expect(try fs.publishDirectory(at: incoming, to: version) == false)
    try fs.writeAtomically(Data("next".utf8), to: SafeRelativePath("kind/.incoming-test/next"))
    #expect(try fs.publishDirectory(at: incoming, to: version))
    #expect(try fs.readFile(at: SafeRelativePath("kind/1.0/next"), maxBytes: 4) == Data("next".utf8))
    #expect(try fs.readFile(at: SafeRelativePath("kind/.incoming-test/new"), maxBytes: 3) == Data("new".utf8))
    try FileManager.default.createSymbolicLink(at: temp.url.appendingPathComponent("redirect"), withDestinationURL: outside.url)
    #expect(throws: LauncherError.unsafePath(temp.url.appendingPathComponent("redirect").path)) {
        try fs.publishDirectory(at: incoming, to: SafeRelativePath("redirect/target"))
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.url.path).isEmpty)
}

@Test
func containedPublishSwapFailureLeavesBothTreesIntact() throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url, fileOps: FailedDirectorySwap())
    try fs.writeAtomically(Data("new".utf8), to: SafeRelativePath("incoming/new"))
    try fs.writeAtomically(Data("old".utf8), to: SafeRelativePath("version/old"))
    #expect(throws: LauncherError.io("injected swap failure")) {
        try fs.publishDirectory(at: SafeRelativePath("incoming"), to: SafeRelativePath("version"))
    }
    #expect(try fs.readFile(at: SafeRelativePath("incoming/new"), maxBytes: 3) == Data("new".utf8))
    #expect(try fs.readFile(at: SafeRelativePath("version/old"), maxBytes: 3) == Data("old".utf8))
}

private struct FailedDirectorySwap: FileOps {
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try SystemFileOps().write(descriptor, bytes: bytes) }
    func synchronize(_ descriptor: Int32, durable: Bool) throws { try SystemFileOps().synchronize(descriptor, durable: durable) }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws { try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory) }
    func swap(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32) throws {
        throw LauncherError.io("injected swap failure")
    }
}

@Test func pinnedRootUsesFreshEnumerationOffsets() throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    try fs.writeAtomically(Data("x".utf8), to: SafeRelativePath("child"))
    let pinned = try fs.pinRoot()
    #expect(try pinned.contentsOfRootDirectory() == [SafeRelativePath("child")])
    #expect(try pinned.contentsOfRootDirectory() == [SafeRelativePath("child")])
}

@Test func pinnedOperationsNeverReopenAReplacementRoot() throws {
    let temp = try TempDir(); let root = temp.url.appendingPathComponent("root")
    let fs = try ContainedFileSystem(root: root)
    try fs.writeAtomically(Data("original".utf8), to: SafeRelativePath("managed"))
    let pinned = try fs.pinRoot()
    let originalIdentity = try pinned.rootIdentity()
    try FileManager.default.moveItem(at: root, to: temp.url.appendingPathComponent("moved"))
    try fs.writeAtomically(Data("replacement".utf8), to: SafeRelativePath("managed"))
    try pinned.removeFile(at: SafeRelativePath("managed"))
    #expect(try fs.readFile(at: SafeRelativePath("managed"), maxBytes: 100) == Data("replacement".utf8))
    #expect(try pinned.rootIdentity() == originalIdentity)
    #expect(throws: LauncherError.io("install folder was replaced")) { try pinned.removePinnedRoot(onlyIfEmpty: false) }
}

@Test func persistentIdentityAcceptsRemountButRefusesAnotherVolume() throws {
    let temp = try TempDir(); let provider = RemountIdentityProvider()
    let fs = try ContainedFileSystem(root: temp.url, identityProvider: provider)
    let identity = try fs.rootIdentity()
    provider.remount(device: 2, differentVolume: false)
    let checked = try ContainedFileSystem(root: temp.url, expectedRootIdentity: identity, identityProvider: provider)
    try checked.writeAtomically(Data("same".utf8), to: SafeRelativePath("accepted"))
    provider.remount(device: 3, differentVolume: true)
    #expect(throws: LauncherError.io("install folder was replaced")) {
        try checked.writeAtomically(Data("other".utf8), to: SafeRelativePath("refused"))
    }
    #expect(try fs.itemType(at: SafeRelativePath("refused")) == nil)
    #expect(try fs.readFile(at: SafeRelativePath("accepted"), maxBytes: 10) == Data("same".utf8))
}

private final class RemountIdentityProvider: FileSystemIdentityProvider, Sendable {
    private let state = Mutex((device: Int64(1), differentVolume: false))
    func remount(device: Int64, differentVolume: Bool) { state.withLock { $0 = (device, differentVolume) } }
    func identity(of descriptor: Int32) throws -> FileSystemIdentity {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw LauncherError.io("test identity unavailable") }
        let value = state.withLock { $0 }
        let uuid = UUID(uuidString: value.differentVolume ? "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB" : "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        return FileSystemIdentity(volumeUUID: uuid, device: value.device, inode: UInt64(info.st_ino))
    }
}

@Test func durableRootCreationCannotClaimAReplacement() throws {
    let temp = try TempDir(); let root = temp.url.appendingPathComponent("claimed")
    let fs = try ContainedFileSystem(root: root); try fs.createRootDurably()
    let checked = try ContainedFileSystem(root: root, expectedRootIdentity: fs.rootIdentity())
    try FileManager.default.moveItem(at: root, to: temp.url.appendingPathComponent("moved"))
    try fs.createRootDurably()
    #expect(throws: LauncherError.io("install folder was replaced")) { try checked.createRootDurably() }
    try FileManager.default.removeItem(at: root)
    #expect(throws: LauncherError.io("install folder was replaced")) { try checked.createRootDurably() }
    #expect(!FileManager.default.fileExists(atPath: root.path))
}
