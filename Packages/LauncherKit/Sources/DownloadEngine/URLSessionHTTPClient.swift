// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import LauncherCore

/// Create once and share; call invalidate() when done.
public struct URLSessionHTTPClient: HTTPClient {
    private var rateLimiter: DownloadRateLimiter?
    private let sessions: [URLSession]
    private let requestTimeout: TimeInterval
    private var timerFactory: @Sendable () -> any HTTPRequestTimer = { DispatchHTTPRequestTimer() }
    private var taskTransitionObserver: (@Sendable (URLSessionTask, URLSessionTask.State) -> Void)?
    private var callbackObserver: (@Sendable (URLSessionTask, Int, Duration) -> Void)?
    private let lifecycle: HTTPSessionLifecycle
    private let highWaterMark: Int
    private let lowWaterMark: Int
    private let bufferObserver: (@Sendable (Int, Bool) -> Void)?
    private let redirectPolicy: @Sendable (URL) -> Bool

    public init(
        session: URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            return URLSession(configuration: configuration)
        }(),
        highWaterMark: Int = 16 << 20,
        lowWaterMark: Int = 4 << 20,
        redirectPolicy: @escaping @Sendable (URL) -> Bool = { _ in true }
    ) {
        self.init(session: session, highWaterMark: highWaterMark, lowWaterMark: lowWaterMark, bufferObserver: nil, redirectPolicy: redirectPolicy)
    }

    /// Independent serial delegate queues and connection pools prevent all
    /// chunk streams (including HTTP/2) from sharing one session's executor.
    /// Configuration is copied by URLSession; stream watermarks remain per task.
    public init(configuration: URLSessionConfiguration, sessionCount: Int = 8,
        highWaterMark: Int = 16 << 20, lowWaterMark: Int = 4 << 20,
        redirectPolicy: @escaping @Sendable (URL) -> Bool = { _ in true }) {
        precondition(sessionCount > 0 && highWaterMark > 0 && lowWaterMark >= 0 && lowWaterMark < highWaterMark)
        sessions = (0..<sessionCount).map { index in
            let queue = OperationQueue()
            queue.name = "MacGacha.HTTP.\(index)"; queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .userInitiated
            return URLSession(configuration: configuration, delegate: nil, delegateQueue: queue)
        }
        requestTimeout = configuration.timeoutIntervalForRequest
        lifecycle = HTTPSessionLifecycle(); self.highWaterMark = highWaterMark; self.lowWaterMark = lowWaterMark
        bufferObserver = nil; self.redirectPolicy = redirectPolicy
    }

    /// Copies share producer admission across independent session pools. An
    /// unlimited bucket retains ordinary concurrent, watermarked reception.
    public func limitingReception(using limiter: DownloadRateLimiter) -> Self {
        var copy = self; copy.rateLimiter = limiter; return copy
    }

    public func invalidate() {
        let first = lifecycle.invalidated.withLock { invalidated in
            guard !invalidated else { return false }
            invalidated = true
            return true
        }
        if first { for session in sessions { session.invalidateAndCancel() } }
    }

    init(session: URLSession, highWaterMark: Int, lowWaterMark: Int,
        bufferObserver: (@Sendable (Int, Bool) -> Void)?, redirectPolicy: @escaping @Sendable (URL) -> Bool = { _ in true },
        timerFactory: @escaping @Sendable () -> any HTTPRequestTimer = { DispatchHTTPRequestTimer() }) {
        precondition(highWaterMark > 0 && lowWaterMark >= 0 && lowWaterMark < highWaterMark)
        self.sessions = [session]
        requestTimeout = session.configuration.timeoutIntervalForRequest
        self.timerFactory = timerFactory
        self.lifecycle = HTTPSessionLifecycle()
        self.highWaterMark = highWaterMark
        self.lowWaterMark = lowWaterMark
        self.bufferObserver = bufferObserver
        self.redirectPolicy = redirectPolicy
    }

    public func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        if let offset, offset < 0 { throw LauncherError.io("Invalid resume offset \(offset)") }
        return try await request(url, method: "GET", offset: offset)
    }

    public func post(_ url: URL) async throws -> (HTTPResponseHead, HTTPBody) {
        try await request(url, method: "POST", offset: nil)
    }

    private func request(_ url: URL, method: String, offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard redirectPolicy(url) else { throw LauncherError.transport("HTTP destination is not allowed") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        if method == "POST" { request.httpBody = Data() }
        // CFNetwork's idle timer keeps running while a task is suspended for
        // consumer backpressure. Own that timer instead, pausing it at the high
        // watermark. An explicitly configured whole-resource deadline still applies.
        request.timeoutInterval = .greatestFiniteMagnitude
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let offset { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let delegate = HTTPStreamDelegate(highWaterMark: highWaterMark, lowWaterMark: lowWaterMark,
            bufferObserver: bufferObserver, lifecycle: lifecycle, redirectPolicy: redirectPolicy, callbackObserver: callbackObserver,
            requestTimeout: requestTimeout, timer: timerFactory(), taskTransitionObserver: taskTransitionObserver, rateLimiter: rateLimiter)
        try lifecycle.invalidated.withLock { invalidated in
            guard !invalidated else { throw LauncherError.cancelled }
            let index = lifecycle.cursor.withLock { cursor in let index = cursor; cursor = (cursor + 1) % sessions.count; return index }
            let task = sessions[index].dataTask(with: request)
            // Attach before invalidate() can cancel, so no completion callback is missed.
            task.delegate = delegate
            delegate.attach(task)
        }
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

    /// Observe the actual client task after each serialized native suspend/resume
    /// effect. Tests can verify native state independently of buffer bookkeeping.
    func observingTaskTransitions(_ observer: @escaping @Sendable (URLSessionTask, URLSessionTask.State) -> Void) -> Self {
        var copy = self; copy.taskTransitionObserver = observer; return copy
    }

    /// Opt-in transport profiling, propagated into native callbacks (which do
    /// not inherit task-local context). Normal clients leave it unset.
    package func observingDataCallbacks(_ observer: @escaping @Sendable (Int, Duration) -> Void) -> Self {
        observingDataCallbacks { _, bytes, duration in observer(bytes, duration) }
    }

    package func observingDataCallbacks(_ observer: @escaping @Sendable (URLSessionTask, Int, Duration) -> Void) -> Self {
        var copy = self; copy.callbackObserver = observer; return copy
    }
}

private final class HTTPSessionLifecycle: Sendable {
    let invalidated = Mutex(false)
    let cursor = Mutex(0)
}

private final class HTTPStreamDelegate: NSObject, URLSessionDataDelegate {
    private enum Effect {
        case resume(URLSessionDataTask)
        case suspend(URLSessionDataTask)
        case cancel(URLSessionDataTask)
        case observe(bytes: Int, suspended: Bool)
        case cancelRateWait(Task<Void, Never>)
        case incrementalDelivery(URLSessionDataTask, Bool)
        case acknowledgeTransition(UUID, observer: UUID)
        case releaseReception(UUID)
        case removeRateObserver(UUID)
        case accountReception(URLSessionTask?, reservation: UUID?, epoch: UUID?)
        case resetReceptionBaseline(URLSessionTask?, epoch: UUID)
    }

    private struct State {
        var task: URLSessionDataTask?
        var head: CheckedContinuation<HTTPResponseHead, any Error>?
        var waiter: CheckedContinuation<Data?, any Error>?
        var pieces: [Data?] = []
        var readIndex = 0
        var bufferedBytes = 0
        var suspended = true // URLSession tasks start suspended.
        var started = false
        var bufferPaused = false
        var ratePaused = false
        var rateLimited = false
        var receptionEpoch: UUID?
        var callbackBytes: Int64 = 0
        var accountedReception: Int64 = 0
        var rateAllowance = 0
        var rateReceiver: UUID?
        var rateGeneration: UUID?
        var rateWait: Task<Void, Never>?
        var rateLease: Task<Void, Never>?
        var rateLeaseGeneration: UUID?
        var idleRemaining: TimeInterval?
        var rateObservation: UUID?
        var finished = false
        var idleDeadline: TimeInterval?
        var terminalError: LauncherError?
        var cancelledByUs = false
        var effects: [Effect] = []
        var drainingEffects = false
    }

    private let state = Mutex(State())
    private let highWaterMark: Int
    private let lowWaterMark: Int
    private let bufferObserver: (@Sendable (Int, Bool) -> Void)?
    private let lifecycle: HTTPSessionLifecycle
    private let redirectPolicy: @Sendable (URL) -> Bool
    private let callbackObserver: (@Sendable (URLSessionTask, Int, Duration) -> Void)?
    private let requestTimeout: TimeInterval
    private let taskTransitionObserver: (@Sendable (URLSessionTask, URLSessionTask.State) -> Void)?
    private let timer: any HTTPRequestTimer
    private let rateLimiter: DownloadRateLimiter?

    init(highWaterMark: Int, lowWaterMark: Int, bufferObserver: (@Sendable (Int, Bool) -> Void)?,
        lifecycle: HTTPSessionLifecycle, redirectPolicy: @escaping @Sendable (URL) -> Bool,
        callbackObserver: (@Sendable (URLSessionTask, Int, Duration) -> Void)?, requestTimeout: TimeInterval,
        timer: any HTTPRequestTimer,
        taskTransitionObserver: (@Sendable (URLSessionTask, URLSessionTask.State) -> Void)?, rateLimiter: DownloadRateLimiter?) {
        self.rateLimiter = rateLimiter
        self.taskTransitionObserver = taskTransitionObserver
        self.highWaterMark = highWaterMark
        self.lowWaterMark = lowWaterMark
        self.bufferObserver = bufferObserver
        self.lifecycle = lifecycle
        self.redirectPolicy = redirectPolicy
        self.callbackObserver = callbackObserver
        self.requestTimeout = requestTimeout; self.timer = timer
        super.init()
        timer.setHandler { [weak self] in
            self?.finish(.transport("HTTP request timed out"), cancelTask: true, onlyIfIdle: true)
        }
        if let rateLimiter {
            let observation = UUID()
            state.withLock { $0.rateObservation = observation }
            rateLimiter.observeChanges(id: observation) { [weak self, weak rateLimiter] transition in
                if let self { self.rateLimitChanged(transition: transition, observation: observation) }
                else { rateLimiter?.acknowledgeTransition(transition, observer: observation) }
            }
            rateLimitChanged()
        }
    }

    deinit {
        if let observation = state.withLock({ $0.rateObservation }) { rateLimiter?.removeObserver(observation) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        var request = request
        request.timeoutInterval = .greatestFiniteMagnitude
        state.withLock { if !$0.finished { receivedActivity(&$0) } }
        completionHandler(request.url.map(redirectPolicy) == true ? request : nil)
    }

    func attach(_ task: URLSessionDataTask) {
        state.withLock { state in
            state.task = task
            if rateLimiter != nil { state.effects.append(.incrementalDelivery(task, state.rateLimited)) }
        }
    }

    func start(_ continuation: CheckedContinuation<HTTPResponseHead, any Error>) {
        let error: LauncherError? = state.withLock { state in
            guard !state.finished, state.task != nil else {
                return state.terminalError ?? .transport("HTTP request already finished")
            }
            state.head = continuation
            state.started = true
            requestRateAllowance(&state)
            updateSuspension(&state)
            return nil
        }
        performEffects()
        if let error { continuation.resume(throwing: error) }
    }

    func cancel() {
        finish(.cancelled, cancelTask: true, cancelledByUs: true)
    }

    func next() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<Data?, LauncherError>? = state.withLock { state in
                defer { observe(&state) }
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
                    if state.bufferPaused && state.bufferedBytes <= lowWaterMark {
                        state.bufferPaused = false
                        requestRateAllowance(&state)
                        updateSuspension(&state)
                    }
                    return .success(data)
                }
                if state.finished {
                    return state.terminalError.map { .failure($0) } ?? .success(nil)
                }
                state.waiter = continuation
                return nil
            }
            performEffects()
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
            receivedActivity(&state)
            let continuation = state.head
            state.head = nil
            requestRateAllowance(&state)
            updateSuspension(&state)
            return continuation
        }
        guard let continuation else {
            completionHandler(.cancel)
            return
        }
        performEffects()
        continuation.resume(returning: HTTPResponseHead(response))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let started = callbackObserver.map { _ in ContinuousClock.now }
        defer { if let started { callbackObserver?(dataTask, data.count, started.duration(to: .now)) } }
        guard !data.isEmpty else { return }
        let waiter = state.withLock { state -> CheckedContinuation<Data?, any Error>? in
            let receiver = state.rateReceiver
            state.rateReceiver = nil
            state.callbackBytes += Int64(data.count)
            // Catch a live enable before its observer reaches this delegate.
            let epoch = rateLimiter?.receptionEpoch
            let newEpoch = epoch != nil && state.receptionEpoch != epoch
            if newEpoch {
                state.receptionEpoch = epoch; state.rateLimited = true
                if let task = state.task { state.effects.append(.incrementalDelivery(task, true)) }
            }
            state.rateAllowance = 0
            if let lease = state.rateLease { state.effects.append(.cancelRateWait(lease)) }
            state.rateLease = nil; state.rateLeaseGeneration = nil
            guard !state.finished else {
                state.effects.append(.accountReception(dataTask, reservation: receiver, epoch: state.receptionEpoch))
                return nil
            }
            defer {
                requestRateAllowance(&state)
                updateSuspension(&state)
                observe(&state)
                if newEpoch, let epoch { state.effects.append(.resetReceptionBaseline(dataTask, epoch: epoch)) }
                state.effects.append(.accountReception(dataTask, reservation: receiver, epoch: state.receptionEpoch))
                if let receiver { state.effects.append(.releaseReception(receiver)) }
            }
            receivedActivity(&state)
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            // Accept the entire callback, including its possible watermark overshoot.
            // Waiting here would block every task sharing this session's delegate queue.
            state.pieces.append(data)
            state.bufferedBytes += data.count
            if state.bufferedBytes >= highWaterMark { state.bufferPaused = true }
            return nil
        }
        performEffects()
        waiter?.resume(returning: data)
    }

    private func rateLimitChanged(transition: UUID? = nil, observation: UUID? = nil) {
        state.withLock { state in
            defer {
                if let transition, let observation { state.effects.append(.acknowledgeTransition(transition, observer: observation)) }
            }
            guard !state.finished, let rateLimiter else { return }
            let epoch = rateLimiter.receptionEpoch
            let limited = epoch != nil, newEpoch = epoch != nil && state.receptionEpoch != epoch
            state.receptionEpoch = epoch
            if state.rateLimited != limited, let task = state.task { state.effects.append(.incrementalDelivery(task, limited)) }
            state.rateLimited = limited
            if !state.rateLimited {
                if let wait = state.rateWait { state.effects.append(.cancelRateWait(wait)) }
                state.rateWait = nil; state.rateGeneration = nil
                if let lease = state.rateLease { state.effects.append(.cancelRateWait(lease)) }
                state.rateLease = nil; state.rateLeaseGeneration = nil
                state.effects.append(.accountReception(state.task, reservation: state.rateReceiver, epoch: state.receptionEpoch))
                state.rateAllowance = 0; state.rateReceiver = nil; state.ratePaused = false
            } else {
                requestRateAllowance(&state)
            }
            updateSuspension(&state)
            if newEpoch, let epoch { state.effects.append(.resetReceptionBaseline(state.task, epoch: epoch)) }
        }
        performEffects()
    }

    private func requestRateAllowance(_ state: inout State) {
        guard state.started, !state.finished, state.rateLimited, state.rateAllowance == 0 else { return }
        state.ratePaused = true
        guard !state.bufferPaused, state.rateWait == nil, let rateLimiter else { return }
        let generation = UUID()
        let owner = generation
        state.rateGeneration = generation
        state.rateWait = Task { [weak self, rateLimiter] in
            do {
                let allowance = try await rateLimiter.acquire(upTo: 64 << 10, receptionOwner: owner)
                guard let self else {
                    rateLimiter.settle(reception: owner, received: 0); rateLimiter.releaseReception(owner); return
                }
                self.admitReception(allowance, generation: generation)
            } catch {
                self?.rateWaitFailed(generation: generation)
            }
        }
    }

    private func rateWaitFailed(generation: UUID) {
        let active = state.withLock { !$0.finished && $0.rateGeneration == generation }
        if active { finish(.transport("Download pacing failed"), cancelTask: true) }
    }

    private func admitReception(_ allowance: Int, generation: UUID) {
        let adopted = state.withLock { state in
            guard !state.finished, state.rateLimited, state.rateGeneration == generation else { return false }
            state.rateWait = nil; state.rateGeneration = nil
            state.rateAllowance = allowance; state.rateReceiver = generation; state.ratePaused = false
            let lease = UUID()
            state.rateLeaseGeneration = lease
            if let rateLimiter {
                state.rateLease = Task { [weak self, rateLimiter] in
                    do { try await rateLimiter.waitForReceptionSlice(); self?.endReceptionSlice(lease) }
                    catch { }
                }
            }
            updateSuspension(&state)
            return true
        }
        if !adopted {
            rateLimiter?.settle(reception: generation, received: 0)
            rateLimiter?.releaseReception(generation)
        }
        performEffects()
    }

    private func endReceptionSlice(_ generation: UUID) {
        state.withLock { state in
            guard !state.finished, state.rateLeaseGeneration == generation else { return }
            let receiver = state.rateReceiver
            state.rateAllowance = 0; state.rateReceiver = nil
            state.rateLease = nil; state.rateLeaseGeneration = nil
            requestRateAllowance(&state)
            updateSuspension(&state)
            state.effects.append(.accountReception(state.task, reservation: receiver, epoch: state.receptionEpoch))
            if let receiver { state.effects.append(.releaseReception(receiver)) }
        }
        performEffects()
    }

    private func accountReception(_ task: URLSessionTask?, reservation: UUID?, epoch: UUID?) {
        let received = state.withLock { state in
            let observed = max(state.callbackBytes, task?.countOfBytesReceived ?? 0)
            let received = max(0, observed - state.accountedReception)
            state.accountedReception = observed
            if received > 0, !state.finished { receivedActivity(&state) }
            return Int(clamping: received)
        }
        rateLimiter?.settle(reception: reservation, received: received, epoch: epoch)
    }

    private func resetReceptionBaseline(_ task: URLSessionTask?, epoch: UUID) {
        state.withLock { state in
            guard state.receptionEpoch == epoch, rateLimiter?.receptionEpoch == epoch else { return }
            state.accountedReception = max(state.callbackBytes, task?.countOfBytesReceived ?? 0)
        }
    }

    private func updateSuspension(_ state: inout State) {
        guard state.started, !state.finished, let task = state.task else { return }
        let suspended = state.bufferPaused || state.ratePaused
        if suspended {
            if state.ratePaused, !state.bufferPaused, let deadline = state.idleDeadline {
                state.idleRemaining = max(0, deadline - timer.now)
            }
            state.idleDeadline = nil
            timer.schedule(at: nil)
        }
        guard state.suspended != suspended else { return }
        state.suspended = suspended
        if suspended { state.effects.append(.suspend(task)) }
        else {
            if let remaining = state.idleRemaining {
                state.idleRemaining = nil
                state.idleDeadline = timer.now + remaining
                timer.schedule(at: state.idleDeadline)
            } else { restartIdleTimer(&state) }
            state.effects.append(.resume(task))
        }
    }

    private func receivedActivity(_ state: inout State) {
        if !state.suspended { state.idleDeadline = timer.now + requestTimeout }
        else if state.ratePaused { state.idleRemaining = requestTimeout }
    }

    private func restartIdleTimer(_ state: inout State) {
        receivedActivity(&state)
        timer.schedule(at: state.idleDeadline)
    }

    private func observe(_ state: inout State) {
        if bufferObserver != nil {
            state.effects.append(.observe(bytes: state.bufferedBytes, suspended: state.suspended))
        }
    }

    private func performEffects() {
        let shouldDrain = state.withLock { state in
            guard !state.drainingEffects else { return false }
            state.drainingEffects = true
            return true
        }
        guard shouldDrain else { return }
        // One drainer preserves transition order, including reentrant observer calls.
        // All native task operations and observer callbacks run outside the mutex.
        while let effects = state.withLock({ state -> [Effect]? in
            guard !state.effects.isEmpty else {
                state.drainingEffects = false
                return nil
            }
            let effects = state.effects
            state.effects.removeAll(keepingCapacity: true)
            return effects
        }) {
            for effect in effects {
                switch effect {
                case .resume(let task):
                    task.resume()
                    taskTransitionObserver?(task, .running)
                case .suspend(let task):
                    task.suspend()
                    taskTransitionObserver?(task, .suspended)
                case .cancel(let task): task.cancel()
                case .cancelRateWait(let task): task.cancel()
                case .incrementalDelivery(let task, let enabled): task.prefersIncrementalDelivery = enabled
                case .acknowledgeTransition(let transition, let observer): rateLimiter?.acknowledgeTransition(transition, observer: observer)
                case .releaseReception(let owner): rateLimiter?.releaseReception(owner)
                case .removeRateObserver(let observer): rateLimiter?.removeObserver(observer)
                case .accountReception(let task, let reservation, let epoch): accountReception(task, reservation: reservation, epoch: epoch)
                case .resetReceptionBaseline(let task, let epoch): resetReceptionBaseline(task, epoch: epoch)
                case .observe(let bytes, let suspended): bufferObserver?(bytes, suspended)
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let failure: LauncherError?
        if let error {
            let nsError = error as NSError
            failure = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
                && (state.withLock({ $0.cancelledByUs }) || lifecycle.invalidated.withLock({ $0 }))
                ? .cancelled : .transport(error.localizedDescription)
        } else {
            failure = nil
        }
        finish(failure)
    }

    private func finish(_ error: LauncherError?, cancelTask: Bool = false, cancelledByUs: Bool = false,
        onlyIfIdle: Bool = false) {
        let completed = state.withLock { state -> State? in
            if onlyIfIdle {
                guard !state.finished, let deadline = state.idleDeadline else { return nil }
                // Data can arrive concurrently with a queued timer callback. Check
                // and finish under the same lock; a stale callback only rearms.
                guard deadline <= timer.now else { timer.schedule(at: deadline); return nil }
            }
            guard !state.finished || cancelTask else { return nil }
            timer.cancel()
            state.idleDeadline = nil
            state.cancelledByUs = state.cancelledByUs || cancelledByUs
            state.finished = true
            state.terminalError = error ?? (state.head == nil ? nil : .transport("HTTP transfer ended before response headers"))
            if cancelTask {
                state.pieces.removeAll()
                state.readIndex = 0
                state.bufferedBytes = 0
            }
            let completed = state
            if let wait = state.rateWait { state.effects.append(.cancelRateWait(wait)) }
            if let lease = state.rateLease { state.effects.append(.cancelRateWait(lease)) }
            state.rateLease = nil; state.rateLeaseGeneration = nil
            state.rateAllowance = 0; state.rateReceiver = nil; state.rateWait = nil; state.rateGeneration = nil; state.rateObservation = nil
            if cancelTask, let task = state.task { state.effects.append(.cancel(task)) }
            state.effects.append(.accountReception(state.task, reservation: completed.rateReceiver, epoch: state.receptionEpoch))
            if let receiver = completed.rateReceiver { state.effects.append(.releaseReception(receiver)) }
            if let observer = completed.rateObservation { state.effects.append(.removeRateObserver(observer)) }
            state.task = nil
            state.head = nil
            state.waiter = nil
            state.suspended = false
            observe(&state)
            return completed
        }
        guard let completed else { return }
        performEffects()
        if let head = completed.head {
            head.resume(throwing: completed.terminalError ?? .transport("Missing HTTP response"))
        }
        if let waiter = completed.waiter {
            if let error = completed.terminalError { waiter.resume(throwing: error) }
            else { waiter.resume(returning: nil) }
        }
    }
}
