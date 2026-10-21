// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import CZstd
import LauncherCore

/// Invalid encoded bytes, distinct from cancellation and failures reading/writing local files.
public struct CorruptObjectError: Error, Sendable, Equatable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

public struct ZstdDecoder: ChunkDecoder {
    private let fileOps: any FileOps
    public init(fileOps: any FileOps = SystemFileOps()) { self.fileOps = fileOps }

    public func decode(_ transferred: FileHandle, expectedSize: Int64, into output: FileHandle, at offset: Int64) throws {
        guard expectedSize >= 0, offset >= 0, !offset.addingReportingOverflow(expectedSize).overflow else {
            throw LauncherError.io("Invalid decode range")
        }
        try checkZstdCancellation()
        var inputInfo = stat(); var outputInfo = stat()
        guard fstat(transferred.fileDescriptor, &inputInfo) == 0, inputInfo.st_mode & S_IFMT == S_IFREG,
            fstat(output.fileDescriptor, &outputInfo) == 0, outputInfo.st_mode & S_IFMT == S_IFREG,
            inputInfo.st_dev != outputInfo.st_dev || inputInfo.st_ino != outputInfo.st_ino else {
            throw LauncherError.io("Decoder requires distinct regular files")
        }
        do {
            try transferred.seek(toOffset: 0); try output.seek(toOffset: UInt64(offset))
            // Never chase a concurrently growing file; the caller verified this transfer's size.
            var remaining = inputInfo.st_size
            try ZstdStream().decode(expectedSize: expectedSize, read: {
                guard remaining > 0 else { return Data() }
                let piece = try autoreleasepool { try transferred.read(upToCount: Int(min(65_536, remaining))) ?? Data() }
                guard !piece.isEmpty else { throw CorruptObjectError(reason: "Truncated zstd object") }
                remaining -= Int64(piece.count)
                return piece
            }, write: { try fileOps.writeAll($0, to: output.fileDescriptor) })
        } catch {
            if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
            if error is CorruptObjectError || error is LauncherError { throw error }
            throw LauncherError.io("Cannot decode zstd object")
        }
    }
}

public enum Zstd {
    /// Output grows only as bytes are decoded; an untrusted expected size never causes a large reservation.
    public static func decode(_ data: Data, expectedSize: Int) throws -> Data {
        guard expectedSize >= 0 else { throw LauncherError.io("Invalid decode range") }
        try checkZstdCancellation()
        var position = 0; var output = Data()
        try ZstdStream().decode(expectedSize: Int64(expectedSize), read: {
            let count = min(65_536, data.count - position)
            defer { position += count }
            return data.subdata(in: position..<(position + count))
        }, write: { output.append($0) })
        return output
    }
}

/// One context per invocation; no shared decoder state crosses tasks or frames.
private final class ZstdStream {
    private let context: OpaquePointer
    private static let outputSize = 128 << 10

    init() throws {
        guard let context = ZSTD_createDStream() else { throw LauncherError.io("Cannot create zstd decoder") }
        if ZSTD_isError(ZSTD_initDStream(context)) != 0 || ZSTD_isError(ZSTD_DCtx_setParameter(context, ZSTD_d_windowLogMax, 27)) != 0 {
            ZSTD_freeDStream(context)
            throw LauncherError.io("Cannot configure zstd decoder")
        }
        self.context = context
    }
    deinit { ZSTD_freeDStream(context) }

    func decode(expectedSize: Int64, read: () throws -> Data, write: (Data) throws -> Void) throws {
        var input = Data(); var position = 0
        var buffer = [UInt8](repeating: 0, count: Self.outputSize)
        var total: Int64 = 0
        var finishedFrame = false; var eof = false; var drain = false
        while true {
            try checkZstdCancellation()
            if position == input.count && !drain {
                input = try read(); position = 0
                if input.isEmpty {
                    eof = true
                    if finishedFrame { break }
                }
            }
            if finishedFrame && position < input.count {
                guard ZSTD_isError(ZSTD_DCtx_reset(context, ZSTD_reset_session_only)) == 0 else {
                    throw LauncherError.io("Cannot reset zstd decoder")
                }
                finishedFrame = false
            }
            let before = position
            var produced = 0
            let result = input.withUnsafeBytes { source in
                buffer.withUnsafeMutableBytes { destination in
                    var encoded = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: position)
                    var decoded = ZSTD_outBuffer(dst: destination.baseAddress, size: destination.count, pos: 0)
                    let hint = ZSTD_decompressStream(context, &decoded, &encoded)
                    position = encoded.pos; produced = decoded.pos
                    return hint
                }
            }
            if ZSTD_isError(result) != 0 {
                if ZSTD_getErrorCode(result) == ZSTD_error_memory_allocation {
                    throw LauncherError.io("Cannot allocate zstd decoder memory")
                }
                throw CorruptObjectError(reason: String(cString: ZSTD_getErrorName(result)))
            }
            let (next, overflow) = total.addingReportingOverflow(Int64(produced))
            guard !overflow, next <= expectedSize else {
                throw LauncherError.sizeMismatch(path: "decoded object", expected: expectedSize, actual: overflow ? Int64.max : next)
            }
            try checkZstdCancellation()
            if produced > 0 { try write(Data(buffer.prefix(produced))) }
            total = next; finishedFrame = result == 0
            // A full output buffer with a nonzero hint can retain decoded bytes after all
            // input was consumed. Drain those bytes with empty input before declaring EOF.
            // Result 0 already guarantees a completely flushed frame, even if exactly full.
            drain = produced == buffer.count && !finishedFrame
            if eof {
                if finishedFrame { break }
                guard produced > 0 else { throw CorruptObjectError(reason: "Truncated zstd frame") }
                drain = true
            } else if position == before && produced == 0 && position < input.count {
                throw CorruptObjectError(reason: "Zstd decoder made no progress")
            }
        }
        guard total == expectedSize else {
            throw LauncherError.sizeMismatch(path: "decoded object", expected: expectedSize, actual: total)
        }
    }
}

private func checkZstdCancellation() throws {
    guard !Task.isCancelled else { throw LauncherError.cancelled }
}
