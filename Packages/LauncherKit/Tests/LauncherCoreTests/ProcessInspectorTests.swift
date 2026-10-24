// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Testing
@testable import LauncherCore

@Suite(.timeLimit(.minutes(1))) struct ProcessInspectorTests {
    @Test func isAliveRejectsReusedPID() async throws {
        try await BlockingIO.run {
            let identity = try #require(SystemProcessKernel().process(pid: getpid())).processIdentity
            let real = try #require(identity)
            #expect(SystemProcessInspector().isAlive(real))
            #expect(!SystemProcessInspector().isAlive(ProcessIdentity(pid: real.pid, startTime: 1)))
            #expect(!SystemProcessInspector().isAlive(ProcessIdentity(pid: -1, startTime: real.startTime)))
            #expect(try JSONDecoder().decode(ProcessIdentity.self, from: JSONEncoder().encode(real)) == real)
            var info = kinfo_proc(); var count = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
            try #require(sysctl(&mib, u_int(mib.count), &info, &count, nil, 0) == 0)
            let start = info.kp_proc.p_un.__p_starttime
            #expect(real.startTime == UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec))
        }
    }

    @Test func parsesProcArgs2WithPaddingEmptyArgumentsAndEnvironment() throws {
        let data = procArguments(path: "/bin/sleep", arguments: ["sleep", "", "space arg", "日本語"],
            environment: ["A=1", "WINEPREFIX=/some prefix", "A=2"])
        let parsed = try #require(ProcessArguments.parse(data))
        #expect(parsed.executablePath == "/bin/sleep")
        #expect(parsed.arguments == ["sleep", "", "space arg", "日本語"])
        #expect(parsed.environment == ["A=1", "WINEPREFIX=/some prefix", "A=2"])
    }

    @Test func procArgs2RejectsMalformedAndTruncatedBuffers() {
        let prefix = procArguments(path: "/bin/sleep", arguments: ["sleep"], environment: [])
        let invalid: [Data] = [Data(), Data([1, 0, 0]), procArguments(argc: -1), procArguments(argc: .max),
            procArguments(argc: 0), Data(prefix.prefix(7)), Data(prefix.dropLast()),
            procArguments(path: "", arguments: ["sleep"]),
            procArguments(path: "/bin/sleep", arguments: ["sleep"], environment: ["A=1"]).dropLast()]
        for bytes in invalid { #expect(ProcessArguments.parse(bytes) == nil, "Malformed buffer: \(bytes as NSData)") }
    }

    @Test func nonUTF8UnrelatedProcessDataDoesNotMakeScanIncomplete() throws {
        var unrelated = procArguments(environment: [])
        unrelated.append(contentsOf: [79, 84, 72, 69, 82, 61, 0xff, 0]) // OTHER=invalid byte
        var matching = procArguments(arguments: ["wine", "game.exe"], environment: ["WINEPREFIX=/prefix"])
        matching.append(contentsOf: [79, 84, 72, 69, 82, 61, 0xff, 0])
        // POSIX argv and executable paths also permit arbitrary non-NUL bytes.
        matching[4] = 0xff
        let argumentOffset = MemoryLayout<Int32>.size + "/bin/sleep".utf8.count + 3
        matching[argumentOffset] = 0xff
        let inspector = SystemProcessInspector(kernel: ByteInspectionFixture(data: [unrelated, matching]))
        let result = try inspector.processes(environmentContains: "WINEPREFIX", value: "/prefix")
        #expect(result.map(\.identity.pid) == [101])
        #expect(result.first?.arguments == ["�ine", "game.exe"])
        #expect(result.first?.executablePath == "�bin/sleep")
    }

    @Test func processEnvironmentMatchingUsesExactBytes() throws {
        var invalidValue = procArguments()
        invalidValue.append(contentsOf: Array("TAG=".utf8) + [0xff, 0])
        let inspector = SystemProcessInspector(kernel: ByteInspectionFixture(data: [invalidValue]))
        // Lossy decoding must not turn arbitrary bytes into a matching UTF-8 value.
        #expect(try inspector.processes(environmentContains: "TAG", value: "�").isEmpty)
    }

    @Test func truncatedNonUTF8EnvironmentStillMakesScanIncomplete() {
        var truncated = procArguments(environment: ["WINEPREFIX=/prefix"])
        truncated.append(contentsOf: Array("OTHER=".utf8) + [0xff])
        let inspector = SystemProcessInspector(kernel: ByteInspectionFixture(data: [truncated]))
        #expect(ProcessArguments.parse(truncated) == nil)
        #expect(throws: ProcessInspectionError.incompleteScan) {
            try inspector.processes(environmentContains: "WINEPREFIX", value: "/prefix")
        }
    }

    @Test func procArgs2DoesNotTreatAppleAuxiliaryStringsAsEnvironment() throws {
        var data = procArguments(environment: ["TAG=real"])
        data.append(0)
        data.append(contentsOf: "TAG=auxiliary\0executable_path=/bin/sleep\0".utf8)
        let parsed = try #require(ProcessArguments.parse(data))
        #expect(parsed.environment == ["TAG=real"])
    }

    @Test func processTableFailureThrowsInsteadOfClaimingNoProcesses() throws {
        let inspector = SystemProcessInspector(kernel: FailingInspectionKernel())
        #expect(throws: LauncherError.io("process table unavailable")) {
            try inspector.processes(environmentContains: "WINEPREFIX", value: "/prefix")
        }
    }

    @Test(arguments: [InspectionFixture.Failure.unreadable, .malformed, .identityFailed, .invalidIdentity])
    private func incompleteSameUserInspectionThrows(failure: InspectionFixture.Failure) {
        let inspector = SystemProcessInspector(kernel: InspectionFixture(failure: failure))
        #expect(throws: ProcessInspectionError.incompleteScan) {
            try inspector.processes(environmentContains: "TAG", value: "match")
        }
    }

    @Test func goneReusedZombieAndOtherUserProcessesAreSkipped() throws {
        let inspector = SystemProcessInspector(kernel: InspectionFixture(failure: nil))
        let result = try inspector.processes(environmentContains: "TAG", value: "match")
        #expect(result.map(\.identity.pid) == [100])
        #expect(result.first?.arguments == ["sleep", "30"])
        #expect(result.first?.executablePath == "/bin/sleep")
        #expect(!inspector.isAlive(ProcessIdentity(pid: 104, startTime: 1_000_002)))
        #expect(try inspector.processes(environmentContains: "TA", value: "match").isEmpty)
    }

}

