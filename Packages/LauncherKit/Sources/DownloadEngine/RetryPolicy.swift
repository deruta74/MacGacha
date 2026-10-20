import Foundation
import LauncherCore

public struct RetryPolicy: Sendable {
    public let maxAttempts: Int
    public let baseDelay: Duration
    public let maxDelay: Duration

    public init(maxAttempts: Int = 6, baseDelay: Duration = .milliseconds(500), maxDelay: Duration = .seconds(30)) {
        precondition(maxAttempts > 0 && baseDelay >= .zero && maxDelay >= .zero)
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public func delay(forAttempt n: Int, retryAfter: Duration?) -> Duration {
        var ceiling = min(baseDelay, maxDelay)
        var remaining = n > 1 ? n - 1 : 0
        while remaining > 0 && ceiling > .zero && ceiling < maxDelay {
            ceiling = ceiling >= maxDelay / 2 ? maxDelay : ceiling * 2
            remaining -= 1
        }
        let jitter = ceiling * Double.random(in: 0...1)
        return max(jitter, retryAfter ?? .zero)
    }

    public func isRetryable(_ error: any Error) -> Bool {
        guard let error = error as? LauncherError else { return false }
        switch error {
        case .transport, .sizeMismatch, .digestMismatch: return true
        case .http(let status, _): return status == 408 || status == 429 || (500...599).contains(status)
        default: return false
        }
    }
}

public protocol Sleeper: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct ContinuousSleeper: Sleeper {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
