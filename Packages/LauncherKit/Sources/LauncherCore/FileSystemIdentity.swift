// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation

/// Stable across a remount of a volume with a UUID. Device numbers are only a
/// fallback for filesystems which do not supply a persistent volume identity.
public struct FileSystemIdentity: Codable, Sendable, Hashable {
    public enum Volume: Codable, Sendable, Hashable { case uuid(UUID), device(Int64) }
    public let volume: Volume
    public let inode: UInt64
    public init(volumeUUID: UUID?, device: Int64, inode: UInt64) {
        volume = volumeUUID.map(Volume.uuid) ?? .device(device)
        self.inode = inode
    }
}

/// The descriptor is borrowed. Injectable to test remounts without unmounting
/// the test volume or changing the production root-opening code path.
public protocol FileSystemIdentityProvider: Sendable {
    func identity(of descriptor: Int32) throws -> FileSystemIdentity
}

public struct SystemFileSystemIdentityProvider: FileSystemIdentityProvider {
    public init() {}
    public func identity(of descriptor: Int32) throws -> FileSystemIdentity {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw LauncherError.io("Cannot inspect contained root") }
        var bytes = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        guard bytes.withUnsafeMutableBytes({ fcntl(descriptor, F_GETPATH, $0.baseAddress!) }) == 0,
            let path = String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8) else {
            throw LauncherError.io("Cannot inspect root volume")
        }
        let values: URLResourceValues
        do { values = try URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]) }
        catch { throw LauncherError.io("Cannot inspect root volume") }
        let uuid: UUID?
        if let value = values.volumeUUIDString {
            guard let parsed = UUID(uuidString: value) else { throw LauncherError.io("Invalid volume identity") }
            uuid = parsed
        } else { uuid = nil }
        return FileSystemIdentity(volumeUUID: uuid, device: Int64(info.st_dev), inode: UInt64(info.st_ino))
    }
}
