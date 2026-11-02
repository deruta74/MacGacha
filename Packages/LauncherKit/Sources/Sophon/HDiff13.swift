// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import LauncherCore
import CHDiffPatch

/// One HDIFF13 file reconstruction. Inputs stay read-only; output is caller-owned
/// scratch space and may contain a partial result on failure. Verify its digest
/// before committing it. Positional I/O preserves all handles' seek positions.
/// Supports raw and zstd sections (8 MiB window per stream, 64 MiB total C heap).
public enum HDiff13 {
    public struct FileRange: Sendable {
        public let fileSystem: ContainedFileSystem
        public let path: SafeRelativePath
        public let offset: Int64
        public let length: Int64
        public init(fileSystem: ContainedFileSystem, path: SafeRelativePath, offset: Int64 = 0, length: Int64) {
            self.fileSystem = fileSystem; self.path = path; self.offset = offset; self.length = length
        }
    }

    public static func apply(old: FileRange, patch: FileRange, expectedSize: Int64, output: FileHandle, fileOps: any FileOps = SystemFileOps()) async throws {
        try await apply(old: old, patch: patch, expectedSize: expectedSize, output: output, fileOps: fileOps, onStep: { _ in })
    }

    enum Step: Sendable { case readOld, readPatch, writeOutput }
    // Smaller buffers exercise real compressed blocks across decoder boundaries.
    struct BufferSizes: Sendable {
        var read = 64 << 10
        var output = 16 << 10
    }
    static func apply(old: FileRange, patch: FileRange, expectedSize: Int64, output: FileHandle,
        fileOps: any FileOps = SystemFileOps(), buffers: BufferSizes = BufferSizes(), onStep: @escaping @Sendable (Step) -> Void) async throws {
        do {
            try await BlockingIO.run {
                guard (1...(64 << 10)).contains(buffers.read), (512...(16 << 10)).contains(buffers.output) else {
                    throw LauncherError.io("Invalid HDiff buffer size")
                }
                guard expectedSize >= 0 else { throw LauncherError.io("Invalid HDiff range") }
                try validateRange(old); try validateRange(patch)
                let oldFile = try old.fileSystem.openForReading(at: old.path)
                defer { try? oldFile.close() }
                let patchFile = try patch.fileSystem.openForReading(at: patch.path)
                defer { try? patchFile.close() }
                let oldInfo = try fileInfo(oldFile), patchInfo = try fileInfo(patchFile), outputInfo = try fileInfo(output)
                let flags = fcntl(output.fileDescriptor, F_GETFL)
                guard flags >= 0, flags & O_ACCMODE != O_RDONLY, flags & O_APPEND == 0,
                      !(outputInfo.st_dev == oldInfo.st_dev && outputInfo.st_ino == oldInfo.st_ino),
                      !(outputInfo.st_dev == patchInfo.st_dev && outputInfo.st_ino == patchInfo.st_ino) else {
                    throw LauncherError.io("HDiff requires distinct regular files")
                }
                try checkSize(old, info: oldInfo); try checkSize(patch, info: patchInfo)
                let context = HDiffContext(old: old, oldFile: oldFile, patch: patch, patchFile: patchFile, output: output, fileOps: fileOps, onStep: onStep)
                var callbacks = MGHDiffCallbacks(context: Unmanaged.passUnretained(context).toOpaque(),
                    read_old: { context, position, bytes, count in
                        guard let context, let bytes else { return 0 }
                        return Unmanaged<HDiffContext>.fromOpaque(context).takeUnretainedValue().read(.readOld, position, bytes, count)
                    }, read_patch: { context, position, bytes, count in
                        guard let context, let bytes else { return 0 }
                        return Unmanaged<HDiffContext>.fromOpaque(context).takeUnretainedValue().read(.readPatch, position, bytes, count)
                    }, write_new: { context, position, bytes, count in
                        guard let context, let bytes else { return 0 }
                        return Unmanaged<HDiffContext>.fromOpaque(context).takeUnretainedValue().write(position, bytes, count)
                    }, cancelled: { _ in Task.isCancelled ? 1 : 0 })
                var info = MGHDiffInfo()
                let result = mg_hdiff_apply(&callbacks, UInt64(old.length), UInt64(patch.length), UInt64(expectedSize), &info, buffers.read, buffers.output)
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                if let error = context.error { throw error }
                switch result {
                case mg_hdiff_ok:
                    guard ftruncate(output.fileDescriptor, expectedSize) == 0 else { throw LauncherError.io("Cannot size HDiff output") }
                case mg_hdiff_cancelled: throw LauncherError.cancelled
                case mg_hdiff_unsupported_compressor: throw LauncherError.unsupportedCompressor
                case mg_hdiff_old_size: throw LauncherError.sizeMismatch(path: "HDiff source", expected: Int64(info.old_size), actual: old.length)
                case mg_hdiff_new_size: throw LauncherError.sizeMismatch(path: "HDiff output", expected: expectedSize, actual: Int64(info.new_size))
                case mg_hdiff_memory: throw LauncherError.io("HDiff decoder memory limit")
                default: throw LauncherError.malformedPatch
                }
            }
        } catch is CancellationError { throw LauncherError.cancelled }
    }

