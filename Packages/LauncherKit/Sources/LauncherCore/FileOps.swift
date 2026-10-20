// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation

/// Borrowed descriptors and leaf names, after ContainedFileSystem has checked traversal.
/// Implementations must preserve syscall semantics, including advancing the offset on short writes.
public protocol FileOps: Sendable {
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int
    func synchronize(_ descriptor: Int32, durable: Bool) throws
    func rename(from source: String, in sourceDirectory: Int32, to destination: String,
        in destinationDirectory: Int32, exclusive: Bool) throws
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws
}

public struct SystemFileOps: FileOps {
    public init() {}

    public func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        while true {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            let result = Darwin.write(descriptor, bytes.baseAddress, bytes.count)
            if result >= 0 { return result }
            guard errno == EINTR else { throw LauncherError.io("Cannot write file (errno \(errno))") }
        }
    }

    public func synchronize(_ descriptor: Int32, durable: Bool) throws {
        try ContainedFileSystem.synchronizeFileDescriptor(descriptor, durable: durable)
    }

    public func rename(from source: String, in sourceDirectory: Int32, to destination: String,
        in destinationDirectory: Int32, exclusive: Bool) throws {
        let result = exclusive
            ? renameatx_np(sourceDirectory, source, destinationDirectory, destination, UInt32(RENAME_EXCL))
            : renameat(sourceDirectory, source, destinationDirectory, destination)
        guard result == 0 else { throw LauncherError.io("Cannot rename file (errno \(errno))") }
    }

    public func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws {
        guard unlinkat(directory, name, isDirectory ? AT_REMOVEDIR : 0) == 0 || errno == ENOENT else {
            throw LauncherError.io("Cannot remove file (errno \(errno))")
        }
    }
}

extension FileOps {
    /// Bounded writes; retry short writes without dropping bytes and refuse non-progressing doubles.
    public func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                let end = offset + min(65_536, bytes.count - offset)
                let count = try write(descriptor, bytes: UnsafeRawBufferPointer(rebasing: bytes[offset..<end]))
                guard count > 0, count <= end - offset else { throw LauncherError.io("Invalid write progress") }
                offset += count
            }
        }
    }
}
