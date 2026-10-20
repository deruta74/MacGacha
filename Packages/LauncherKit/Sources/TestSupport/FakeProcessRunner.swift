// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import LauncherCore

public final class FakeProcessRunner: ProcessRunner, Sendable {
    public struct Invocation: Sendable {
        public let executable: URL
        public let arguments: [String]
        public let environment: [String: String]
        public let currentDirectory: URL?
    }

    private let calls = Mutex([Invocation]())
    private let handler: @Sendable (Invocation) async throws -> ProcessResult

    public init(handler: @escaping @Sendable (Invocation) async throws -> ProcessResult = { _ in
        ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }) { self.handler = handler }

    public var invocations: [Invocation] { calls.withLock { $0 } }

    public func run(_ executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL?) async throws -> ProcessResult {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        let invocation = Invocation(executable: executable, arguments: arguments, environment: environment, currentDirectory: currentDirectory)
        calls.withLock { $0.append(invocation) }
        return try await handler(invocation)
    }
}
