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
        let entry = Array("WINEPREFIX=/some prefix".utf8)
        #expect(parsed.environmentContains(entry))
        #expect(ProcessArguments.environmentContains(entry, in: data))
    }

    @Test(arguments: [2, 8, 16]) func rewrittenWineArgumentsFindPrefixBeyondPadding(argc: Int32) throws {
        let data = wineArguments(argc: argc, padding: 32)
        let parsed = try #require(ProcessArguments.parse(data))
        #expect(parsed.executablePath == "/runtime/lib/wine/x86_64-unix/wine")
        #expect(parsed.arguments.first == "C:\\Games\\GenshinImpact.exe")
        #expect(parsed.environment == ["HOME=/synthetic/home", "WINEPREFIX=/synthetic/prefix", "LANG=en_US.UTF-8"])
        let entry = Array("WINEPREFIX=/synthetic/prefix".utf8)
        #expect(parsed.environmentContains(entry))
        #expect(ProcessArguments.environmentContains(entry, in: data))
        let matches = try SystemProcessInspector(kernel: ByteInspectionFixture(data: [data])).processes(
            environmentContains: "WINEPREFIX", value: "/synthetic/prefix", scope: runtimeScope)
        #expect(matches.map(\.identity.pid) == [100])
        #expect(matches.first?.arguments.first == "C:\\Games\\GenshinImpact.exe")
    }

    @Test(arguments: [false, true]) func liveWineDumpLayoutPreservesArgvAndEnvironment(cmd: Bool) throws {
        let image = cmd ? "C:\\windows\\system32\\cmd.exe" : "C:\\windows\\system32\\services.exe"
        var argc: Int32 = cmd ? 4 : 2
        var data = withUnsafeBytes(of: &argc) { Data($0) }
        data.append(contentsOf: "/runtime/lib/wine/x86_64-unix/wine".utf8)
        data.append(contentsOf: repeatElement(UInt8(0), count: 4))
        data.append(contentsOf: image.utf8)
        if cmd { data.append(contentsOf: "\0/c\0ping -n 30 127.0.0.1 >nul".utf8) }
        data.append(contentsOf: repeatElement(UInt8(0), count: 102))
        let environment = ["GST_PLUGIN_SCANNER=/runtime/scanner", "DYLD_FALLBACK_LIBRARY_PATH=/runtime/lib",
            "WINEPREFIX=/synthetic/prefix", "WINELOADERNOEXEC=1"]
        data.append(contentsOf: environment.joined(separator: "\0").utf8)
        data.append(contentsOf: repeatElement(UInt8(0), count: cmd ? 103 : 102))
        data.append(contentsOf: "ptr_munge=".utf8)
        data.append(contentsOf: repeatElement(UInt8(0), count: 19))
        data.append(contentsOf: "main_stack=".utf8)
        data.append(contentsOf: repeatElement(UInt8(0), count: 43))
        data.append(contentsOf: "executable_file=0x123\0dyld_file=/usr/lib/dyld\0executable_cdhash=abc\0executable_boothash=def\0WINEPREFIX=/auxiliary\0th_port=".utf8)
        data.append(contentsOf: repeatElement(UInt8(0), count: 6))
        data.append(contentsOf: "security_config=0x0".utf8) // Ignored auxiliary tail need not be a C string.
        let parsed = try #require(ProcessArguments.parse(data))
        #expect(parsed.arguments == (cmd ? [image, "/c", "ping -n 30 127.0.0.1 >nul", ""] : [image, ""]))
        #expect(parsed.environment == environment)
        let prefix = Array("WINEPREFIX=/synthetic/prefix".utf8), auxiliary = Array("WINEPREFIX=/auxiliary".utf8)
        #expect(parsed.environmentContains(prefix))
        #expect(ProcessArguments.environmentContains(prefix, in: data))
        #expect(!parsed.environmentContains(auxiliary))
        #expect(!ProcessArguments.environmentContains(auxiliary, in: data))
    }

    @Test func rewrittenWineArgcRunningPastBufferIsIncomplete() {
        let data = wineArguments(argc: 80, padding: 0)
        #expect(ProcessArguments.parse(data) == nil)
        #expect(!ProcessArguments.environmentContains(Array("WINEPREFIX=/synthetic/prefix".utf8), in: data))
        #expect(throws: ProcessInspectionError.incompleteScan) {
            try SystemProcessInspector(kernel: ByteInspectionFixture(data: [data])).processes(
                environmentContains: "WINEPREFIX", value: "/synthetic/prefix", scope: runtimeScope)
        }
    }

    @Test(arguments: ["/usr/bin/env", "/runtime/wine"])
    func untouchedAssignmentArgumentsAreNotEnvironment(path: String) throws {
        let data = procArguments(path: path, arguments: ["Game.exe", "WINEPREFIX=/session"], environment: ["HOME=/home"])
        let parsed = try #require(ProcessArguments.parse(data))
        #expect(parsed.arguments == ["Game.exe", "WINEPREFIX=/session"])
        let entry = Array("WINEPREFIX=/session".utf8)
        #expect(!parsed.environmentContains(entry))
        #expect(!ProcessArguments.environmentContains(entry, in: data))
        #expect(try SystemProcessInspector(kernel: ByteInspectionFixture(data: [data])).processes(
            environmentContains: "WINEPREFIX", value: "/session", scope: runtimeScope).isEmpty)
    }

    @Test(arguments: ["executable_path", "ptr_munge", "main_stack", "dyld_file"])
    func appleNamedEnvironmentEntriesDoNotTruncateEnvironment(key: String) throws {
        let entries = [key + "=/ordinary/value", "WINEPREFIX=/session"]
        let data = procArguments(path: "/runtime/wine", arguments: ["wine", "", "game.exe", ""], environment: entries)
        let parsed = try #require(ProcessArguments.parse(data))
        #expect(parsed.arguments == ["wine", "", "game.exe", ""])
        #expect(parsed.environment == entries)
        // Auxiliary names remain legal environment entries, but are reserved
        // from queries; they must never hide the ordinary entries after them.
        #expect(!parsed.environmentContains(Array(entries[0].utf8)))
        #expect(!ProcessArguments.environmentContains(Array(entries[0].utf8), in: data))
        #expect(parsed.environmentContains(Array(entries[1].utf8)))
        #expect(ProcessArguments.environmentContains(Array(entries[1].utf8), in: data))
        #expect(try SystemProcessInspector(kernel: ByteInspectionFixture(data: [data])).processes(
            environmentContains: "WINEPREFIX", value: "/session", scope: runtimeScope).map(\.identity.pid) == [100])
    }

    @Test(arguments: darwinAuxiliaryQueryKeys)
    func emptyEnvironmentAuxiliaryTailCannotMatchQueriedKeys(key: String) throws {
        var data = procArguments(path: "/usr/bin/python3", arguments: ["python3", "-c", "pass"], environment: [])
        data.append(contentsOf: repeatElement(UInt8(0), count: 16))
        // Like Darwin's env={} Python payload: empty environ/padding followed
        // by Apple's C-string auxiliary vector, with no WINEPREFIX entry.
        for name in darwinAuxiliaryQueryKeys { data.append(contentsOf: "\(name)=synthetic\0".utf8) }
        let parsed = try #require(ProcessArguments.parse(data))
        let prefix = Array("WINEPREFIX=/session".utf8), auxiliary = Array("\(key)=synthetic".utf8)
        #expect(!parsed.environmentContains(prefix))
        #expect(!ProcessArguments.environmentContains(prefix, in: data))
        #expect(!parsed.environmentContains(auxiliary))
        #expect(!ProcessArguments.environmentContains(auxiliary, in: data))
        let inspector = SystemProcessInspector(kernel: ByteInspectionFixture(data: [data]))
        #expect(try inspector.processes(environmentContains: "WINEPREFIX", value: "/session", scope: runtimeScope).isEmpty)
        #expect(try inspector.processes(environmentContains: key, value: "synthetic", scope: runtimeScope).isEmpty)
        // A reserved query must be rejected before any process-table access.
        #expect(try SystemProcessInspector(kernel: FailingInspectionKernel()).processes(
            environmentContains: key, value: "synthetic", scope: runtimeScope).isEmpty)
    }

    /// Lowercase names could collide with Darwin's auxiliary tail, so queries refuse them;
    /// the parsed environment itself keeps the entry.
    @Test func lowercaseQueryKeysAreRefused() throws {
        let data = procArguments(environment: ["ordinary_key=match", "WINEPREFIX=/synthetic/prefix"])
        let parsed = try #require(ProcessArguments.parse(data))
        #expect(parsed.environmentContains(Array("WINEPREFIX=/synthetic/prefix".utf8)))
        #expect(!ProcessArguments.environmentContains(Array("ordinary_key=match".utf8), in: data))
        #expect(try SystemProcessInspector(kernel: ByteInspectionFixture(data: [data])).processes(
            environmentContains: "ordinary_key", value: "match", scope: runtimeScope).isEmpty)
        #expect(try SystemProcessInspector(kernel: ByteInspectionFixture(data: [data])).processes(
            environmentContains: "WINEPREFIX", value: "/synthetic/prefix", scope: runtimeScope).map(\.identity.pid) == [100])
    }

    @Test(arguments: ["executable_path=/runtime/wine", "ptr_munge=0x123", "main_stack=0x456"])
    func appleVectorCannotSupplyMatchingEnvironment(marker: String) throws {
        var data = wineArguments(argc: 2, padding: 20)
        data.append(contentsOf: ("\0" + marker + "\0WINEPREFIX=/auxiliary\0\0").utf8)
        let parsed = try #require(ProcessArguments.parse(data))
        #expect(parsed.environment.contains("WINEPREFIX=/synthetic/prefix"))
        #expect(!parsed.environmentContains(Array("WINEPREFIX=/auxiliary".utf8)))
        #expect(!ProcessArguments.environmentContains(Array("WINEPREFIX=/auxiliary".utf8), in: data))
        #expect(!parsed.environment.contains(marker))
    }

    @Test func winePrefixEvidenceSurvivesTruncationAfterPadding() {
        var data = wineArguments(argc: 2, padding: 20)
        data.removeLast() // Keep the truncation inside environ, before its empty terminator.
        data.append(contentsOf: "OTHER=truncated".utf8)
        #expect(ProcessArguments.parse(data) == nil)
        #expect(ProcessArguments.environmentContains(Array("WINEPREFIX=/synthetic/prefix".utf8), in: data))
        let inspector = SystemProcessInspector(kernel: GroupInspectionFixture(candidateData: data))
        #expect(throws: ProcessInspectionError.incompleteScan) {
            try inspector.processes(environmentContains: "WINEPREFIX", value: "/synthetic/prefix", scope: ProcessInspectionScope(executableRoots: []))
        }
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
        data.append(contentsOf: "executable_path=/bin/sleep\0TAG=auxiliary\0".utf8)
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


private func wineArguments(argc: Int32, padding: Int) -> Data {
    var count = argc
    var data = withUnsafeBytes(of: &count) { Data($0) }
    data.append(contentsOf: "/runtime/lib/wine/x86_64-unix/wine\0\0\0C:\\Games\\GenshinImpact.exe\0".utf8)
    data.append(contentsOf: repeatElement(UInt8(0), count: padding))
    data.append(contentsOf: "HOME=/synthetic/home\0WINEPREFIX=/synthetic/prefix\0LANG=en_US.UTF-8\0\0".utf8)
    return data
}

private let darwinAuxiliaryQueryKeys = [
    "executable_path", "ptr_munge", "main_stack", "executable_file", "dyld_file",
    "executable_cdhash", "executable_boothash", "th_port", "security_config",
    "pfz", "stack_guard", "malloc_entropy", "arm64e_abi", "dyld_hw_tpro", "dyld_hw_tpro_pagers",
    // Unknown future auxiliary names are rejected by shape, not by this list.
    "future_darwin_key"
]
