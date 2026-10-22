// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Dispatch
import Foundation

/// One timer per request, independent of the cooperative pool. The delegate
/// advances its deadline on data without rescheduling on every chunk; a stale
/// wakeup rearms against the latest deadline. Tests can advance time explicitly.
// Scheduling/cancelling must never synchronously invoke the handler.
protocol HTTPRequestTimer: Sendable {
    var now: TimeInterval { get }
    func setHandler(_ handler: @escaping @Sendable () -> Void)
    func schedule(at deadline: TimeInterval?)
    func cancel()
}

final class DispatchHTTPRequestTimer: HTTPRequestTimer {
    private static let queue = DispatchQueue(label: "org.macgacha.http-timeout", attributes: .concurrent)
    private let source = DispatchSource.makeTimerSource(queue: queue)
    var now: TimeInterval { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }

    init() { source.activate() }
    deinit { source.cancel() }
    func setHandler(_ handler: @escaping @Sendable () -> Void) { source.setEventHandler(handler: handler) }
    func schedule(at deadline: TimeInterval?) {
        let nanos = deadline.map { $0 * 1_000_000_000 }
        if let nanos, nanos.isFinite, nanos >= 0, nanos < Double(UInt64.max) {
            source.schedule(deadline: DispatchTime(uptimeNanoseconds: UInt64(nanos)))
        } else { source.schedule(deadline: .distantFuture) }
    }
    func cancel() { source.cancel() }
}
