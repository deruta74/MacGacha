import Darwin
import Foundation

public struct SystemInfo: Codable, Sendable {
    public let macOSVersion: String
    public let macOSBuild: String
    public let hardwareModel: String
    public let chip: String
    public let memoryBytes: UInt64
    public let appVersion: String

    public init(macOSVersion: String, macOSBuild: String, hardwareModel: String, chip: String,
        memoryBytes: UInt64, appVersion: String) {
        self.macOSVersion = macOSVersion
        self.macOSBuild = macOSBuild
        self.hardwareModel = hardwareModel
        self.chip = chip
        self.memoryBytes = memoryBytes
        self.appVersion = appVersion
    }

    public static func current(appVersion: String) -> SystemInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return SystemInfo(macOSVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            macOSBuild: sysctlString("kern.osversion"), hardwareModel: sysctlString("hw.model"),
            chip: sysctlString("machdep.cpu.brand_string"), memoryBytes: ProcessInfo.processInfo.physicalMemory,
            appVersion: appVersion)
    }

    private static func sysctlString(_ name: String) -> String {
        var count = 0
        guard sysctlbyname(name, nil, &count, nil, 0) == 0, count > 0, count <= 65_536 else { return "Unknown" }
        var bytes = [UInt8](repeating: 0, count: count)
        guard sysctlbyname(name, &bytes, &count, nil, 0) == 0 else { return "Unknown" }
        return String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}
