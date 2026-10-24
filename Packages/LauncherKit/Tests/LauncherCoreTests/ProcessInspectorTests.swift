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
            #expect(UUID(uuidString: try SystemProcessInspector.bootSessionUUID()) != nil)
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
        let result = try inspector.processes(environmentContains: "WINEPREFIX", value: "/prefix", scope: runtimeScope)
        #expect(result.map(\.identity.pid) == [101])
        #expect(result.first?.arguments == ["�ine", "game.exe"])
        #expect(result.first?.executablePath == "�bin/sleep")
    }

    @Test func processEnvironmentMatchingUsesExactBytes() throws {
        var invalidValue = procArguments()
        invalidValue.append(contentsOf: Array("TAG=".utf8) + [0xff, 0])
        let inspector = SystemProcessInspector(kernel: ByteInspectionFixture(data: [invalidValue]))
        // Lossy decoding must not turn arbitrary bytes into a matching UTF-8 value.
        #expect(try inspector.processes(environmentContains: "TAG", value: "�", scope: runtimeScope).isEmpty)
    }

    @Test func truncatedNonUTF8EnvironmentStillMakesScanIncomplete() {
        var truncated = procArguments(environment: ["WINEPREFIX=/prefix"])
        truncated.append(contentsOf: Array("OTHER=".utf8) + [0xff])
        let inspector = SystemProcessInspector(kernel: ByteInspectionFixture(data: [truncated]))
        #expect(ProcessArguments.parse(truncated) == nil)
        #expect(throws: ProcessInspectionError.incompleteScan) {
            try inspector.processes(environmentContains: "WINEPREFIX", value: "/prefix", scope: runtimeScope)
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
            try inspector.processes(environmentContains: "WINEPREFIX", value: "/prefix", scope: runtimeScope)
        }
    }

    @Test(arguments: [InspectionFixture.Failure.unreadable, .malformed, .identityFailed, .invalidIdentity])
    private func unreadableRuntimeProcessMakesInspectionIncomplete(failure: InspectionFixture.Failure) {
        let inspector = SystemProcessInspector(kernel: InspectionFixture(failure: failure))
        #expect(throws: ProcessInspectionError.incompleteScan) {
            try inspector.processes(environmentContains: "TAG", value: "match", scope: runtimeScope)
        }
    }

    @Test(arguments: [InspectionFixture.Failure.unreadable, .malformed, .identityFailed, .invalidIdentity])
    private func unreadableForeignProcessIsSkipped(failure: InspectionFixture.Failure) throws {
        let inspector = SystemProcessInspector(kernel: InspectionFixture(failure: failure, path: "/foreign/bin/worker"))
        let result = try inspector.processes(environmentContains: "TAG", value: "match", scope: runtimeScope)
        #expect(result.map(\.identity.pid) == [100])
    }

    @Test func exactRecordedLeaderKeepsGroupValidWithoutSessionStartTime() {
        let inspector = SystemProcessInspector(kernel: GroupInspectionFixture())
        let scope = ProcessInspectionScope(executableRoots: [], processGroupIDs: [700],
            identities: [ProcessIdentity(pid: 700, startTime: 1_500_000)], bootSessionUUID: "boot")
        #expect(throws: ProcessInspectionError.incompleteScan) {
            try inspector.processes(environmentContains: "WINEPREFIX", value: "/prefix", scope: scope)
        }
    }

    @Test func unreadableGameProcessMakesInspectionIncomplete() {
        let inspector = SystemProcessInspector(kernel: InspectionFixture(failure: .unreadable, path: "/games/hsr/Game.exe"))
        let scope = ProcessInspectionScope(executableRoots: [URL(fileURLWithPath: "/games/hsr")])
        #expect(throws: ProcessInspectionError.incompleteScan) {
            try inspector.processes(environmentContains: "TAG", value: "match", scope: scope)
        }
    }

    @Test func unreadableForeignSiblingRootIsSkipped() throws {
        let inspector = SystemProcessInspector(kernel: InspectionFixture(failure: .unreadable, path: "/runtime-other/bin/worker"))
        #expect(try inspector.processes(environmentContains: "TAG", value: "match", scope: runtimeScope).map(\.identity.pid) == [100])
    }

    @Test func vanishedExecutablePathIsGoneEvenForOwnedGroup() throws {
        let inspector = SystemProcessInspector(kernel: InspectionFixture(failure: .unreadable, path: nil))
        let scope = ProcessInspectionScope(executableRoots: [], processGroupIDs: [700], bootSessionUUID: "boot", sessionStartTime: 1_000_000)
        #expect(try inspector.processes(environmentContains: "TAG", value: "match", scope: scope).map(\.identity.pid) == [100])
    }

    @Test func unavailableExecutablePathIsUncertainEvenWithoutRecordedIdentity() throws {
        let inspector = SystemProcessInspector(kernel: InspectionFixture(failure: .unreadable, pathFailure: true))
        #expect(throws: ProcessInspectionError.incompleteScan) {
            try inspector.processes(environmentContains: "TAG", value: "match", scope: runtimeScope)
        }
        let ownedScope = ProcessInspectionScope(executableRoots: [], processGroupIDs: [700])
        #expect(throws: ProcessInspectionError.incompleteScan) {
            try inspector.processes(environmentContains: "TAG", value: "match", scope: ownedScope)
        }
    }

    @Test func recordedIdentityMakesUnreadableForeignPathUncertain() {
        let inspector = SystemProcessInspector(kernel: GroupInspectionFixture())
        let scope = ProcessInspectionScope(executableRoots: [], identities: [ProcessIdentity(pid: 101, startTime: 2_000_000)])
        #expect(throws: ProcessInspectionError.incompleteScan) {
            try inspector.processes(environmentContains: "WINEPREFIX", value: "/prefix", scope: scope)
        }
    }

    @Test func recordedIdentityEvidenceSurvivesInvalidRecheckedIdentity() {
        let inspector = SystemProcessInspector(kernel: GroupInspectionFixture(candidateCurrentIdentityInvalid: true))
        let scope = ProcessInspectionScope(executableRoots: [], identities: [ProcessIdentity(pid: 101, startTime: 2_000_000)])
        #expect(throws: ProcessInspectionError.incompleteScan) {
            try inspector.processes(environmentContains: "WINEPREFIX", value: "/prefix", scope: scope)
        }
    }

    @Test func reusedRecordedPIDDoesNotMatchForeignProcessIdentity() throws {
        let inspector = SystemProcessInspector(kernel: GroupInspectionFixture())
        let scope = ProcessInspectionScope(executableRoots: [], identities: [ProcessIdentity(pid: 101, startTime: 1_000_000)])
        #expect(try inspector.processes(environmentContains: "WINEPREFIX", value: "/prefix", scope: scope).isEmpty)
    }

    @Test func replacementLeaderBornAfterSessionDoesNotValidateStaleGroup() throws {
        let inspector = SystemProcessInspector(kernel: GroupInspectionFixture(leaderStartTime: 2_000_000))
        let scope = ProcessInspectionScope(executableRoots: [], processGroupIDs: [700],
            identities: [ProcessIdentity(pid: 700, startTime: 1_500_000)],
            bootSessionUUID: "boot", sessionStartTime: 1_000_000)
        #expect(try inspector.processes(environmentContains: "WINEPREFIX", value: "/prefix", scope: scope).isEmpty)
    }

    @Test func reusedLeaderlessGroupWithoutRecordedSurvivorDoesNotValidateClaim() throws {
        let inspector = SystemProcessInspector(kernel: GroupInspectionFixture(leaderStartTime: nil))
        let scope = ProcessInspectionScope(executableRoots: [], processGroupIDs: [700],
            identities: [ProcessIdentity(pid: 700, startTime: 1_500_000)],
            bootSessionUUID: "boot", sessionStartTime: 1_000_000)
        #expect(try inspector.processes(environmentContains: "WINEPREFIX", value: "/prefix", scope: scope).isEmpty)
    }

    @Test(arguments: [RecordedMemberChange.reused, .movedGroup, .zombie])
    private func changedRecordedMemberCannotValidateLeaderlessGroup(change: RecordedMemberChange) throws {
        let inspector = SystemProcessInspector(kernel: GroupInspectionFixture(
            leaderStartTime: nil, hasMember: true, memberChange: change))
        let scope = ProcessInspectionScope(executableRoots: [], processGroupIDs: [700],
            identities: [ProcessIdentity(pid: 102, startTime: 1_500_000)], bootSessionUUID: "boot")
        #expect(try inspector.processes(environmentContains: "WINEPREFIX", value: "/prefix", scope: scope).isEmpty)
    }

    @Test func zombieRecordedLeaderCannotValidateGroupClaim() throws {
        let inspector = SystemProcessInspector(kernel: GroupInspectionFixture(leaderIsZombie: true))
        let scope = ProcessInspectionScope(executableRoots: [], processGroupIDs: [700],
            identities: [ProcessIdentity(pid: 700, startTime: 1_500_000)], bootSessionUUID: "boot")
        #expect(try inspector.processes(environmentContains: "WINEPREFIX", value: "/prefix", scope: scope).isEmpty)
    }

    @Test func verifiedSurvivingMemberKeepsLeaderlessGroupValid() {
        let inspector = SystemProcessInspector(kernel: GroupInspectionFixture(leaderStartTime: nil, hasMember: true))
        let scope = ProcessInspectionScope(executableRoots: [], processGroupIDs: [700], identities: [ProcessIdentity(pid: 102, startTime: 1_500_000)], bootSessionUUID: "boot", sessionStartTime: 1_000_000)
        #expect(throws: ProcessInspectionError.incompleteScan) {
            try inspector.processes(environmentContains: "WINEPREFIX", value: "/prefix", scope: scope)
        }
    }

    @Test func staleBootGroupDoesNotMakeForeignProcessUncertain() throws {
        let inspector = SystemProcessInspector(kernel: GroupInspectionFixture())
        let scope = ProcessInspectionScope(executableRoots: [], processGroupIDs: [700],
            identities: [ProcessIdentity(pid: 700, startTime: 1_500_000)], bootSessionUUID: "previous-boot", sessionStartTime: 1_000_000)
        #expect(try inspector.processes(environmentContains: "WINEPREFIX", value: "/prefix", scope: scope).isEmpty)
    }

    @Test func sameBootGroupWithLeaderPredatingSessionIsStale() throws {
        let inspector = SystemProcessInspector(kernel: GroupInspectionFixture(leaderStartTime: 500_000))
        let scope = ProcessInspectionScope(executableRoots: [], processGroupIDs: [700], bootSessionUUID: "boot", sessionStartTime: 1_000_000)
        #expect(try inspector.processes(environmentContains: "WINEPREFIX", value: "/prefix", scope: scope).isEmpty)
    }

    @Test func verifiedSurvivingMemberKeepsGroupClaimValid() {
        let inspector = SystemProcessInspector(kernel: GroupInspectionFixture(leaderStartTime: 500_000, hasMember: true))
        let scope = ProcessInspectionScope(executableRoots: [], processGroupIDs: [700], identities: [ProcessIdentity(pid: 102, startTime: 1_500_000)], bootSessionUUID: "boot", sessionStartTime: 1_000_000)
        #expect(throws: ProcessInspectionError.incompleteScan) {
            try inspector.processes(environmentContains: "WINEPREFIX", value: "/prefix", scope: scope)
        }
    }

    @Test func unreadableLeaderLifetimeDoesNotValidateGroupClaim() throws {
        let inspector = SystemProcessInspector(kernel: GroupInspectionFixture(leaderIdentityFails: true))
        let scope = ProcessInspectionScope(executableRoots: [], processGroupIDs: [700], bootSessionUUID: "boot", sessionStartTime: 1_000_000)
        #expect(try inspector.processes(environmentContains: "WINEPREFIX", value: "/prefix", scope: scope).isEmpty)
    }

    @Test func groupWithoutProvenanceDoesNotClassifyForeignProcessAsOurs() throws {
        let inspector = SystemProcessInspector(kernel: GroupInspectionFixture())
        #expect(try inspector.processes(environmentContains: "WINEPREFIX", value: "/prefix", scope: ProcessInspectionScope(executableRoots: [], processGroupIDs: [700])).isEmpty)
    }

    @Test func readablePrefixMatchRemainsUncertainWhenIdentityQueryFails() {
        let inspector = SystemProcessInspector(kernel: GroupInspectionFixture(candidateData: procArguments(environment: ["WINEPREFIX=/prefix"]), identityQueryFails: true))
        #expect(throws: ProcessInspectionError.incompleteScan) {
            try inspector.processes(environmentContains: "WINEPREFIX", value: "/prefix", scope: ProcessInspectionScope(executableRoots: []))
        }
    }

    @Test func readablePrefixBeforeTruncationRemainsUncertain() {
        var data = procArguments(environment: ["WINEPREFIX=/prefix"])
        data.append(contentsOf: "OTHER=truncated".utf8)
        let inspector = SystemProcessInspector(kernel: GroupInspectionFixture(candidateData: data))
        #expect(throws: ProcessInspectionError.incompleteScan) {
            try inspector.processes(environmentContains: "WINEPREFIX", value: "/prefix", scope: ProcessInspectionScope(executableRoots: []))
        }
    }

    @Test func scopeResolvesSymlinkedRootsAndExecutablePaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("actual/bin"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("wine".utf8).write(to: root.appendingPathComponent("actual/bin/wine"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: root.appendingPathComponent("actual"))
        let inspector = SystemProcessInspector(kernel: InspectionFixture(failure: .unreadable, path: root.appendingPathComponent("alias/bin/wine").path))
        let scope = ProcessInspectionScope(executableRoots: [root.appendingPathComponent("actual")])
        #expect(throws: ProcessInspectionError.incompleteScan) {
            try inspector.processes(environmentContains: "TAG", value: "match", scope: scope)
        }
        let reverseInspector = SystemProcessInspector(kernel: InspectionFixture(failure: .unreadable, path: root.appendingPathComponent("actual/bin/wine").path))
        #expect(throws: ProcessInspectionError.incompleteScan) {
            try reverseInspector.processes(environmentContains: "TAG", value: "match", scope: ProcessInspectionScope(executableRoots: [root.appendingPathComponent("alias")]))
        }
    }

    @Test func goneReusedZombieAndOtherUserProcessesAreSkipped() throws {
        let inspector = SystemProcessInspector(kernel: InspectionFixture(failure: nil))
        let result = try inspector.processes(environmentContains: "TAG", value: "match", scope: runtimeScope)
        #expect(result.map(\.identity.pid) == [100])
        #expect(result.first?.arguments == ["sleep", "30"])
        #expect(result.first?.executablePath == "/bin/sleep")
        #expect(!inspector.isAlive(ProcessIdentity(pid: 104, startTime: 1_000_002)))
        #expect(try inspector.processes(environmentContains: "TA", value: "match", scope: runtimeScope).isEmpty)
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
    func bootSessionUUID() throws -> String { "boot" }
    var path: String? = "/runtime/bin/wine"
    var pathFailure = false
    func executablePath(pid: Int32) throws -> String? {
        if pathFailure { throw ProcessInspectionError.incompleteScan }
        return path
    }
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
        return procArguments(arguments: ["sleep", "30"], environment: [pid == 101 ? "TAG=other" : "TAG=match"])
    }
    private func record(_ pid: Int32) -> kinfo_proc {
        var info = kinfo_proc(); info.kp_proc.p_pid = pid; info.kp_proc.p_stat = Int8(pid == 104 ? SZOMB : SRUN)
        info.kp_eproc.e_pgid = pid == 101 ? 700 : pid
        info.kp_eproc.e_ucred.cr_uid = pid == 105 ? geteuid() &+ 1 : geteuid()
        info.kp_proc.p_un.__p_starttime.tv_sec = pid == 101 && failure == .invalidIdentity ? -1 : 1
        info.kp_proc.p_un.__p_starttime.tv_usec = 2
        return info
    }
}

