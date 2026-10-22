// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import LauncherCore

package struct AssemblyBadObject: Error { let id: String; let cause: any Error }

package enum FileAssembler {
    /// One independent output descriptor and digest state per worker. All
    /// blocking decoding, hashing and full sync runs off the scheduling actor.
    @concurrent static func assemble(_ file: FileTask, plan: InstallPlan, fs: ContainedFileSystem, durable: Bool = false,
        fallback: @escaping @Sendable (String) async throws -> Void) async throws {
        let span = OperationWork.begin(.assembly); defer { span?.end() }
        OperationWork.record(.assemblyStarted); defer { OperationWork.record(.assemblyFinished) }
        let layout = StagingLayout(id: plan.id), path = try layout.file(file.path)
        let output = try fs.openForWriting(at: path, truncate: true)
        defer { try? output.close() }
        let sink = DigestingOutput(base: fs.fileOps, descriptor: output.fileDescriptor, algorithm: file.digest.algorithm)
        for extent in file.extents.sorted(by: { $0.fileOffset < $1.fileOffset }) {
            try Task.checkCancellation()
            switch extent.source {
            case .chunk(let id): try decode(id, extent: extent, plan: plan, fs: fs, output: output, sink: sink)
            case .local(let source, let offset):
                if try copyLocal(source, offset: offset, extent: extent, fs: fs, output: output, sink: sink) { continue }
                guard let id = extent.fallbackChunkID else {
                    throw LauncherError.digestMismatch(path: source.description, expected: extent.digest.hex, actual: "local range mismatch")
                }
                try await fallback(id)
                try decode(id, extent: extent, plan: plan, fs: fs, output: output, sink: sink)
            }
        }
        let size = try fs.size(at: path) ?? 0
        guard size == file.size else { throw LauncherError.sizeMismatch(path: file.path.description, expected: file.size, actual: size) }
        let actual = try sink.fileDigest(size: file.size) ?? hash(path, size: file.size, algorithm: file.digest.algorithm, fs: fs)
        guard actual == file.digest else { throw LauncherError.digestMismatch(path: file.path.description, expected: file.digest.hex, actual: actual.hex) }
        // Data reaches the filesystem before fileStaged can be appended. The
        // batch/commit journal F_FULLFSYNC flushes the device cache before any
        // rename. Pre-commit recovery also rehashes staged data before reuse.
        try fs.synchronizeFile(at: path, durable: durable)
    }

    private static func decode(_ id: String, extent: Extent, plan: InstallPlan, fs: ContainedFileSystem,
        output: FileHandle, sink: DigestingOutput) throws {
        guard let object = plan.objects[id] else { throw LauncherError.io("Missing plan object") }
        let input = try fs.openForReading(at: StagingLayout(id: plan.id).object(object))
        defer { try? input.close() }
        do {
            guard object.decodedSize == extent.length else { throw LauncherError.sizeMismatch(path: id, expected: extent.length, actual: object.decodedSize) }
            sink.begin(offset: extent.fileOffset, first: object.decodedDigest.algorithm, second: extent.digest.algorithm)
            try object.codec.decoder(fileOps: sink).decode(input, expectedSize: object.decodedSize, into: output, at: extent.fileOffset)
            let (first, second) = sink.extentDigests()
            guard first == object.decodedDigest else { throw LauncherError.digestMismatch(path: id, expected: object.decodedDigest.hex, actual: first.hex) }
            guard second == extent.digest else { throw LauncherError.digestMismatch(path: id, expected: extent.digest.hex, actual: second.hex) }
        } catch let error as CorruptObjectError { throw AssemblyBadObject(id: id, cause: error) }
        catch let error as LauncherError {
            switch error {
            case .digestMismatch, .sizeMismatch: throw AssemblyBadObject(id: id, cause: error)
            default: throw error
            }
        }
    }

    private static func copyLocal(_ path: SafeRelativePath, offset: Int64, extent: Extent, fs: ContainedFileSystem,
        output: FileHandle, sink: DigestingOutput) throws -> Bool {
        guard let size = try fs.size(at: path), offset >= 0, offset <= size, extent.length <= size - offset else { return false }
        OperationWork.record(.localRangeHash)
        let input = try fs.openForReading(at: path)
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(offset)); try output.seek(toOffset: UInt64(extent.fileOffset))
        sink.begin(offset: extent.fileOffset, first: extent.digest.algorithm, second: extent.digest.algorithm)
        var remaining = extent.length
        while remaining > 0 {
            try Task.checkCancellation()
            let piece = try autoreleasepool { try input.read(upToCount: Int(min(65_536, remaining))) ?? Data() }
            guard !piece.isEmpty else { return false }
            try sink.writeAll(piece, to: output.fileDescriptor); remaining -= Int64(piece.count)
        }
        return sink.extentDigests().0 == extent.digest
    }

    @concurrent static func matches(_ file: FileTask, plan: InstallPlan, fs: ContainedFileSystem) async throws -> Bool {
        let path = try StagingLayout(id: plan.id).file(file.path)
        guard try fs.size(at: path) == file.size else { return false }
        return try hash(path, size: file.size, algorithm: file.digest.algorithm, fs: fs) == file.digest
    }

    private static func hash(_ path: SafeRelativePath, size: Int64, algorithm: DigestAlgorithm, fs: ContainedFileSystem) throws -> Digest {
        let span = OperationWork.begin(.hashing); defer { span?.end() }
        let input = try fs.openForReading(at: path)
        defer { try? input.close() }
        var h = StreamingHasher(algorithm), remaining = size
        while remaining > 0 {
            try Task.checkCancellation()
            let piece = try input.read(upToCount: Int(min(65_536, remaining))) ?? Data()
            guard !piece.isEmpty else { throw LauncherError.io("Staged file changed while hashing") }
            h.update(piece); remaining -= Int64(piece.count)
        }
        return h.finalize()
    }
}

