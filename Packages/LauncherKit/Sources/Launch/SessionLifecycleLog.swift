// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization

/// Lifecycle writers resolve recovered logs lazily on BlockingIO. Reattachment
/// must not wait for optional log discovery, stale-output capping or append I/O.
final class SessionLifecycleLog: Sendable {
    private enum State: Sendable {
        case ready(SessionLog?)
        case recovering(URL, any SessionLogTicker)
    }
    let url: URL
    private let state: Mutex<State>
    init(_ log: SessionLog) { url = log.url; state = Mutex(.ready(log)) }
    init(recovering url: URL, ticker: any SessionLogTicker) {
        self.url = url; state = Mutex(.recovering(url, ticker))
    }
    private func resolve() -> SessionLog? {
        state.withLock { state in
            switch state {
            case .ready(let log): return log
            case .recovering(let url, let ticker):
                let log = try? SessionLog.recover(at: url, ticker: ticker)
                state = .ready(log)
                return log
            }
        }
    }
    func append(line: String) { resolve()?.append(line: line) }
    func cap() { resolve()?.enforceCap() }
    func finish() { resolve()?.finish() }
}
