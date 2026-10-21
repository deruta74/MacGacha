// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import TestSupport

// Committed vectors, generated with /opt/homebrew/bin/zstd v1.5.7 (no CLI needed by tests):
// python3 - <<'PY'
// from pathlib import Path
// p=Path('/tmp/macgacha-zstd-vectors'); p.mkdir(exist_ok=True)
// x=0x12345678; b=bytearray()
// for _ in range(1<<20):
//     x=(1664525*x+1013904223)&0xffffffff; b.append(x>>24)
// (p/'random-1m.bin').write_bytes(b)
// for name,char,size in [('repeat-8m',b'a',8<<20),('good',b'A',4096),('wrong',b'B',4096)]:
//     (p/(name+'.bin')).write_bytes(char*size)
// PY
// /opt/homebrew/bin/zstd -q -3 --no-check /tmp/macgacha-zstd-vectors/random-1m.bin -o Packages/LauncherKit/Tests/DownloadEngineTests/Resources/zstd/random-1m.zst
// /opt/homebrew/bin/zstd -q -3 --no-check /tmp/macgacha-zstd-vectors/repeat-8m.bin -o Packages/LauncherKit/Tests/DownloadEngineTests/Resources/zstd/repeat-8m.zst
// /opt/homebrew/bin/zstd -q -3 --no-check /tmp/macgacha-zstd-vectors/good.bin -o Packages/LauncherKit/Tests/DownloadEngineTests/Resources/zstd/good.zst
// /opt/homebrew/bin/zstd -q -3 --no-check /tmp/macgacha-zstd-vectors/wrong.bin -o Packages/LauncherKit/Tests/DownloadEngineTests/Resources/zstd/wrong.zst

@Suite struct ZstdDecoderTests {
    @Test func decodesSingleFrameToExactSize() throws {
        let source = zstdRandomPayload()
        let decoded = try decodeVector(try zstdVector("random-1m"), size: source.count)
        #expect(decoded == source)
        #expect(zstdDigest(decoded) == zstdDigest(source))
        #expect(ChunkCodec.supportedCodecs == [.identity, .zstd])
        #expect(try ChunkCodec.zstd.decoder() is ZstdDecoder)
    }

    @Test func flushesBufferedOutputAfterInputEnds() throws {
        let bytes = try zstdVector("repeat-8m")
        #expect(bytes.count < 1024)
        #expect(try decodeVector(bytes, size: 8 << 20) == Data(repeating: 97, count: 8 << 20))
    }

    @Test func decodesConcatenatedFrames() throws {
        let bytes = try zstdVector("good") + zstdVector("wrong")
        #expect(try decodeVector(bytes, size: 8192) == Data(repeating: 65, count: 4096) + Data(repeating: 66, count: 4096))
    }

