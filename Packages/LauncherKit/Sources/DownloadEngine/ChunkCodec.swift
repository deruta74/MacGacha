// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).

import Darwin
import Foundation
import LauncherCore

public enum ChunkCodec: String, Codable, Sendable {
    case identity, zstd

    public func decoder() throws -> any ChunkDecoder {
        switch self {
        case .identity: return IdentityDecoder()
        case .zstd: throw LauncherError.io("codec unsupported: zstd")
        }
    }
}

public protocol ChunkDecoder: Sendable {
    func decode(_ transferred: URL, expectedSize: Int64, into: FileHandle, at offset: Int64) throws
}

public struct IdentityDecoder: ChunkDecoder {
    public init() {}

    public func decode(_ transferred: URL, expectedSize: Int64, into output: FileHandle, at offset: Int64) throws {
        guard transferred.isFileURL, !transferred.path.utf8.contains(0), expectedSize >= 0, offset >= 0,
              !offset.addingReportingOverflow(expectedSize).overflow else { throw LauncherError.io("Invalid decode range or URL") }
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        let fd = open(transferred.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw LauncherError.io("Cannot open transferred object") }
        let source = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? source.close() }
        var inputInfo = stat()
        var outputInfo = stat()
        guard fstat(fd, &inputInfo) == 0, inputInfo.st_mode & S_IFMT == S_IFREG,
              fstat(output.fileDescriptor, &outputInfo) == 0, outputInfo.st_mode & S_IFMT == S_IFREG,
              inputInfo.st_dev != outputInfo.st_dev || inputInfo.st_ino != outputInfo.st_ino else {
            throw LauncherError.io("Decoder requires distinct regular files")
        }
        guard inputInfo.st_size == expectedSize else {
            throw LauncherError.sizeMismatch(path: transferred.path, expected: expectedSize, actual: inputInfo.st_size)
        }
        do {
            try output.seek(toOffset: UInt64(offset))
            var remaining = expectedSize
            while remaining > 0 {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                let data = try autoreleasepool { try source.read(upToCount: Int(min(65_536, remaining))) ?? Data() }
                guard !data.isEmpty else {
                    throw LauncherError.sizeMismatch(path: transferred.path, expected: expectedSize, actual: expectedSize - remaining)
                }
                try output.write(contentsOf: data)
                remaining -= Int64(data.count)
            }
        } catch let error as LauncherError { throw error }
        catch { throw LauncherError.io("Cannot decode identity object") }
    }
}
