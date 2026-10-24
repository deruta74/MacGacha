// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Testing
import TestSupport
@testable import LauncherCore

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MACGACHA_LIVE_WINE"]?.isEmpty == false))
struct LiveWineInspectionTests {
    @Test(.timeLimit(.minutes(2))) func inspectorFindsRewrittenCmdInIsolatedPrefix() async throws {
        try await BlockingIO.run {
            let wine = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MACGACHA_LIVE_WINE"]))
            let wineserver = wine.deletingLastPathComponent().appendingPathComponent("wineserver")
            let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url)
            for name in ["prefix", "home", "tmp"] { try fs.createDirectory(at: SafeRelativePath(name)) }
            let prefix = temp.url.appendingPathComponent("prefix")
            let environment = ["WINEPREFIX": prefix.path, "WINEDEBUG": "-all", "WINEARCH": "win64",
                "HOME": temp.url.appendingPathComponent("home").path, "TMPDIR": temp.url.appendingPathComponent("tmp").path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "WINEDLLOVERRIDES": "winemenubuilder.exe=d;mscoree=d;mshtml=d"]
            let output = temp.url.appendingPathComponent("probe.log")
            let inspector = SystemProcessInspector()
            let scope = ProcessInspectionScope(executableRoots: [wine.deletingLastPathComponent(), prefix])
            var child: ProcessIdentity?
            var observed: [ProcessIdentity] = []
            defer { if let child { killAndReap(child.pid) } }
            var probeError: (any Error)?
            do {
                // Runtime wrappers can suppress optional installer dialogs only
                // for an explicit wineboot route, as PrefixManager also uses.
                let bootstrap = try await SystemProcessRunner().run(wine, arguments: ["wineboot", "--init"],
                    environment: environment, currentDirectory: temp.url, timeout: .seconds(60),
                    timeoutWait: { try await ContinuousClock().sleep(for: $0) })
                guard bootstrap.exitCode == 0 else {
                    throw LauncherError.processFailed(executable: "wineboot", exitCode: bootstrap.exitCode,
                        stderrTail: String(decoding: bootstrap.stderr.suffix(4096), as: UTF8.self))
                }
                child = try SystemProcessSpawner().spawn(wine, arguments: ["cmd", "/c", "ping -n 120 127.0.0.1"],
                    environment: environment, currentDirectory: temp.url, outputFile: output)
                // This gated test waits for the property it exercises, rather
                // than cmd redirection or a translated Z: path. Elapsed time
                // only bounds failure; it never declares the process ready.
                let processes = try await waitForLiveCmd(inspector, prefix: prefix, scope: scope, clock: ContinuousClock())
                observed = processes.map(\.identity)
                try #require(processes.contains(where: isLiveCmd))
            } catch { probeError = error }

            // Wine's daemon is not our waitpid child. Ask this isolated prefix's
            // server to kill its clients and join its exit; kill/reap our direct
            // spawn and its group even when the probe or cleanup command fails.
            let remaining = try? inspector.processes(environmentContains: "WINEPREFIX", value: prefix.path, scope: scope)
            observed = Array(Set(observed + (remaining?.map(\.identity) ?? [])))
            let cleanupError = await stopLiveWine(wineserver, environment: environment, observed: observed)
            if let owned = child { killAndReap(owned.pid); child = nil }
            if let cleanupError { throw cleanupError }
            if let probeError { throw probeError }
            #expect(try inspector.processes(environmentContains: "WINEPREFIX", value: prefix.path, scope: scope).isEmpty)
        }
    }
}

private func isLiveCmd(_ process: InspectedProcess) -> Bool {
    process.arguments.first?.replacingOccurrences(of: "\\", with: "/")
        .split(separator: "/").last?.lowercased() == "cmd.exe"
}

private func waitForLiveCmd(_ inspector: SystemProcessInspector, prefix: URL, scope: ProcessInspectionScope,
    clock: some Clock<Duration>) async throws -> [InspectedProcess] {
    let deadline = clock.now.advanced(by: .seconds(20))
    while clock.now < deadline {
        try Task.checkCancellation()
        do {
            let processes = try inspector.processes(environmentContains: "WINEPREFIX", value: prefix.path, scope: scope)
            if processes.contains(where: isLiveCmd) { return processes }
        } catch ProcessInspectionError.incompleteScan { /* Startup can race process-table reads. */ }
        try await clock.sleep(for: .milliseconds(100))
    }
    throw LauncherError.io("The real inspector did not discover cmd.exe within the live probe's deadline")
}

private func stopLiveWine(_ wineserver: URL, environment: [String: String], observed: [ProcessIdentity]) async -> (any Error)? {
    // Cleanup must survive test cancellation, but is joined and bounded.
    await Task.detached {
        do {
            try await BlockingIO.run {
                let runner = SystemProcessRunner()
                var cleanupError: (any Error)?
                for argument in ["-k", "-w"] {
                    do {
                        let result = try await runner.run(wineserver, arguments: [argument], environment: environment,
                            currentDirectory: nil, timeout: .seconds(10), timeoutWait: { try await ContinuousClock().sleep(for: $0) })
                        guard result.exitCode == 0 else {
                            throw LauncherError.processFailed(executable: "wineserver", exitCode: result.exitCode, stderrTail: "")
                        }
                    } catch { cleanupError = cleanupError ?? error }
                }
                // Also cover a failed server command. Never signal a reused PID.
                let inspector = SystemProcessInspector()
                for identity in observed where inspector.isAlive(identity) { _ = kill(identity.pid, SIGKILL) }
                try await waitUntil { observed.allSatisfy { !inspector.isAlive($0) } }
                if let cleanupError { throw cleanupError }
            }
            return nil
        } catch { return error }
    }.value
}
