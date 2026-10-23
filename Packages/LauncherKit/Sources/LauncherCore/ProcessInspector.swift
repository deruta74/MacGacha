// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation

/// A PID alone can be reused. startTime is kinfo_proc.p_starttime in epoch microseconds.
public struct ProcessIdentity: Codable, Sendable, Hashable {
    public let pid: Int32
    public let startTime: UInt64
    public init(pid: Int32, startTime: UInt64) { self.pid = pid; self.startTime = startTime }
}

public struct InspectedProcess: Sendable {
    public let identity: ProcessIdentity
    public let executablePath: String
    public let arguments: [String]
    public init(identity: ProcessIdentity, executablePath: String, arguments: [String]) {
        self.identity = identity; self.executablePath = executablePath; self.arguments = arguments
    }
}

/// Synchronous kernel queries: async callers must use BlockingIO.run.
public protocol ProcessInspector: Sendable {
    func isAlive(_ id: ProcessIdentity) -> Bool
    func processes(environmentContains key: String, value: String) -> [InspectedProcess]
}

public struct SystemProcessInspector: ProcessInspector {
    private let kernel: any ProcessKernel
    public init() { kernel = SystemProcessKernel() }
    init(kernel: any ProcessKernel) { self.kernel = kernel }

    public func isAlive(_ id: ProcessIdentity) -> Bool {
        guard id.pid > 0, let process = kernel.process(pid: id.pid), Int32(process.kp_proc.p_stat) != SZOMB else { return false }
        return process.processIdentity == id
    }

    public func processes(environmentContains key: String, value: String) -> [InspectedProcess] {
        guard !key.isEmpty, !key.contains("="), !key.utf8.contains(0), !value.utf8.contains(0) else { return [] }
        let entry = key + "=" + value
        return kernel.processes().compactMap { process in
            guard Int32(process.kp_proc.p_stat) != SZOMB, let identity = process.processIdentity,
                let bytes = kernel.arguments(pid: identity.pid), let args = ProcessArguments.parse(bytes),
                args.environment.contains(entry), isAlive(identity) else { return nil }
            // Recheck identity after reading arguments: the table's PID may have been reused.
            return InspectedProcess(identity: identity, executablePath: args.executablePath, arguments: args.arguments)
        }.sorted { $0.identity.pid < $1.identity.pid }
    }
}

protocol ProcessKernel: Sendable {
    func process(pid: Int32) -> kinfo_proc?
    func processes() -> [kinfo_proc]
    func arguments(pid: Int32) -> Data?
}

struct SystemProcessKernel: ProcessKernel {
    func process(pid: Int32) -> kinfo_proc? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
        var result: Int32
        repeat { result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) } while result < 0 && errno == EINTR
        guard result == 0, size == MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else { return nil }
        return info
    }

    func processes() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        // The process table may grow between the size query and the copy.
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0, size <= 64 << 20 else { return [] }
            let stride = MemoryLayout<kinfo_proc>.stride
            var records = [kinfo_proc](repeating: kinfo_proc(), count: (size + stride - 1) / stride)
            let status = records.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }
            if status < 0 {
                if errno == ENOMEM || errno == EINTR { continue }
                return []
            }
            guard size % stride == 0, size / stride <= records.count else { return [] }
            return Array(records.prefix(size / stride))
        }
        return []
    }

    func arguments(pid: Int32) -> Data? {
        var maximum: Int32 = 0; var size = MemoryLayout<Int32>.size
        var maximumMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&maximumMIB, u_int(maximumMIB.count), &maximum, &size, nil, 0) == 0,
            maximum > 0, maximum <= 4 << 20 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(maximum)); size = bytes.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let status = bytes.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }
        // EPERM and a process disappearing mid-scan are normal, not launch failures.
        guard status == 0, size <= bytes.count else { return nil }
        return Data(bytes.prefix(size))
    }
}

extension kinfo_proc {
    var processIdentity: ProcessIdentity? {
        let time = kp_proc.p_un.__p_starttime
        guard kp_proc.p_pid > 0, let seconds = UInt64(exactly: time.tv_sec),
            let micros = UInt64(exactly: time.tv_usec), micros < 1_000_000 else { return nil }
        let (whole, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000)
        let (start, additionOverflow) = whole.addingReportingOverflow(micros)
        guard !overflow, !additionOverflow else { return nil }
        return ProcessIdentity(pid: kp_proc.p_pid, startTime: start)
    }
}

/// KERN_PROCARGS2: argc, executable C string, NUL padding, argc argument C
/// strings, then environment C strings. No strlen or unchecked pointer walking.
struct ProcessArguments {
    let executablePath: String
    let arguments: [String]
    let environment: [String]

    static func parse(_ data: Data) -> ProcessArguments? {
        guard data.count >= MemoryLayout<Int32>.size else { return nil }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        let bytes = [UInt8](data)
        var offset = MemoryLayout<Int32>.size
        func string() -> String? {
            guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0),
                let value = String(bytes: bytes[offset..<end], encoding: .utf8) else { return nil }
            offset = end + 1
            return value
        }
        guard argc > 0, Int(argc) <= bytes.count - offset,
            let path = string(), !path.isEmpty else { return nil }
        while offset < bytes.count && bytes[offset] == 0 { offset += 1 }
        var arguments: [String] = []
        for _ in 0..<argc {
            guard let argument = string() else { return nil }
            arguments.append(argument)
        }
        var environment: [String] = []
        while offset < bytes.count {
            guard let value = string() else { return nil }
            if value.isEmpty {
                // Darwin may return padding and Apple auxiliary strings after
                // the environment terminator. They are not environment entries.
                break
            }
            environment.append(value)
        }
        return ProcessArguments(executablePath: path, arguments: arguments, environment: environment)
    }
}
