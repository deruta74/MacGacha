// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation

/// Optional package-level allocation barrier; never held across suspension.
package protocol AllocationFileOps: FileOps {
    func beginAllocation()
    func endAllocation()
    func openedForWriting(_ descriptor: Int32) throws
}

/// Borrowed descriptors and leaf names, after ContainedFileSystem has checked traversal.
/// Implementations must preserve syscall semantics, including advancing the offset on short writes.
public protocol FileOps: Sendable {
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int
    func synchronize(_ descriptor: Int32, durable: Bool) throws
    func rename(from source: String, in sourceDirectory: Int32, to destination: String,
        in destinationDirectory: Int32, exclusive: Bool) throws
    func swap(from source: String, in sourceDirectory: Int32, to destination: String,
        in destinationDirectory: Int32) throws
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws
}

public struct SystemFileOps: FileOps {
    public init() {}

    public func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        // writeAll owns cancellation policy; a journal record must finish once writing starts.
        while true {
            let result = Darwin.write(descriptor, bytes.baseAddress, bytes.count)
            if result >= 0 { return result }
            guard errno == EINTR else { throw LauncherError.fileSystemFailure("Cannot write file (errno \(errno))") }
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
        guard result == 0 else { throw LauncherError.fileSystemFailure("Cannot rename file (errno \(errno))") }
    }

    public func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws {
        guard unlinkat(directory, name, isDirectory ? AT_REMOVEDIR : 0) == 0 || errno == ENOENT else {
            throw LauncherError.fileSystemFailure("Cannot remove file (errno \(errno))")
        }
    }
}

extension FileOps {
    /// Atomic directory exchange on macOS. A default preserves existing fault doubles;
    /// override this requirement to inject a failure at the swap syscall boundary.
    public func swap(from source: String, in sourceDirectory: Int32, to destination: String,
        in destinationDirectory: Int32) throws {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard renameatx_np(sourceDirectory, source, destinationDirectory, destination, UInt32(RENAME_SWAP)) == 0 else {
            throw LauncherError.fileSystemFailure("Cannot swap runtime directories (errno \(errno))")
        }
    }

    /// Bounded writes; retry short writes without dropping bytes and refuse non-progressing doubles.
    public func writeAll(_ data: Data, to descriptor: Int32, checkingCancellation: Bool = true,
        didWrite: (Int) -> Void = { _ in }) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard !checkingCancellation || !Task.isCancelled else { throw LauncherError.cancelled }
                let end = offset + min(65_536, bytes.count - offset)
                let count: Int
                do { count = try write(descriptor, bytes: UnsafeRawBufferPointer(rebasing: bytes[offset..<end])) }
                catch { throw LauncherError.normalizingFileSystemError(error) }
                guard count > 0, count <= end - offset else { throw LauncherError.io("Invalid write progress") }
                offset += count
                didWrite(count)
            }
        }
    }
}

extension LauncherError {
    /// A failed allocation supplies no reliable byte shortfall (quotas may be
    /// lower than free blocks). Preserve a positive shortfall for the pause/UI.
    package static func fileSystemFailure(_ message: String, code: Int32 = errno) -> LauncherError {
        code == ENOSPC || code == EDQUOT ? .insufficientSpace(required: 1, available: 0) : .io(message)
    }

    /// Foundation/FileOps fault doubles may carry errno as a typed NSError.
    /// Never infer allocation failures by parsing localized/free-text messages.
    package static func normalizingFileSystemError(_ error: any Error) -> any Error {
        if error is LauncherError { return error }
        var current = error as NSError
        for _ in 0..<8 {
            if current.domain == NSPOSIXErrorDomain, current.code == Int(ENOSPC) || current.code == Int(EDQUOT) {
                return LauncherError.insufficientSpace(required: 1, available: 0)
            }
            if current.domain == NSCocoaErrorDomain, current.code == NSFileWriteOutOfSpaceError {
                return LauncherError.insufficientSpace(required: 1, available: 0)
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return error
    }
}

/// Normalize every injected and system mutation boundary, including delayed
/// allocation errors reported by fsync or rename rather than by write.
package struct SpaceAwareFileOps: AllocationFileOps {
    let base: any FileOps
    private func mapped<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw LauncherError.normalizingFileSystemError(error) }
    }
    package func beginAllocation() { (base as? any AllocationFileOps)?.beginAllocation() }
    package func endAllocation() { (base as? any AllocationFileOps)?.endAllocation() }
    package func openedForWriting(_ descriptor: Int32) throws {
        try mapped { try (base as? any AllocationFileOps)?.openedForWriting(descriptor) }
    }
    package func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        try mapped { try base.write(descriptor, bytes: bytes) }
    }
    package func synchronize(_ descriptor: Int32, durable: Bool) throws {
        try mapped { try base.synchronize(descriptor, durable: durable) }
    }
    package func rename(from source: String, in sourceDirectory: Int32, to destination: String,
        in destinationDirectory: Int32, exclusive: Bool) throws {
        try mapped { try base.rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive) }
    }
    package func swap(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32) throws {
        try mapped { try base.swap(from: source, in: sourceDirectory, to: destination, in: destinationDirectory) }
    }
    package func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws {
        try mapped { try base.unlink(name, in: directory, isDirectory: isDirectory) }
    }
}
