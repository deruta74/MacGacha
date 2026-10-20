// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Testing
import LauncherCore
import RuntimeManager
import TestSupport

@Test(arguments: [ArchiveFormat.tarGZ, .zip])
func extractsArchiveWithSpacesAndInternalLinks(format: ArchiveFormat) async throws {
    let temp = try TempDir()
    let archive = temp.url.appendingPathComponent("fixture")
    let entries = [ArchiveTestEntry("bin/", type: .directory), ArchiveTestEntry("bin/wine", body: "wine"),
        ArchiveTestEntry("a space/日本語", body: "unicode"), ArchiveTestEntry("bin/link", type: .symlink, link: "wine"),
        ArchiveTestEntry("dir-link", type: .symlink, link: "bin/"), ArchiveTestEntry("lib/link", type: .symlink, link: "../bin/wine")]
    try archiveTestData(entries, format: format).write(to: archive)
    let target = temp.url.appendingPathComponent("target")
    try await ArchiveExtractor(runner: SystemProcessRunner()).extract(archive, format: format, into: target)
    #expect(try String(contentsOf: target.appendingPathComponent("bin/wine"), encoding: .utf8) == "wine")
    #expect(try String(contentsOf: target.appendingPathComponent("a space/日本語"), encoding: .utf8) == "unicode")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.appendingPathComponent("bin/link").path) == "wine")
}

@Test(arguments: [ArchiveFormat.tarGZ, .zip], ["absolute", "parent", "symlink", "chain", "linkParent", "duplicate", "caseDuplicate", "device"])
func rejectsMaliciousArchiveBeforeExtraction(format: ArchiveFormat, attack: String) async throws {
    let temp = try TempDir(); let outside = try TempDir()
    let control = outside.url.appendingPathComponent("control")
    try Data("untouched".utf8).write(to: control)
    let entries: [ArchiveTestEntry]
    switch attack {
    case "absolute": entries = [ArchiveTestEntry(control.path, body: "evil")]
    case "parent": entries = [ArchiveTestEntry("../control", body: "evil")]
    case "symlink": entries = [ArchiveTestEntry("link", type: .symlink, link: outside.url.path)]
    case "chain": entries = [ArchiveTestEntry("a", type: .symlink, link: "b"), ArchiveTestEntry("b", type: .symlink, link: "../control")]
    case "linkParent": entries = [ArchiveTestEntry("a", type: .symlink, link: "safe"), ArchiveTestEntry("a/file", body: "evil")]
    case "duplicate": entries = [ArchiveTestEntry("same", body: "a"), ArchiveTestEntry("same", body: "b")]
    case "caseDuplicate": entries = [ArchiveTestEntry("Same", body: "a"), ArchiveTestEntry("same", body: "b")]
    default: entries = [ArchiveTestEntry("device", type: .device)]
    }
    let archive = temp.url.appendingPathComponent("hostile")
    try archiveTestData(entries, format: format).write(to: archive)
    let runner = FakeProcessRunner()
    do {
        try await ArchiveExtractor(runner: runner).extract(archive, format: format, into: temp.url.appendingPathComponent("target"))
        Issue.record("Unsafe archive accepted")
    } catch LauncherError.unsafePath { } // The rejection must be a path policy decision, not a tool failure.
    #expect(runner.invocations.isEmpty)
    #expect(try Data(contentsOf: control) == Data("untouched".utf8))
}

@Test
func rejectsEscapingTarHardlinkAndAcceptsContainedHardlink() async throws {
    let temp = try TempDir(); let archive = temp.url.appendingPathComponent("fixture")
    try archiveTestData([ArchiveTestEntry("hard", type: .hardlink, link: "../outside")], format: .tarGZ).write(to: archive)
    do {
        try await ArchiveExtractor(runner: FakeProcessRunner()).extract(archive, format: .tarGZ, into: temp.url.appendingPathComponent("bad"))
        Issue.record("Escaping hardlink accepted")
    } catch LauncherError.unsafePath { }
    try archiveTestData([ArchiveTestEntry("file", body: "ok"), ArchiveTestEntry("hard", type: .hardlink, link: "file")], format: .tarGZ).write(to: archive)
    let target = temp.url.appendingPathComponent("good")
    try await ArchiveExtractor(runner: SystemProcessRunner()).extract(archive, format: .tarGZ, into: target)
    #expect(try Data(contentsOf: target.appendingPathComponent("hard")) == Data("ok".utf8))
}