/// The decoder's actual successful writes feed both extent and file digests.
/// A rewind (e.g. a failed local copy followed by fallback) invalidates only the
/// streaming file digest; that rare case uses one final read instead.
private final class DigestingOutput: FileOps {
    private struct State {
        var file: StreamingHasher
        var first: StreamingHasher?
        var second: StreamingHasher?
        var position: Int64 = 0
        var sequential = true
    }
    private let base: any FileOps
    private let descriptor: Int32
    private let state: Mutex<State>
    init(base: any FileOps, descriptor: Int32, algorithm: DigestAlgorithm) {
        self.base = base; self.descriptor = descriptor; state = Mutex(State(file: StreamingHasher(algorithm)))
    }
    func begin(offset: Int64, first: DigestAlgorithm, second: DigestAlgorithm) {
        state.withLock {
            if offset != $0.position { $0.sequential = false }
            $0.position = offset; $0.first = StreamingHasher(first)
            $0.second = first == second ? nil : StreamingHasher(second)
        }
    }
    func extentDigests() -> (Digest, Digest) {
        state.withLock { s in let first = s.first!.finalize(); return (first, s.second?.finalize() ?? first) }
    }
    func fileDigest(size: Int64) -> Digest? { state.withLock { $0.sequential && $0.position == size ? $0.file.finalize() : nil } }
    func write(_ fd: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        let written = try base.write(fd, bytes: bytes)
        if fd == descriptor, written > 0, written <= bytes.count {
            let span = OperationWork.begin(.hashing); defer { span?.end() }
            let buffer = UnsafeRawBufferPointer(rebasing: bytes.prefix(written))
            state.withLock {
                $0.file.update(buffer: buffer); $0.first?.update(buffer: buffer); $0.second?.update(buffer: buffer); $0.position += Int64(written)
            }
        }
        return written
    }
    func synchronize(_ descriptor: Int32, durable: Bool) throws { try base.synchronize(descriptor, durable: durable) }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        try base.rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws { try base.unlink(name, in: directory, isDirectory: isDirectory) }
}