func procArguments(path: String = "/bin/sleep", arguments: [String] = ["sleep"], environment: [String] = [], argc: Int32? = nil) -> Data {
    var count = argc ?? Int32(arguments.count)
    var data = withUnsafeBytes(of: &count) { Data($0) }
    data.append(contentsOf: path.utf8); data.append(contentsOf: [0, 0, 0])
    for string in arguments + environment { data.append(contentsOf: string.utf8); data.append(0) }
    return data
}

private struct InspectionFixture: ProcessKernel {
    enum Failure: Sendable { case unreadable, malformed, identityFailed, invalidIdentity }
    let failure: Failure?
    func processes() -> [kinfo_proc] { (100...105).map { record(Int32($0)) } }
    func process(pid: Int32) -> kinfo_proc? { try? checkedProcess(pid: pid) }
    func checkedProcess(pid: Int32) throws -> kinfo_proc? {
        if pid == 102 { return nil } // Confirmed exit during inspection.
        if pid == 101 && failure == .identityFailed { throw ProcessInspectionError.incompleteScan }
        var info = record(pid)
        if pid == 103 { info.kp_proc.p_un.__p_starttime.tv_usec = 3 } // PID reused.
        return info
    }
    func arguments(pid: Int32) -> Data? {
        if pid == 102 { return nil } // Argument read raced with a confirmed exit.
        if pid == 101 && failure == .unreadable { return nil }
        if pid == 101 && failure == .malformed { return Data([0]) }
        if pid == 105 { return nil } // Unreadable process belonging to another user.
        return procArguments(arguments: ["sleep", "30"], environment: [pid == 101 && failure == nil ? "TAG=other" : "TAG=match"])
    }
    private func record(_ pid: Int32) -> kinfo_proc {
        var info = kinfo_proc(); info.kp_proc.p_pid = pid; info.kp_proc.p_stat = Int8(pid == 104 ? SZOMB : SRUN)
        info.kp_eproc.e_ucred.cr_uid = pid == 105 ? geteuid() &+ 1 : geteuid()
        info.kp_proc.p_un.__p_starttime.tv_sec = pid == 101 && failure == .invalidIdentity ? -1 : 1
        info.kp_proc.p_un.__p_starttime.tv_usec = 2
        return info
    }
}

private struct FailingInspectionKernel: ProcessKernel {
    func process(pid: Int32) -> kinfo_proc? { nil }
    func processes() throws -> [kinfo_proc] { throw LauncherError.io("process table unavailable") }
    func arguments(pid: Int32) -> Data? { nil }
}

private struct ByteInspectionFixture: ProcessKernel {
    let data: [Data]
    func processes() -> [kinfo_proc] { data.indices.map { record(Int32(100 + $0)) } }
    func process(pid: Int32) -> kinfo_proc? { record(pid) }
    func arguments(pid: Int32) -> Data? { data[Int(pid - 100)] }
    private func record(_ pid: Int32) -> kinfo_proc {
        var info = kinfo_proc(); info.kp_proc.p_pid = pid; info.kp_proc.p_stat = Int8(SRUN)
        info.kp_eproc.e_ucred.cr_uid = geteuid()
        info.kp_proc.p_un.__p_starttime.tv_sec = 1
        return info
    }
}