@Test
func archiveExtractionRechecksTreeAndDeletesUnsafeStaging() async throws {
    let temp = try TempDir(); let outside = try TempDir()
    let archive = temp.url.appendingPathComponent("fixture")
    try archiveTestData([ArchiveTestEntry("file", body: "ok")], format: .tarGZ).write(to: archive)
    let target = temp.url.appendingPathComponent("target")
    let outsideURL = outside.url
    let runner = FakeProcessRunner { invocation in
        if invocation.arguments.first == "-xf" {
            try FileManager.default.createSymbolicLink(at: target.appendingPathComponent("escape"), withDestinationURL: outsideURL)
        }
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
    do {
        try await ArchiveExtractor(runner: runner).extract(archive, format: .tarGZ, into: target)
        Issue.record("Unsafe extracted tree accepted")
    } catch LauncherError.unsafePath { }
    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(FileManager.default.fileExists(atPath: outside.url.path))
}

@Test
func archiveExtractionPropagatesProcessFailureAndCancellation() async throws {
    let temp = try TempDir(); let archive = temp.url.appendingPathComponent("fixture")
    try archiveTestData([ArchiveTestEntry("file", body: "ok")], format: .tarGZ).write(to: archive)
    let runner = FakeProcessRunner { invocation in
        ProcessResult(exitCode: invocation.arguments.first == "-xf" ? 7 : 0, stdout: Data(), stderr: Data("failed".utf8))
    }
    await #expect(throws: LauncherError.processFailed(executable: "/usr/bin/tar", exitCode: 7, stderrTail: "failed")) {
        try await ArchiveExtractor(runner: runner).extract(archive, format: .tarGZ, into: temp.url.appendingPathComponent("target"))
    }
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        await #expect(throws: LauncherError.cancelled) {
            try await ArchiveExtractor(runner: runner).extract(archive, format: .tarGZ, into: temp.url.appendingPathComponent("cancelled"))
        }
    }
    await cancelled.value
}

@Test
func archiveExtractionBoundsExpandedSizeAndPreservesNonemptyTarget() async throws {
    let temp = try TempDir(); let archive = temp.url.appendingPathComponent("fixture")
    try archiveTestData([ArchiveTestEntry("file", body: "12345")], format: .zip).write(to: archive)
    await #expect(throws: LauncherError.fileTooLarge(path: "archive", limit: 4)) {
        try await ArchiveExtractor(runner: FakeProcessRunner(), maxExpandedBytes: 4).extract(archive, format: .zip, into: temp.url.appendingPathComponent("bounded"))
    }
    let fs = try ContainedFileSystem(root: temp.url)
    try fs.writeAtomically(Data("kept".utf8), to: SafeRelativePath("existing/file"))
    await #expect(throws: LauncherError.io("Extraction target must be empty")) {
        try await ArchiveExtractor(runner: FakeProcessRunner()).extract(archive, format: .zip, into: temp.url.appendingPathComponent("existing"))
    }
    #expect(try fs.readFile(at: SafeRelativePath("existing/file"), maxBytes: 4) == Data("kept".utf8))
}

struct ArchiveTestEntry {
    enum Kind { case file, directory, symlink, hardlink, device, pax }
    let name: String
    var body: String = ""
    var type: Kind = .file
    var link: String = ""
    init(_ name: String, body: String = "", type: Kind = .file, link: String = "") {
        self.name = name; self.body = body; self.type = type; self.link = link
    }
}