private let runtimeScope = ProcessInspectionScope(executableRoots: [URL(fileURLWithPath: "/runtime")])

private struct FailingInspectionKernel: ProcessKernel {
    func executablePath(pid: Int32) throws -> String? { nil }
    func process(pid: Int32) -> kinfo_proc? { nil }
    func processes() throws -> [kinfo_proc] { throw LauncherError.io("process table unavailable") }
    func arguments(pid: Int32) -> Data? { nil }
}

private struct ByteInspectionFixture: ProcessKernel {
    func executablePath(pid: Int32) throws -> String? { "/runtime/bin/wine" }
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

private enum RecordedMemberChange: Sendable { case reused, movedGroup, zombie }

private struct GroupInspectionFixture: ProcessKernel {
    var leaderStartTime: UInt64? = 1_500_000
    var hasMember = false
    var memberChange: RecordedMemberChange? = nil
    var leaderIsZombie = false
    var candidateData: Data? = nil
    var identityQueryFails = false
    var leaderIdentityFails = false
    var candidateCurrentIdentityInvalid = false
    func bootSessionUUID() throws -> String { "boot" }
    func executablePath(pid: Int32) throws -> String? { "/foreign/bin/worker" }
    func process(pid: Int32) -> kinfo_proc? { try? checkedProcess(pid: pid) }
    func processes() -> [kinfo_proc] {
        [record(101, startTime: 2_000_000)]
            + (leaderStartTime.map { [record(700, startTime: $0)] } ?? [])
            + (hasMember ? [record(102, startTime: 1_500_000)] : [])
    }
    func checkedProcess(pid: Int32) throws -> kinfo_proc? {
        if pid == 101 && identityQueryFails { throw ProcessInspectionError.incompleteScan }
        var current = processes().first { $0.kp_proc.p_pid == pid }
        if pid == 101 && candidateCurrentIdentityInvalid { current?.kp_proc.p_un.__p_starttime.tv_sec = -1 }
        if pid == 102 {
            switch memberChange {
            case .reused: current?.kp_proc.p_un.__p_starttime.tv_usec += 1
            case .movedGroup: current?.kp_eproc.e_pgid = 701
            case .zombie: current?.kp_proc.p_stat = Int8(SZOMB)
            case nil: break
            }
        }
        return current
    }
    func arguments(pid: Int32) -> Data? {
        pid == 101 ? candidateData : procArguments(environment: ["WINEPREFIX=/other-prefix"])
    }
    private func record(_ pid: Int32, startTime: UInt64) -> kinfo_proc {
        var info = kinfo_proc(); info.kp_proc.p_pid = pid; info.kp_proc.p_stat = Int8(SRUN)
        info.kp_eproc.e_ucred.cr_uid = geteuid(); info.kp_eproc.e_pgid = 700
        if pid == 700 && leaderIsZombie { info.kp_proc.p_stat = Int8(SZOMB) }
        info.kp_proc.p_un.__p_starttime.tv_sec = pid == 700 && leaderIdentityFails ? -1 : Int(startTime / 1_000_000)
        info.kp_proc.p_un.__p_starttime.tv_usec = Int32(startTime % 1_000_000)
        return info
    }
}