    private static func validateRange(_ range: FileRange) throws {
        guard range.offset >= 0, range.length >= 0, !range.offset.addingReportingOverflow(range.length).overflow else {
            throw LauncherError.io("Invalid HDiff range")
        }
    }
    private static func checkSize(_ range: FileRange, info: stat) throws {
        guard range.offset + range.length <= info.st_size else {
            throw LauncherError.sizeMismatch(path: "HDiff input range", expected: range.offset + range.length, actual: info.st_size)
        }
    }
    private static func fileInfo(_ handle: FileHandle) throws -> stat {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            throw LauncherError.io("HDiff requires distinct regular files")
        }
        return info
    }
}

private final class HDiffContext {
    let old: HDiff13.FileRange, patch: HDiff13.FileRange
    let oldFile: FileHandle, patchFile: FileHandle, output: FileHandle
    let fileOps: any FileOps
    let onStep: @Sendable (HDiff13.Step) -> Void
    var error: LauncherError?
    init(old: HDiff13.FileRange, oldFile: FileHandle, patch: HDiff13.FileRange, patchFile: FileHandle, output: FileHandle, fileOps: any FileOps,
        onStep: @escaping @Sendable (HDiff13.Step) -> Void) {
        self.old = old; self.oldFile = oldFile; self.patch = patch; self.patchFile = patchFile; self.output = output; self.fileOps = fileOps; self.onStep = onStep
    }
    func read(_ step: HDiff13.Step, _ position: UInt64, _ bytes: UnsafeMutablePointer<UInt8>, _ count: Int) -> Int32 {
        let range = step == .readOld ? old : patch, file = step == .readOld ? oldFile : patchFile
        guard position <= UInt64(range.length), count <= range.length - Int64(position) else { error = .malformedPatch; return 0 }
        return transfer(step, count: count) { done, size in
            pread(file.fileDescriptor, bytes + done, size, range.offset + Int64(position) + Int64(done))
        }
    }
    func write(_ position: UInt64, _ bytes: UnsafePointer<UInt8>, _ count: Int) -> Int32 {
        transfer(.writeOutput, count: count) { done, size in
            try fileOps.write(output.fileDescriptor, bytes: UnsafeRawBufferPointer(start: bytes + done, count: size), at: Int64(position) + Int64(done))
        }
    }
    private func transfer(_ step: HDiff13.Step, count: Int, operation: (Int, Int) throws -> Int) -> Int32 {
        guard error == nil else { return 0 }
        onStep(step)
        var done = 0
        while done < count {
            guard !Task.isCancelled else { error = .cancelled; return 0 }
            let result: Int
            do { result = try operation(done, min(64 << 10, count - done)) }
            catch { self.error = (LauncherError.normalizingFileSystemError(error) as? LauncherError) ?? .io("Cannot transfer HDiff file bytes"); return 0 }
            if result < 0 && errno == EINTR { continue }
            guard result > 0, result <= min(64 << 10, count - done) else { error = .io("Cannot transfer HDiff file bytes"); return 0 }
            done += result
        }
        return 1
    }
}