/// Deliberately writes raw headers, allowing fixtures that normal archive tools refuse to create.
func archiveTestData(_ entries: [ArchiveTestEntry], format: ArchiveFormat, paxNames: Bool = true) -> Data {
    if format == .zip { return zipTestData(entries) }
    var result = Data()
    for entry in entries {
        let usePax = paxNames && entry.name.utf8.contains { $0 >= 128 }
        if usePax {
            let body = " path=\(entry.name)\n"
            var length = body.utf8.count + 1
            while String(length).utf8.count + body.utf8.count != length { length = String(length).utf8.count + body.utf8.count }
            let header = ArchiveTestEntry("PaxHeader", body: "\(length)" + body, type: .pax)
            result.append(archiveTestData([header], format: format, paxNames: false).dropLast(1024))
        }
        var h = [UInt8](repeating: 0, count: 512)
        func put(_ value: String, _ offset: Int, _ length: Int) {
            for (i, byte) in value.utf8.prefix(length).enumerated() { h[offset + i] = byte }
        }
        let body = (entry.type == .file || entry.type == .pax) ? Data(entry.body.utf8) : Data()
        put(usePax ? "PaxPayload" : entry.name, 0, 100); put("0000755", 100, 7); put("0000000", 108, 7); put("0000000", 116, 7)
        put(String(format: "%011o", body.count), 124, 11); put("00000000000", 136, 11)
        for i in 148..<156 { h[i] = 32 }
        h[156] = entry.type == .pax ? 120 : entry.type == .directory ? 53 : entry.type == .symlink ? 50 : entry.type == .hardlink ? 49 : entry.type == .device ? 51 : 48
        put(entry.link, 157, 100); put("ustar", 257, 5); put("00", 263, 2)
        put(String(format: "%06o", h.reduce(0) { $0 + Int($1) }), 148, 6)
        result.append(contentsOf: h); result.append(body)
        result.append(Data(repeating: 0, count: (512 - body.count % 512) % 512))
    }
    result.append(Data(repeating: 0, count: 1024))
    return result
}

private func zipTestData(_ entries: [ArchiveTestEntry], unicodeOverride: String? = nil, flags: UInt16 = 0x800, fat: Bool = false) -> Data {
    var result = Data(); var central = Data()
    for entry in entries {
        let name = Data(entry.name.utf8)
        let body = Data((entry.type == .symlink ? entry.link : entry.body).utf8)
        var crc: UInt32 = 0xffff_ffff
        for byte in body { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0) } }
        crc ^= 0xffff_ffff
        var extra = Data()
        if let unicodeOverride {
            let utf8 = Data(unicodeOverride.utf8)
            extra.le16(0x7075); extra.le16(UInt16(utf8.count + 5)); extra.append(1); extra.le32(0); extra.append(utf8)
        }
        let offset = UInt32(result.count)
        result.le32(0x04034b50); result.le16(20); result.le16(flags); result.le16(0); result.le16(0); result.le16(0)
        result.le32(crc); result.le32(UInt32(body.count)); result.le32(UInt32(body.count)); result.le16(UInt16(name.count)); result.le16(UInt16(extra.count))
        result.append(name); result.append(extra); result.append(body)
        central.le32(0x02014b50); central.le16(fat ? 0x0014 : 0x0314); central.le16(20); central.le16(flags); central.le16(0); central.le16(0); central.le16(0)
        central.le32(crc); central.le32(UInt32(body.count)); central.le32(UInt32(body.count)); central.le16(UInt16(name.count)); central.le16(UInt16(extra.count)); central.le16(0)
        central.le16(0); central.le16(0)
        let mode: UInt32 = (entry.type == .directory ? 0o040000 : entry.type == .symlink ? 0o120000 : entry.type == .device ? 0o020000 : 0o100000) | 0o755
        central.le32(fat ? 0 : mode << 16); central.le32(offset); central.append(name); central.append(extra)
    }
    let start = UInt32(result.count); result.append(central)
    result.le32(0x06054b50); result.le16(0); result.le16(0); result.le16(UInt16(entries.count)); result.le16(UInt16(entries.count))
    result.le32(UInt32(central.count)); result.le32(start); result.le16(0)
    return result
}

