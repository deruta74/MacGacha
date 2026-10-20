// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import LauncherCore
import DownloadEngine
import TestSupport

@main
struct CrashHarness {
    static func main() async {
        do {
            let args = CommandLine.arguments
            guard args.count == 4, let point = CrashPoint(rawValue: args[3]) else {
                throw LauncherError.io("Usage: CrashHarness <fixtureDir> <installRoot> <crashPoint>")
            }
            let fixtures = URL(fileURLWithPath: args[1], isDirectory: true)
            let root = URL(fileURLWithPath: args[2], isDirectory: true)
            let fs = try ContainedFileSystem(root: fixtures)
            let plan = try JSONDecoder().decode(InstallPlan.self,
                from: fs.readFile(at: SafeRelativePath("plan.json"), maxBytes: 64 << 20))
            let operation = try InstallOperation(plan: plan, installRoot: root,
                fetcher: ChunkFetcher(http: FileBackedHTTPClient(root: fixtures),
                    retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()),
                crashHooks: CrashHooks(at: point, action: { _exit(137) }))
            for try await _ in operation.run() {}
            // A missing hook must fail the parent test rather than masquerade as a crash.
            _exit(1)
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("CrashHarness: \(error)\n".utf8))
            _exit(2)
        }
    }
}
