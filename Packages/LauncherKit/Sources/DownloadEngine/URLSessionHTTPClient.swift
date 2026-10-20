import Foundation
import Synchronization
import LauncherCore

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .init(configuration: .ephemeral)) {
        self.session = session
    }

    public func get(_ url: URL, byteRangeFrom offset: Int64?) async throws
        -> (HTTPResponseHead, AsyncThrowingStream<Data, any Error>) {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        var request = URLRequest(url: url)
        if let offset { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let delegate = HTTPStreamDelegate(body: continuation)
        let task = session.dataTask(with: request)
        task.delegate = delegate
        delegate.attach(task)
        continuation.onTermination = { [weak delegate] termination in
            if case .cancelled = termination { delegate?.cancel() }
        }
        let head = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { delegate.start($0) }
        } onCancel: {
            delegate.cancel()
        }
        guard !Task.isCancelled else {
            delegate.cancel()
            throw LauncherError.cancelled
        }
        return (head, stream)
    }
}

private final class HTTPStreamDelegate: NSObject, URLSessionDataDelegate {
    private struct State {
        var task: URLSessionDataTask?
        var head: CheckedContinuation<HTTPResponseHead, any Error>?
        var body: AsyncThrowingStream<Data, any Error>.Continuation?
        var finished = false
        var terminalError: LauncherError?
    }

    private let state: Mutex<State>

    init(body: AsyncThrowingStream<Data, any Error>.Continuation) {
        state = Mutex(State(body: body))
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
        let continuation = state.withLock { $0.finished ? nil : $0.body }
        continuation?.yield(data)
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
            guard !state.finished else { return nil }
            state.finished = true
            state.terminalError = error ?? (state.head == nil ? nil : .transport("HTTP transfer ended before response headers"))
            let completed = state
            state.task = nil
            state.head = nil
            state.body = nil
            return completed
        }
        guard let completed else { return }
        // Resume and finish outside the lock: termination can call cancel() synchronously.
        if cancelTask { completed.task?.cancel() }
        if let head = completed.head {
            head.resume(throwing: completed.terminalError ?? .transport("Missing HTTP response"))
        }
        if let error = completed.terminalError {
            completed.body?.finish(throwing: error)
        } else {
            completed.body?.finish()
        }
    }
}