private extension Data {
    mutating func le16(_ n: UInt16) { append(UInt8(n & 255)); append(UInt8(n >> 8)) }
    mutating func le32(_ n: UInt32) { le16(UInt16(n & 65535)); le16(UInt16(n >> 16)) }
}

@Test
func cancellingExtractionCancelsItsProcessAndRemovesStaging() async throws {
    let temp = try TempDir(); let archive = temp.url.appendingPathComponent("fixture")
    try archiveTestData([ArchiveTestEntry("file", body: "ok")], format: .tarGZ).write(to: archive)
    let real = SystemProcessRunner(terminationGracePeriod: .milliseconds(50), pipeDrainGracePeriod: .milliseconds(50))
    let pidFile = temp.url.appendingPathComponent("pid")
    let runner = FakeProcessRunner { invocation in
        if invocation.arguments.first == "-xf" {
            return try await real.run(URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo $$ > \"$1\"; exec /bin/sleep 30", "sh", pidFile.path], environment: [:], currentDirectory: nil)
        }
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
    let target = temp.url.appendingPathComponent("target")
    let task = Task { try await ArchiveExtractor(runner: runner).extract(archive, format: .tarGZ, into: target) }
    defer { task.cancel() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    var launchedPID: Int32?
    while launchedPID == nil && ContinuousClock.now < deadline {
        if let text = try? String(contentsOf: pidFile, encoding: .utf8) { launchedPID = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if launchedPID == nil { try await Task.sleep(for: .milliseconds(10)) }
    }
    let pid = try #require(launchedPID)
    let start = ContinuousClock.now
    task.cancel()
    await #expect(throws: LauncherError.cancelled) { try await task.value }
    #expect(start.duration(to: .now) < .seconds(3))
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
    // Cancellation may leave hidden staging for the store sweep; it must not contain data.
    if FileManager.default.fileExists(atPath: target.path) {
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }
}

@Test(arguments: [ArchiveFormat.tarGZ, .zip])
func archiveLimitsAndParentTargetsFailBeforeProcesses(format: ArchiveFormat) async throws {
    let temp = try TempDir(); let outside = try TempDir()
    let archive = temp.url.appendingPathComponent("fixture")
    try archiveTestData([ArchiveTestEntry("one", body: "1"), ArchiveTestEntry("two", body: "2")], format: format).write(to: archive)
    let runner = FakeProcessRunner()
    await #expect(throws: LauncherError.io("Archive entry limit exceeded")) {
        try await ArchiveExtractor(runner: runner, maxEntries: 1).extract(archive, format: format, into: temp.url.appendingPathComponent("target"))
    }
    #expect(runner.invocations.isEmpty)
    try FileManager.default.createSymbolicLink(at: temp.url.appendingPathComponent("redirect"), withDestinationURL: outside.url)
    do {
        try await ArchiveExtractor(runner: runner).extract(archive, format: format, into: temp.url.appendingPathComponent("redirect"))
        Issue.record("Symlink target accepted")
    } catch LauncherError.unsafePath { }
    #expect(runner.invocations.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.url.path).isEmpty)
}

@Test(arguments: [true, false])
func zipRejectsConflictingLocalAndCentralNames(localUnsafe: Bool) async throws {
    let temp = try TempDir(); let archive = temp.url.appendingPathComponent("fixture.zip")
    var data = zipTestData([ArchiveTestEntry("safe", body: "ok")])
    // Both names have four bytes. Disagreement must not let two parsers see different paths.
    let offset = localUnsafe ? 30 : 30 + 4 + 2 + 46
    data.replaceSubrange(offset..<(offset + 4), with: Data("../x".utf8))
    try data.write(to: archive)
    let runner = FakeProcessRunner()
    do {
        try await ArchiveExtractor(runner: runner).extract(archive, format: .zip, into: temp.url.appendingPathComponent("target"))
        Issue.record("Conflicting ZIP names accepted")
    } catch LauncherError.unsafePath { }
    catch LauncherError.io { } // A malformed archive is also an acceptable pre-extraction rejection.
    #expect(runner.invocations.isEmpty)
}

@Test(arguments: [ArchiveFormat.tarXZ, .zip])
func extractsSystemCompressedArchive(format: ArchiveFormat) async throws {
    let temp = try TempDir(); let source = temp.url.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let content = Data(repeating: 97, count: 8192)
    try content.write(to: source.appendingPathComponent("file"))
    if format == .tarXZ { try content.write(to: source.appendingPathComponent("日本語")) }
    let archive = temp.url.appendingPathComponent(format == .zip ? "fixture.zip" : "fixture.tar.xz")
    let runner = SystemProcessRunner()
    let result = try await runner.run(URL(fileURLWithPath: format == .zip ? "/usr/bin/ditto" : "/usr/bin/tar"),
        arguments: format == .zip ? ["-c", "-k", "--norsrc", source.path, archive.path] : ["-cJf", archive.path, "--format", "pax", "-C", source.path, "."],
        environment: [:], currentDirectory: nil)
    try #require(result.exitCode == 0)
    let target = temp.url.appendingPathComponent("target")
    try await ArchiveExtractor(runner: runner).extract(archive, format: format, into: target)
    #expect(try Data(contentsOf: target.appendingPathComponent("file")) == content)
    if format == .tarXZ { #expect(try Data(contentsOf: target.appendingPathComponent("日本語")) == content) }
}

@Test
func zipRejectsConflictingUnicodePathOverride() async throws {
    let temp = try TempDir(); let archive = temp.url.appendingPathComponent("fixture.zip")
    try zipTestData([ArchiveTestEntry("safe", body: "ok")], unicodeOverride: "../x").write(to: archive)
    let runner = FakeProcessRunner()
    await #expect(throws: LauncherError.unsafePath("Conflicting Unicode ZIP path")) {
        try await ArchiveExtractor(runner: runner).extract(archive, format: .zip, into: temp.url.appendingPathComponent("target"))
    }
    #expect(runner.invocations.isEmpty)
}

@Test
func extractsZIP64Directory() async throws {
    let temp = try TempDir(); let archive = temp.url.appendingPathComponent("fixture.zip")
    var data = zipTestData([ArchiveTestEntry("file", body: "ok")])
    let centralOffset = try #require(data.range(of: Data([0x50, 0x4b, 0x01, 0x02]))).lowerBound
    data.removeLast(22)
    let zip64Offset = data.count
    let centralSize = zip64Offset - centralOffset
    func append64(_ n: UInt64, to data: inout Data) { data.le32(UInt32(n & 0xffff_ffff)); data.le32(UInt32(n >> 32)) }
    data.le32(0x06064b50); append64(44, to: &data); data.le16(45); data.le16(45); data.le32(0); data.le32(0)
    append64(1, to: &data); append64(1, to: &data); append64(UInt64(centralSize), to: &data); append64(UInt64(centralOffset), to: &data)
    data.le32(0x07064b50); data.le32(0); append64(UInt64(zip64Offset), to: &data); data.le32(1)
    data.le32(0x06054b50); data.le16(0); data.le16(0); data.le16(0xffff); data.le16(0xffff)
    data.le32(0xffff_ffff); data.le32(0xffff_ffff); data.le16(0)
    try data.write(to: archive)
    let target = temp.url.appendingPathComponent("target")
    try await ArchiveExtractor(runner: SystemProcessRunner()).extract(archive, format: .zip, into: target)
    #expect(try Data(contentsOf: target.appendingPathComponent("file")) == Data("ok".utf8))
}


@Test(arguments: ["self", "ancestor", "exponential", "repeated", "budget"])
func rejectsSymlinkResolutionAbuse(attack: String) async throws {
    let temp = try TempDir(); let archive = temp.url.appendingPathComponent("fixture")
    let entries: [ArchiveTestEntry]
    switch attack {
    case "self": entries = [ArchiveTestEntry("a", type: .symlink, link: ".")]
    case "ancestor": entries = [ArchiveTestEntry("sub/", type: .directory), ArchiveTestEntry("sub/a", type: .symlink, link: "..")]
    case "exponential":
        entries = (0..<14).map { ArchiveTestEntry("s\($0)", type: .symlink, link: "s\($0 + 1)/s\($0 + 1)") } + [ArchiveTestEntry("s14", type: .symlink, link: ".")]
    case "repeated":
        entries = [ArchiveTestEntry("dir/", type: .directory)]
            + (0..<14).map { ArchiveTestEntry("s\($0)", type: .symlink, link: "s\($0 + 1)/../s\($0 + 1)") }
            + [ArchiveTestEntry("s14", type: .symlink, link: "dir")]
    default:
        entries = [ArchiveTestEntry("dir/", type: .directory), ArchiveTestEntry("dir/file", body: "ok")]
            + (0..<2200).map { ArchiveTestEntry("link\($0)", type: .symlink, link: "dir/file") }
    }
    try archiveTestData(entries, format: .tarGZ).write(to: archive)
    let runner = FakeProcessRunner(); let start = ContinuousClock.now
    do {
        try await ArchiveExtractor(runner: runner).extract(archive, format: .tarGZ, into: temp.url.appendingPathComponent("target"))
        Issue.record("Unsafe link resolution accepted")
    } catch LauncherError.unsafePath { }
    #expect(start.duration(to: .now) < .seconds(3))
    #expect(runner.invocations.isEmpty)
}

@Test(arguments: ["forward", "symlink", "parent", "case"])
func rejectsNonliteralOrForwardHardlinks(attack: String) async throws {
    let temp = try TempDir(); let archive = temp.url.appendingPathComponent("fixture")
    let file = ArchiveTestEntry("file", body: "ok")
    let entries: [ArchiveTestEntry]
    switch attack {
    case "forward": entries = [ArchiveTestEntry("hard", type: .hardlink, link: "file"), file]
    case "symlink": entries = [file, ArchiveTestEntry("link", type: .symlink, link: "file"), ArchiveTestEntry("hard", type: .hardlink, link: "link")]
    case "parent": entries = [ArchiveTestEntry("dir/", type: .directory), ArchiveTestEntry("dir/file", body: "ok"),
        ArchiveTestEntry("alias", type: .symlink, link: "dir"), ArchiveTestEntry("hard", type: .hardlink, link: "alias/file")]
    default: entries = [file, ArchiveTestEntry("hard", type: .hardlink, link: "File")]
    }
    try archiveTestData(entries, format: .tarGZ).write(to: archive)
    let runner = FakeProcessRunner()
    do {
        try await ArchiveExtractor(runner: runner).extract(archive, format: .tarGZ, into: temp.url.appendingPathComponent("target"))
        Issue.record("Nonliteral or forward hardlink accepted")
    } catch LauncherError.unsafePath { }
    #expect(runner.invocations.isEmpty)
}

@Test
func extractsHardlinksWithImplicitParentDirectories() async throws {
    let temp = try TempDir(); let archive = temp.url.appendingPathComponent("fixture")
    try archiveTestData([ArchiveTestEntry("bin/wine", body: "wine"),
        ArchiveTestEntry("bin/wine-preloader", type: .hardlink, link: "bin/wine")], format: .tarGZ).write(to: archive)
    let target = temp.url.appendingPathComponent("target")
    try await ArchiveExtractor(runner: SystemProcessRunner()).extract(archive, format: .tarGZ, into: target)
    #expect(try Data(contentsOf: target.appendingPathComponent("bin/wine")) == Data("wine".utf8))
    #expect(try Data(contentsOf: target.appendingPathComponent("bin/wine-preloader")) == Data("wine".utf8))
    let original = try FileManager.default.attributesOfItem(atPath: target.appendingPathComponent("bin/wine").path)
    let linked = try FileManager.default.attributesOfItem(atPath: target.appendingPathComponent("bin/wine-preloader").path)
    #expect(original[.systemFileNumber] as? NSNumber == linked[.systemFileNumber] as? NSNumber)
}

@Test(arguments: ["bin", "BIN"])
func rejectsHardlinkTargetWithSymlinkAncestor(ancestor: String) async throws {
    let temp = try TempDir(); let archive = temp.url.appendingPathComponent("fixture")
    try archiveTestData([ArchiveTestEntry("payload/", type: .directory),
        ArchiveTestEntry(ancestor, type: .symlink, link: "payload"),
        ArchiveTestEntry("bin/wine", body: "wine"),
        ArchiveTestEntry("hard", type: .hardlink, link: "bin/wine")], format: .tarGZ).write(to: archive)
    let runner = FakeProcessRunner()
    do {
        try await ArchiveExtractor(runner: runner).extract(archive, format: .tarGZ, into: temp.url.appendingPathComponent("target"))
        Issue.record("Hardlink target with a symlink ancestor accepted")
    } catch LauncherError.unsafePath { }
    #expect(runner.invocations.isEmpty)
}

@Test
func acceptsPAXWarningWithValidUTF8Metadata() async throws {
    let temp = try TempDir(); let archive = temp.url.appendingPathComponent("fixture")
    // libarchive reports ARCHIVE_WARN for this unsupported sparse format, with a
    // valid UTF-8 pathname. Warning acceptance must not depend on English wording.
    try archiveTestData([ArchiveTestEntry("PaxHeader", body: "28 GNU.sparse.major=invalid\n", type: .pax),
        ArchiveTestEntry("file", body: "ok")], format: .tarGZ).write(to: archive)
    let runner = FakeProcessRunner()
    try await ArchiveExtractor(runner: runner).extract(archive, format: .tarGZ, into: temp.url.appendingPathComponent("target"))
    #expect(runner.invocations.count == 1)
}

@Test(arguments: [ArchiveTestEntry.Kind.symlink, .hardlink])
func rejectsPAXWarningWithInvalidUTF8LinkTarget(kind: ArchiveTestEntry.Kind) async throws {
    let temp = try TempDir(); let archive = temp.url.appendingPathComponent("fixture")
    var bytes = archiveTestData([ArchiveTestEntry("PaxHeader", body: "28 GNU.sparse.major=invalid\n", type: .pax),
        ArchiveTestEntry("link", type: kind, link: "bad")], format: .tarGZ)
    // The entry's path is valid ASCII; only its link target is invalid UTF-8.
    let header = 1024
    bytes[header + 157] = 0xFF
    for i in (header + 148)..<(header + 156) { bytes[i] = 32 }
    let checksum = bytes[header..<(header + 512)].reduce(0) { $0 + Int($1) }
    bytes.replaceSubrange((header + 148)..<(header + 154), with: Data(String(format: "%06o", checksum).utf8))
    try bytes.write(to: archive)
    let runner = FakeProcessRunner()
    do {
        try await ArchiveExtractor(runner: runner).extract(archive, format: .tarGZ, into: temp.url.appendingPathComponent("target"))
        Issue.record("PAX warning with an invalid UTF-8 link target accepted")
    } catch LauncherError.unsafePath { }
    #expect(runner.invocations.isEmpty)
}

@Test
func hardlinksCountOnlyUniquePayloadBytes() async throws {
    let temp = try TempDir(); let archive = temp.url.appendingPathComponent("fixture")
    var bytes = archiveTestData([ArchiveTestEntry("dir/", type: .directory), ArchiveTestEntry("dir/file", body: "1234"),
        ArchiveTestEntry("hard", type: .hardlink, link: "dir/file")], format: .tarGZ)
    // A hardlink header's size is not payload, even when nonzero.
    let header = 1536
    bytes.replaceSubrange((header + 124)..<(header + 135), with: Data("00000000010".utf8))
    for i in (header + 148)..<(header + 156) { bytes[i] = 32 }
    let checksum = bytes[header..<(header + 512)].reduce(0) { $0 + Int($1) }
    bytes.replaceSubrange((header + 148)..<(header + 154), with: Data(String(format: "%06o", checksum).utf8))
    try bytes.write(to: archive)
    let target = temp.url.appendingPathComponent("target")
    try await ArchiveExtractor(runner: SystemProcessRunner(), maxExpandedBytes: 4).extract(archive, format: .tarGZ, into: target)
    #expect(try Data(contentsOf: target.appendingPathComponent("hard")) == Data("1234".utf8))
}

@Test
func extractsFATZipWithZeroUnixMode() async throws {
    let temp = try TempDir(); let archive = temp.url.appendingPathComponent("fixture.zip")
    try zipTestData([ArchiveTestEntry("dir/", type: .directory), ArchiveTestEntry("dir/file", body: "ok")], flags: 0, fat: true).write(to: archive)
    let target = temp.url.appendingPathComponent("target")
    try await ArchiveExtractor(runner: SystemProcessRunner()).extract(archive, format: .zip, into: target)
    #expect(try Data(contentsOf: target.appendingPathComponent("dir/file")) == Data("ok".utf8))
}

@Test(arguments: ["zip-unflagged", "zip-invalid", "tar-ustar", "tar-invalid", "tar-pax-invalid", "tar-ustar-after-pax"])
func rejectsAmbiguousArchiveFilenameEncoding(encoding: String) async throws {
    let temp = try TempDir(); let archive = temp.url.appendingPathComponent("fixture")
    let format: ArchiveFormat = encoding.hasPrefix("zip") ? .zip : .tarGZ
    var bytes: Data
    if encoding == "zip-unflagged" { bytes = zipTestData([ArchiveTestEntry("日本語", body: "ok")], flags: 0) }
    else if encoding == "zip-invalid" {
        bytes = zipTestData([ArchiveTestEntry("a", body: "ok")])
        bytes[30] = 0xff; bytes[30 + 1 + 2 + 46] = 0xff
    } else if encoding == "tar-ustar-after-pax" {
        bytes = archiveTestData([ArchiveTestEntry("PaxHeader", body: "13 path=safe\n", type: .pax),
            ArchiveTestEntry("safe", body: "ok")], format: .tarGZ, paxNames: false)
        bytes.removeLast(1024)
        bytes.append(archiveTestData([ArchiveTestEntry("日本語", body: "ok")], format: .tarGZ, paxNames: false))
    } else if encoding == "tar-pax-invalid" {
        bytes = archiveTestData([ArchiveTestEntry("日本語", body: "ok")], format: .tarGZ)
        let range = try #require(bytes.range(of: Data("日本語".utf8)))
        bytes[range.lowerBound] = 0xff
    } else {
        bytes = archiveTestData([ArchiveTestEntry(encoding == "tar-invalid" ? "a" : "日本語", body: "ok")], format: .tarGZ, paxNames: false)
        if encoding == "tar-invalid" {
            bytes[0] = 0xff
            for i in 148..<156 { bytes[i] = 32 }
            let checksum = bytes.prefix(512).reduce(0) { $0 + Int($1) }
            bytes.replaceSubrange(148..<154, with: Data(String(format: "%06o", checksum).utf8))
        }
    }
    try bytes.write(to: archive)
    let runner = FakeProcessRunner()
    do {
        try await ArchiveExtractor(runner: runner).extract(archive, format: format, into: temp.url.appendingPathComponent("target"))
        Issue.record("Ambiguous filename encoding accepted")
    } catch LauncherError.unsafePath { }
    #expect(runner.invocations.isEmpty)
}

@Test(arguments: [ArchiveFormat.tarGZ, .zip])
func extractionUsesOnlyOneProcessAndMatchingUTF8Locale(format: ArchiveFormat) async throws {
    let temp = try TempDir(); let archive = temp.url.appendingPathComponent("fixture")
    try archiveTestData([ArchiveTestEntry("file", body: "ok")], format: format).write(to: archive)
    let system = SystemProcessRunner()
    let runner = FakeProcessRunner { try await system.run($0.executable, arguments: $0.arguments, environment: $0.environment, currentDirectory: $0.currentDirectory) }
    try await ArchiveExtractor(runner: runner).extract(archive, format: format, into: temp.url.appendingPathComponent("target"))
    #expect(runner.invocations.count == 1)
    #expect(runner.invocations.allSatisfy { $0.environment["LC_ALL"] == "en_US.UTF-8" })
}
