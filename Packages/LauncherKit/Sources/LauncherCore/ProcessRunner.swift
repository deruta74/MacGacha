import Dispatch
import Foundation

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol ProcessRunner: Sendable {
    func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?
    ) async throws -> ProcessResult
}

public struct SystemProcessRunner: ProcessRunner {
    public init() {}

    public func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?
    ) async throws -> ProcessResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        defer {
            try? stdoutPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForWriting.close()
        }
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, supplied in supplied }
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            throw LauncherError.io(error.localizedDescription)
        }

        async let stdout = Self.readAll(stdoutPipe.fileHandleForReading)
        async let stderr = Self.readAll(stderrPipe.fileHandleForReading)
        let exitCode: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus)
            }
        }
        return try await ProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }

    private static func readAll(_ handle: FileHandle) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try handle.readToEnd() ?? Data())
                } catch {
                    continuation.resume(throwing: LauncherError.io(error.localizedDescription))
                }
            }
        }
    }
}
