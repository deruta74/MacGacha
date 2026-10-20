import Foundation

public protocol DiskSpaceProbe: Sendable {
    func availableBytes(at url: URL) throws -> Int64
}

public struct SystemDiskSpaceProbe: DiskSpaceProbe {
    public init() {}

    public func availableBytes(at url: URL) throws -> Int64 {
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            guard let bytes = values.volumeAvailableCapacityForImportantUsage else {
                throw LauncherError.io("Available disk capacity is unavailable")
            }
            return bytes
        } catch let error as LauncherError {
            throw error
        } catch {
            throw LauncherError.io(error.localizedDescription)
        }
    }
}
