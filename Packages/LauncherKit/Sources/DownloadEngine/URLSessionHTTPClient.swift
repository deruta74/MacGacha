import Foundation
import Synchronization
import LauncherCore

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    private let highWaterMark: Int
    private let lowWaterMark: Int
    private let bufferObserver: (@Sendable (Int, Bool) -> Void)?

    public init(
        session: URLSession = .init(configuration: .ephemeral),
        highWaterMark: Int = 16 << 20,
        lowWaterMark: Int = 4 << 20
    ) {
        self.init(session: session, highWaterMark: highWaterMark, lowWaterMark: lowWaterMark, bufferObserver: nil)
    }

    init(session: URLSession, highWaterMark: Int, lowWaterMark: Int,
        bufferObserver: (@Sendable (Int, Bool) -> Void)?) {
        precondition(highWaterMark > 0 && lowWaterMark >= 0 && lowWaterMark < highWaterMark)
        self.session = session
        self.highWaterMark = highWaterMark
        self.lowWaterMark = lowWaterMark
        self.bufferObserver = bufferObserver
    }

    public func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        var request = URLRequest(url: url)
        if let offset { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let delegate = HTTPStreamDelegate(highWaterMark: highWaterMark, lowWaterMark: lowWaterMark,
            bufferObserver: bufferObserver)
        let task = session.dataTask(with: request)
        task.delegate = delegate
        delegate.attach(task)
        let body = HTTPBody(next: { try await delegate.next() }, onCancel: { delegate.cancel() })
        let head = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { delegate.start($0) }
        } onCancel: {
            delegate.cancel()
        }
        guard !Task.isCancelled else {
            delegate.cancel()
            throw LauncherError.cancelled
        }
        return (head, body)
    }
}

private final class HTTPStreamDelegate: NSObject, URLSessionDataDelegate {
    private struct State {
        var task: URLSessionDataTask?
        var head: CheckedContinuation<HTTPResponseHead, any Error>?
        var waiter: CheckedContinuation<Data?, any Error>?
        var pieces: [Data?] = []
        var readIndex = 0
        var bufferedBytes = 0
        var suspended = false
        var finished = false
        var terminalError: LauncherError?
    }

    private let state = Mutex(State())
    private let highWaterMark: Int
    private let lowWaterMark: Int
    private let bufferObserver: (@Sendable (Int, Bool) -> Void)?

    init(highWaterMark: Int, lowWaterMark: Int, bufferObserver: (@Sendable (Int, Bool) -> Void)?) {
        self.highWaterMark = highWaterMark
        self.lowWaterMark = lowWaterMark
        self.bufferObserver = bufferObserver
        super.init()
    }

    func attach(_ task: URLSessionDataTask) {
        state.withLock { $0.task = task }
    }

    func start(_ continuation: CheckedContinuation<HTTPResponseHead, any Error>) {
        let result: Result<URLSessionDataTask, LauncherError> = state.withLock { state in
            guard !state.finished, let task = state.task else {
                return .failure(state.terminalError ?? .transport("HTTP request already finished"))
            }
            state.head = continuation
            return .success(task)
        }
        switch result {
        case .success(let task): task.resume()
        case .failure(let error): continuation.resume(throwing: error)
        }
    }

    func cancel() {
        finish(.cancelled, cancelTask: true)
    }

    func next() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<Data?, LauncherError>? = state.withLock { state in
                defer { bufferObserver?(state.bufferedBytes, state.suspended) }
                if state.readIndex < state.pieces.count {
                    // Only consumed prefix slots are nil; readIndex points to a queued piece.
                    let data = state.pieces[state.readIndex]!
                    state.pieces[state.readIndex] = nil
                    state.readIndex += 1
                    state.bufferedBytes -= data.count
                    if state.readIndex == state.pieces.count {
                        state.pieces.removeAll(keepingCapacity: true)
                        state.readIndex = 0
                    } else if state.readIndex >= 64 {
                        state.pieces.removeFirst(state.readIndex)
                        state.readIndex = 0
                    }
                    if state.suspended && state.bufferedBytes <= lowWaterMark {
                        state.suspended = false
                        state.task?.resume()
                    }
                    return .success(data)
                }
                if state.finished {
                    return state.terminalError.map { .failure($0) } ?? .success(nil)
                }
                state.waiter = continuation
                return nil
            }
            if let result { continuation.resume(with: result.mapError { $0 as any Error }) }
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            finish(.transport("Expected an HTTP response"), cancelTask: true)
            completionHandler(.cancel)
            return
        }
        let continuation = state.withLock { state in
            guard !state.finished else { return nil as CheckedContinuation<HTTPResponseHead, any Error>? }
            let continuation = state.head
            state.head = nil
            return continuation
        }
        guard let continuation else {
            completionHandler(.cancel)
            return
        }
        continuation.resume(returning: HTTPResponseHead(response))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        let waiter = state.withLock { state -> CheckedContinuation<Data?, any Error>? in
            guard !state.finished else { return nil }
            defer { bufferObserver?(state.bufferedBytes, state.suspended) }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            // Accept the entire callback, including its possible watermark overshoot.
            // Waiting here would block every task sharing this session's delegate queue.
            state.pieces.append(data)
            state.bufferedBytes += data.count
            if state.bufferedBytes >= highWaterMark { suspend(&state) }
            return nil
        }
        waiter?.resume(returning: data)
    }

    private func suspend(_ state: inout State) {
        guard !state.suspended else { return }
        state.suspended = true
        state.task?.suspend()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let failure: LauncherError?
        if let error {
            let nsError = error as NSError
            failure = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
                ? .cancelled : .transport(error.localizedDescription)
        } else {
            failure = nil
        }
        finish(failure)
    }

    private func finish(_ error: LauncherError?, cancelTask: Bool = false) {
        let completed = state.withLock { state -> State? in
            guard !state.finished || cancelTask else { return nil }
            defer { bufferObserver?(state.bufferedBytes, state.suspended) }
            state.finished = true
            state.terminalError = error ?? (state.head == nil ? nil : .transport("HTTP transfer ended before response headers"))
            if cancelTask {
                state.pieces.removeAll()
                state.readIndex = 0
                state.bufferedBytes = 0
            }
            let completed = state
            state.task = nil
            state.head = nil
            state.waiter = nil
            state.suspended = false
            return completed
        }
        guard let completed else { return }
        // Complete outside the lock; native cancellation can schedule delegate callbacks.
        if cancelTask { completed.task?.cancel() }
        if let head = completed.head {
            head.resume(throwing: completed.terminalError ?? .transport("Missing HTTP response"))
        }
        if let waiter = completed.waiter {
            if let error = completed.terminalError { waiter.resume(throwing: error) }
            else { waiter.resume(returning: nil) }
        }
    }
}
