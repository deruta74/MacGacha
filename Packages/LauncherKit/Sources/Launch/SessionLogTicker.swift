// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Dispatch

package struct LogTickCancellation: Sendable {
    private let action: @Sendable () -> Void
    package init(_ action: @escaping @Sendable () -> Void) { self.action = action }
    package func cancel() { action() }
}
package protocol SessionLogTicker: Sendable {
    func start(_ action: @escaping @Sendable () -> Void) -> LogTickCancellation
}
package struct SystemSessionLogTicker: SessionLogTicker {
    package func start(_ action: @escaping @Sendable () -> Void) -> LogTickCancellation {
        let timer = Timer(action)
        return LogTickCancellation { timer.cancel() }
    }
    // Dispatch source cancellation is thread safe; all event work uses its own
    // serial I/O queue, never a cooperative worker. No mutable Swift state escapes.
    private final class Timer: @unchecked Sendable {
        let source: any DispatchSourceTimer
        init(_ action: @escaping @Sendable () -> Void) {
            source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "MacGacha.SessionLog.Cap", qos: .utility))
            source.setEventHandler(handler: action)
            source.schedule(deadline: .now() + 5, repeating: 5)
            source.resume()
        }
        func cancel() { source.cancel() }
        deinit { source.cancel() }
    }
}
