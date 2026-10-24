// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation

public enum RosettaStatus: Sendable, Equatable { case installed, missing, unknown }

public protocol RosettaProbing: Sendable {
    func status() async -> RosettaStatus
}

public struct SystemRosettaProbe: RosettaProbing {
    private let runner: any ProcessRunner
    private let timeout: Duration
    private let timeoutWait: @Sendable (Duration) async throws -> Void

    public init(runner: any ProcessRunner = SystemProcessRunner(), timeout: Duration = .seconds(5),
        timeoutWait: @escaping @Sendable (Duration) async throws -> Void = { try await ContinuousClock().sleep(for: $0) }) {
        self.runner = runner; self.timeout = timeout; self.timeoutWait = timeoutWait
    }

    public func status() async -> RosettaStatus {
        do {
            // ProcessRunner's synchronous launch must also leave the cooperative pool.
            let result = try await BlockingIO.run {
                try await runner.run(URL(fileURLWithPath: "/usr/bin/arch"), arguments: ["-x86_64", "/usr/bin/true"],
                    environment: ["LC_ALL": "C"], currentDirectory: nil, timeout: timeout, timeoutWait: timeoutWait)
            }
            if result.exitCode == 0 { return .installed }
            return Self.architectureFailure(String(decoding: result.stderr, as: UTF8.self)) ? .missing : .unknown
        } catch {
            let message = String(describing: error)
            let error = error as NSError
            if error.domain == NSPOSIXErrorDomain, [Int(EBADARCH), Int(ENOEXEC)].contains(error.code) { return .missing }
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
                underlying.domain == NSPOSIXErrorDomain, [Int(EBADARCH), Int(ENOEXEC)].contains(underlying.code) { return .missing }
            return Self.architectureFailure(message) ? .missing : .unknown
        }
    }

    private static func architectureFailure(_ message: String) -> Bool {
        let message = message.lowercased()
        return message.contains("bad cpu type") || message.contains("exec format error")
    }
}
