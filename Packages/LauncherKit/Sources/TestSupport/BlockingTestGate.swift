// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation

/// Models stalled synchronous I/O. Call block() only from a BlockingIO worker.
public final class BlockingTestGate: @unchecked Sendable {
    public let entered = TestEvent()
    private let condition = NSCondition()
    private var released = false
    public init() {}
    public func block() {
        condition.lock()
        defer { condition.unlock() }
        entered.signal()
        while !released { condition.wait() }
    }
    public func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
