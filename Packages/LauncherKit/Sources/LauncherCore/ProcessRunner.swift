import Dispatch
import Foundation
import Synchronization

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
        guard !Task.isCancelled else { throw LauncherError.cancelled }
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
        let cancellation = ProcessCancellation(process: process)
        return try await withTaskCancellationHandler {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            async let stdout = Self.readAll(stdoutPipe.fileHandleForReading)
            async let stderr = Self.readAll(stderrPipe.fileHandleForReading)
            let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try cancellation.launch()
                } catch {
                    process.terminationHandler = nil
                    // Readers may already be waiting; release them if launch fails.
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                    continuation.resume(throwing: error)
                }
            }
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            let result = try await ProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            return result
        } onCancel: {
            cancellation.cancel()
        }
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

// Serialize launch with cancellation so cancellation immediately before run()
// cannot leave a newly launched process running.
private final class ProcessCancellation: Sendable {
    private struct State {
        var cancelled = false
        var launched = false
    }

    private let process: Process
    private let state = Mutex(State())

    init(process: Process) {
        self.process = process
    }

    func launch() throws {
        try state.withLock { state in
            guard !state.cancelled else { throw LauncherError.cancelled }
            do {
                try process.run()
            } catch {
                throw LauncherError.io(error.localizedDescription)
            }
            state.launched = true
        }
    }

    func cancel() {
        let launched = state.withLock { state in
            state.cancelled = true
            return state.launched
        }
        if launched && process.isRunning {
            process.terminate()
        }
    }
}
