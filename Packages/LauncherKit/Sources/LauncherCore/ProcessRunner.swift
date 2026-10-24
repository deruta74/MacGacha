// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
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

extension ProcessRunner {
    /// Cancels and joins the runner on timeout, including its process cleanup.
    /// The injected deadline keeps callers' timeout tests independent of pacing.
    package func run(_ executable: URL, arguments: [String], environment: [String: String],
        currentDirectory: URL?, timeout: Duration,
        timeoutWait: @escaping @Sendable (Duration) async throws -> Void) async throws -> ProcessResult {
        guard timeout > .zero else { throw LauncherError.io("Process timed out") }
        return try await withThrowingTaskGroup(of: ProcessResult.self) { group in
            group.addTask { try await self.run(executable, arguments: arguments, environment: environment, currentDirectory: currentDirectory) }
            group.addTask {
                try await timeoutWait(timeout)
                try Task.checkCancellation()
                throw LauncherError.io("Process timed out")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw LauncherError.cancelled }
            return result
        }
    }
}

public struct SystemProcessRunner: ProcessRunner {
    private let terminationGracePeriod: Duration
    private let pipeDrainGracePeriod: Duration

    public init(
        terminationGracePeriod: Duration = .seconds(3),
        pipeDrainGracePeriod: Duration = .seconds(2)
    ) {
        self.terminationGracePeriod = max(.zero, terminationGracePeriod)
        self.pipeDrainGracePeriod = max(.zero, pipeDrainGracePeriod)
    }

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
            process.terminationHandler = nil
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
        }
        let stdoutReader = try ProcessPipeReader(stdoutPipe.fileHandleForReading)
        defer { stdoutReader.close() }
        let stderrReader = try ProcessPipeReader(stderrPipe.fileHandleForReading)
        defer { stderrReader.close() }
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, supplied in supplied }
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let cancellation = ProcessCancellation(process: process, gracePeriod: terminationGracePeriod)
        return try await withTaskCancellationHandler {
            do {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { finished in
                        cancellation.didExit()
                        stdoutReader.close(after: pipeDrainGracePeriod)
                        stderrReader.close(after: pipeDrainGracePeriod)
                        continuation.resume(returning: finished.terminationStatus)
                    }
                    do {
                        try cancellation.launch()
                    } catch {
                        process.terminationHandler = nil
                        continuation.resume(throwing: error)
                    }
                }
                let stdout = try await stdoutReader.collectedData()
                let stderr = try await stderrReader.collectedData()
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                return ProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
            } catch {
                if Task.isCancelled { throw LauncherError.cancelled }
                throw error
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

// Nonblocking reads let the deadline close a pipe even when descendants keep
// its write end open. Each event reads a bounded amount so timers can run.
private final class ProcessPipeReader: Sendable {
    // Darwin FIONREAD (_IOR('f', 127, int)) is a C macro unavailable to Swift.
    private static let fionread: UInt = 0x4004_667f

    private struct State {
        var data = Data()
        var failure: LauncherError?
        var stopping = false
        var closed = false
        var waiter: CheckedContinuation<Data, any Error>?
    }

    private let handle: FileHandle
    private let queue: DispatchQueue
    private let source: any DispatchSourceRead
    private let state = Mutex(State())

    init(_ handle: FileHandle) throws {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            let error = errno
            try? handle.close()
            throw LauncherError.io("Configuring process output: \(String(cString: strerror(error)))")
        }
        self.handle = handle
        queue = DispatchQueue(label: "com.lo7ted.macgacha.process-output")
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { [weak self, handle] in
            try? handle.close()
            self?.didClose()
        }
        source.resume()
    }

    deinit {
        source.cancel()
    }

    func close(after gracePeriod: Duration) {
        queue.asyncAfter(deadline: dispatchDeadline(after: gracePeriod)) { [weak self] in
            guard let self else { return }
            guard !state.withLock({ $0.stopping }) else { return }
            var bufferedBytes: Int32 = 0
            guard ioctl(handle.fileDescriptor, Self.fionread, &bufferedBytes) == 0 else {
                let error = errno
                stop(LauncherError.io("Querying buffered process output: \(String(cString: strerror(error)))"))
                return
            }
            drain(byteLimit: Int(bufferedBytes), readLimit: .max)
            // Descendant output produced after this snapshot is intentionally discarded.
            stop()
        }
    }

    func close() {
        queue.async { self.stop() }
    }

    func collectedData() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<Data, LauncherError>? = state.withLock { state in
                if state.closed {
                    return state.failure.map { .failure($0) } ?? .success(state.data)
                }
                state.waiter = continuation
                return nil
            }
            if let result {
                continuation.resume(with: result.mapError { $0 as any Error })
            }
        }
    }

    private func drain(byteLimit: Int = .max, readLimit: Int = 16) {
        guard !state.withLock({ $0.stopping }) else { return }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var remainingBytes = byteLimit
        var remainingReads = readLimit
        while remainingBytes > 0 && remainingReads > 0 {
            remainingReads -= 1
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(handle.fileDescriptor, $0.baseAddress, min($0.count, remainingBytes))
            }
            if count > 0 {
                state.withLock { $0.data.append(contentsOf: buffer.prefix(count)) }
                remainingBytes -= count
            } else if count == 0 {
                stop()
                return
            } else {
                let error = errno
                if error == EINTR { continue }
                if error == EAGAIN || error == EWOULDBLOCK { return }
                stop(LauncherError.io("Reading process output: \(String(cString: strerror(error)))"))
                return
            }
        }
    }

    private func stop(_ failure: LauncherError? = nil) {
        let shouldCancel = state.withLock { state in
            guard !state.stopping else { return false }
            state.stopping = true
            state.failure = failure
            return true
        }
        if shouldCancel { source.cancel() }
    }

    private func didClose() {
        let (waiter, result) = state.withLock { state in
            state.closed = true
            let waiter = state.waiter
            state.waiter = nil
            let result: Result<Data, LauncherError> = state.failure.map { .failure($0) } ?? .success(state.data)
            return (waiter, result)
        }
        waiter?.resume(with: result.mapError { $0 as any Error })
    }
}

private func dispatchDeadline(after duration: Duration) -> DispatchTime {
    let components = duration.components
    let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
    return .now() + seconds
}

// Serialize launch with cancellation so cancellation immediately before run()
// cannot leave a newly launched process running.
private final class ProcessCancellation: Sendable {
    private struct State {
        var cancelled = false
        var launched = false
        var exited = false
        var escalation: DispatchWorkItem?
    }

    private let process: Process
    private let gracePeriod: Duration
    private let state = Mutex(State())

    init(process: Process, gracePeriod: Duration) {
        self.process = process
        self.gracePeriod = gracePeriod
    }

    func launch() throws {
        try state.withLock { state in
            guard !state.cancelled else { throw LauncherError.cancelled }
            do {
                try process.run()
            } catch {
                throw LauncherError.processLaunchFailure(error)
            }
            state.launched = true
        }
    }

    func didExit() {
        state.withLock { state in
            state.exited = true
            state.escalation?.cancel()
            state.escalation = nil
        }
    }

    func cancel() {
        state.withLock { state in
            state.cancelled = true
            guard state.launched, !state.exited, process.isRunning else { return }
            process.terminate()
            let escalation = DispatchWorkItem { [weak self] in self?.killIfRunning() }
            state.escalation = escalation
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: dispatchDeadline(after: gracePeriod),
                execute: escalation
            )
        }
    }

    private func killIfRunning() {
        state.withLock { state in
            guard state.launched, !state.exited, process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }
}
