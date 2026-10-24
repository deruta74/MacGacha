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

/// An incomplete scan cannot prove that a game or wineserver has exited.
public enum ProcessInspectionError: Error, Sendable, Equatable {
    case incompleteScan
}

/// Synchronous kernel queries: async callers must use BlockingIO.run.
public protocol ProcessInspector: Sendable {
    func isAlive(_ id: ProcessIdentity) -> Bool
    /// Scans this user's processes. Global failures and unreadable same-user
    /// entries throw; only confirmed vanished, reused or zombie entries are skipped.
    /// An empty successful scan is meaningful to recovery.
    func processes(environmentContains key: String, value: String) throws -> [InspectedProcess]
}

public struct SystemProcessInspector: ProcessInspector {
    private let kernel: any ProcessKernel
    public init() { kernel = SystemProcessKernel() }
    init(kernel: any ProcessKernel) { self.kernel = kernel }

    public func isAlive(_ id: ProcessIdentity) -> Bool {
        guard id.pid > 0, let process = kernel.process(pid: id.pid), Int32(process.kp_proc.p_stat) != SZOMB else { return false }
        return process.processIdentity == id
    }

    public func processes(environmentContains key: String, value: String) throws -> [InspectedProcess] {
        guard !key.isEmpty, !key.contains("="), !key.utf8.contains(0), !value.utf8.contains(0) else { return [] }
        let entry = Array((key + "=" + value).utf8)
        var matches: [InspectedProcess] = []
        for process in try kernel.processes() {
            // Spawned Wine/game children retain our effective user. Protected
            // system processes belonging to other users cannot be our children
            // and must not make every session scan permanently incomplete.
            guard process.kp_eproc.e_ucred.cr_uid == geteuid(), Int32(process.kp_proc.p_stat) != SZOMB else { continue }
            guard let identity = process.processIdentity else { throw ProcessInspectionError.incompleteScan }
            let bytes = kernel.arguments(pid: identity.pid)
            // Distinguish confirmed disappearance from a failed identity lookup;
            // isAlive's Bool alone deliberately cannot authorize restoration.
            guard let current = try kernel.checkedProcess(pid: identity.pid) else { continue }
            guard Int32(current.kp_proc.p_stat) != SZOMB else { continue }
            guard let currentIdentity = current.processIdentity else { throw ProcessInspectionError.incompleteScan }
            guard currentIdentity == identity else { continue }
            guard let bytes, let args = ProcessArguments.parse(bytes) else { throw ProcessInspectionError.incompleteScan }
            guard args.environmentContains(entry) else { continue }
            matches.append(InspectedProcess(identity: identity, executablePath: args.executablePath, arguments: args.arguments))
        }
        return matches.sorted { $0.identity.pid < $1.identity.pid }
    }
}

protocol ProcessKernel: Sendable {
    func process(pid: Int32) -> kinfo_proc?
    func checkedProcess(pid: Int32) throws -> kinfo_proc?
    func processes() throws -> [kinfo_proc]
    func arguments(pid: Int32) -> Data?
}

extension ProcessKernel {
    func checkedProcess(pid: Int32) throws -> kinfo_proc? { process(pid: pid) }
}

struct SystemProcessKernel: ProcessKernel {
    func process(pid: Int32) -> kinfo_proc? { try? checkedProcess(pid: pid) }

    func checkedProcess(pid: Int32) throws -> kinfo_proc? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
        var result: Int32
        repeat { result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) } while result < 0 && errno == EINTR
        if result < 0 {
            if errno == ESRCH { return nil }
            throw ProcessInspectionError.incompleteScan
        }
        if size == 0 { return nil }
        guard size == MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else {
            throw ProcessInspectionError.incompleteScan
        }
        return info
    }

    func processes() throws -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        // The process table may grow between the size query and the copy.
        for _ in 0..<4 {
            var size = 0
            let query = sysctl(&mib, u_int(mib.count), nil, &size, nil, 0)
            if query < 0 && errno == EINTR { continue }
            guard query == 0, size > 0, size <= 64 << 20 else {
                throw LauncherError.io("Cannot inspect process table")
            }
            let stride = MemoryLayout<kinfo_proc>.stride
            var records = [kinfo_proc](repeating: kinfo_proc(), count: (size + stride - 1) / stride)
            let status = records.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }
            if status < 0 {
                if errno == ENOMEM || errno == EINTR { continue }
                throw LauncherError.io("Cannot inspect process table")
            }
            guard size % stride == 0, size / stride <= records.count else {
                throw LauncherError.io("Invalid process table")
            }
            return Array(records.prefix(size / stride))
        }
        throw LauncherError.io("Process table changed during inspection")
    }

    func arguments(pid: Int32) -> Data? {
        var maximum: Int32 = 0; var size = MemoryLayout<Int32>.size
        var maximumMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&maximumMIB, u_int(maximumMIB.count), &maximum, &size, nil, 0) == 0,
            maximum > 0, maximum <= 4 << 20 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(maximum)); size = bytes.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let status = bytes.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }
        // The scan rechecks identity to distinguish an unreadable live process from disappearance.
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
    private let pathBytes: [UInt8]
    private let argumentBytes: [[UInt8]]
    private let environmentBytes: [[UInt8]]

    // POSIX strings need not be UTF-8. Keep their bytes for exact environment
    // matching; decode only the matched process's descriptive fields lossily.
    var executablePath: String { String(decoding: pathBytes, as: UTF8.self) }
    var arguments: [String] { argumentBytes.map { String(decoding: $0, as: UTF8.self) } }
    var environment: [String] { environmentBytes.map { String(decoding: $0, as: UTF8.self) } }
    func environmentContains(_ entry: [UInt8]) -> Bool { environmentBytes.contains(entry) }

    static func parse(_ data: Data) -> ProcessArguments? {
        guard data.count >= MemoryLayout<Int32>.size else { return nil }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        let bytes = [UInt8](data)
        var offset = MemoryLayout<Int32>.size
        func string() -> [UInt8]? {
            guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0) else { return nil }
            let value = Array(bytes[offset..<end])
            offset = end + 1
            return value
        }
        guard argc > 0, Int(argc) <= bytes.count - offset,
            let path = string(), !path.isEmpty else { return nil }
        while offset < bytes.count && bytes[offset] == 0 { offset += 1 }
        var arguments: [[UInt8]] = []
        for _ in 0..<argc {
            guard let argument = string() else { return nil }
            arguments.append(argument)
        }
        var environment: [[UInt8]] = []
        while offset < bytes.count {
            guard let value = string() else { return nil }
            if value.isEmpty {
                // Darwin may return padding and Apple auxiliary strings after
                // the environment terminator. They are not environment entries.
                break
            }
            environment.append(value)
        }
        return ProcessArguments(pathBytes: path, argumentBytes: arguments, environmentBytes: environment)
    }
}