    @Test func rejectsOutputLargerThanExpected() throws {
        let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
        let inputPath = try SafeRelativePath("input"); let outputPath = try SafeRelativePath("output")
        try fs.writeAtomically(zstdVector("repeat-8m"), to: inputPath)
        let expected = (8 << 20) - 1; let offset = 17
        try fs.writeAtomically(Data(repeating: 0xcc, count: offset + expected + 16), to: outputPath)
        let input = try fs.openForReading(at: inputPath); defer { try? input.close() }
        let output = try fs.openForWriting(at: outputPath, truncate: false); defer { try? output.close() }
        #expect(throws: LauncherError.sizeMismatch(path: "decoded object", expected: Int64(expected), actual: 8 << 20)) {
            try ZstdDecoder().decode(input, expectedSize: Int64(expected), into: output, at: Int64(offset))
        }
        let bytes = try fs.readFile(at: outputPath, maxBytes: 9 << 20)
        #expect(bytes.prefix(offset) == Data(repeating: 0xcc, count: offset))
        #expect(bytes.suffix(16) == Data(repeating: 0xcc, count: 16))
    }

    @Test func rejectsShortOutput() throws {
        #expect(throws: LauncherError.sizeMismatch(path: "decoded object", expected: 8192, actual: 4096)) {
            try decodeVector(zstdVector("good"), size: 8192)
        }
    }

    @Test func rejectsCorruptFrame() throws {
        var bytes = try zstdVector("good"); bytes[0] ^= 1
        #expect(throws: CorruptObjectError.self) { try decodeVector(bytes, size: 4096) }
    }

    @Test func rejectsTrailingGarbage() throws {
        #expect(throws: CorruptObjectError.self) { try decodeVector(zstdVector("good") + Data([1, 2, 3]), size: 4096) }
    }

    @Test func rejectsTruncatedFrame() throws {
        #expect(throws: CorruptObjectError.self) { try decodeVector(Data(zstdVector("good").dropLast()), size: 4096) }
    }

    @Test func rejectsHugeWindow() throws {
        // Valid streaming header: no content size; window descriptor 0x90 declares 2^28.
        // One last raw block containing 'a'. The 2^27 decoder limit must refuse the header.
        let bytes = Data([0x28, 0xb5, 0x2f, 0xfd, 0, 0x90, 9, 0, 0, 97])
        #expect(throws: CorruptObjectError.self) { try decodeVector(bytes, size: 1) }
        #expect(throws: CorruptObjectError.self) { try Zstd.decode(bytes, expectedSize: 1) }
        #expect(throws: CorruptObjectError.self) { try Zstd.decode(zstdVector("good") + bytes, expectedSize: 4097) }
    }

    @Test func honoursCancellation() async throws {
        let bytes = try zstdVector("repeat-8m")
        let writes = Mutex(0)
        let ops = ZstdTestFileOps(onWrite: { descriptor, buffer in
            let count = try SystemFileOps().write(descriptor, bytes: buffer)
            writes.withLock { $0 += 1 }
            withUnsafeCurrentTask { $0?.cancel() }
            return count
        })
        let task = Task.detached { try decodeVector(bytes, size: 8 << 20, fileOps: ops) }
        await #expect(throws: LauncherError.cancelled) { try await task.value }
        #expect(writes.withLock { $0 } == 1)
        let cancelled = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try Zstd.decode(bytes, expectedSize: 8 << 20)
        }
        await #expect(throws: LauncherError.cancelled) { try await cancelled.value }
    }

    @Test func writesAtOffset() throws {
        let prefix = Data("keep prefix".utf8)
        let decoded = try decodeVector(zstdVector("good"), size: 4096, prefix: prefix)
        #expect(decoded == prefix + Data(repeating: 65, count: 4096))
    }

    @Test func inMemoryDecodeBounds() throws {
        let input = try zstdVector("good")
        #expect(try Zstd.decode(input, expectedSize: 4096) == Data(repeating: 65, count: 4096))
        #expect(throws: LauncherError.sizeMismatch(path: "decoded object", expected: 4095, actual: 4096)) {
            try Zstd.decode(input, expectedSize: 4095)
        }
        #expect(throws: LauncherError.sizeMismatch(path: "decoded object", expected: 4097, actual: 4096)) {
            try Zstd.decode(input, expectedSize: 4097)
        }
        #expect(throws: LauncherError.io("Invalid decode range")) { try Zstd.decode(input, expectedSize: -1) }
        #expect(throws: LauncherError.sizeMismatch(path: "decoded object", expected: Int64.max, actual: 4096)) {
            try Zstd.decode(input, expectedSize: Int.max)
        }
        #expect(throws: CorruptObjectError.self) { try Zstd.decode(Data(), expectedSize: 0) }
        #expect(try Zstd.decode(zstdVector("good") + zstdVector("wrong"), expectedSize: 8192).count == 8192)
    }

    @Test func rejectsAliasedOrNonRegularHandlesAndInvalidRanges() throws {
        let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
        let path = try SafeRelativePath("input"); try fs.writeAtomically(zstdVector("good"), to: path)
        let input = try fs.openForReading(at: path); defer { try? input.close() }
        let same = try fs.openForWriting(at: path, truncate: false); defer { try? same.close() }
        #expect(throws: LauncherError.io("Decoder requires distinct regular files")) {
            try ZstdDecoder().decode(input, expectedSize: 4096, into: same, at: 0)
        }
        let null = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null")); defer { try? null.close() }
        #expect(throws: LauncherError.io("Decoder requires distinct regular files")) {
            try ZstdDecoder().decode(input, expectedSize: 4096, into: null, at: 0)
        }
        #expect(throws: LauncherError.io("Invalid decode range")) {
            try ZstdDecoder().decode(input, expectedSize: Int64.max, into: same, at: 1)
        }
    }
}

func zstdVector(_ name: String) throws -> Data {
    try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: "zst", subdirectory: "zstd")))
}
func zstdDigest(_ bytes: Data) -> Digest {
    var hasher = StreamingHasher(.md5); hasher.update(bytes); return hasher.finalize()
}
private func zstdRandomPayload() -> Data {
    var state: UInt32 = 0x12345678
    return Data((0..<(1 << 20)).map { _ in state = state &* 1_664_525 &+ 1_013_904_223; return UInt8(state >> 24) })
}
private func decodeVector(_ bytes: Data, size: Int, prefix: Data = Data(), fileOps: any FileOps = SystemFileOps()) throws -> Data {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let source = try SafeRelativePath("input"); let destination = try SafeRelativePath("output")
    try fs.writeAtomically(bytes, to: source); try fs.writeAtomically(prefix, to: destination)
    let input = try fs.openForReading(at: source); defer { try? input.close() }
    let output = try fs.openForWriting(at: destination, truncate: false); defer { try? output.close() }
    try ZstdDecoder(fileOps: fileOps).decode(input, expectedSize: Int64(size), into: output, at: Int64(prefix.count))
    return try fs.readFile(at: destination, maxBytes: max(0, size) + prefix.count)
}

struct ZstdTestFileOps: FileOps {
    var onWrite: @Sendable (Int32, UnsafeRawBufferPointer) throws -> Int? = { _, _ in nil }
    var afterUnlink: @Sendable (String) -> Void = { _ in }
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        try onWrite(descriptor, bytes) ?? SystemFileOps().write(descriptor, bytes: bytes)
    }
    func synchronize(_ descriptor: Int32, durable: Bool) throws { try SystemFileOps().synchronize(descriptor, durable: durable) }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws {
        try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory); afterUnlink(name)
    }
}
