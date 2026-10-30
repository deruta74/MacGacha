// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import DownloadEngine
import LauncherCore
import TestSupport
@testable import GameLibrary

@Suite(.timeLimit(.minutes(1))) struct VerificationProgressTests {
    @Test func byteCallbacksAccumulateUnderInjectedThrottle() {
        let start = ContinuousClock.now, clock = Mutex(ContinuousClock.now)
        clock.withLock { $0 = start }
        let values = Mutex<[Int64]>([])
        let progress = VerificationByteProgress(total: 1000, now: { clock.withLock { $0 } }, publish: { event in
            if case .progress(_, _, let bytes, let total) = event { #expect(total == 1000); values.withLock { $0.append(bytes) } }
        })
        progress.advance(10); progress.advance(20)
        #expect(values.withLock { $0.isEmpty })
        clock.withLock { $0 = start.advanced(by: .milliseconds(50)) }
        progress.advance(30)
        progress.advance(40); progress.flush()
        #expect(values.withLock { $0 } == [60, 100])
    }

    @Test func verificationPublishesBeforeCompletionAndCoalescesBursts() async throws {
        let beginBurst = TestEvent(), burstDone = TestEvent(), complete = TestEvent()
        let producer = Mutex<Task<Void, Never>?>(nil)
        let session = VerificationStream { publish in
            publish(.progress(downloaded: 0, totalNetwork: 0, staged: 0, totalStaged: 1000))
            try await beginBurst.wait()
            for count in 1...1000 { publish(.progress(downloaded: 0, totalNetwork: 0, staged: Int64(count), totalStaged: 1000)) }
            burstDone.signal(); try await complete.wait()
            return AsyncThrowingStream { $0.yield(.phase(.completed)); $0.finish() }
        }
        #expect(try await session.next(register: { _ in }) == .phase(.verifying))
        #expect(try await session.next(register: { task in producer.withLock { $0 = task } }) == .progress(downloaded: 0, totalNetwork: 0, staged: 0, totalStaged: 1000))
        beginBurst.signal(); try await burstDone.wait()
        #expect(try await session.next(register: { _ in }) == .progress(downloaded: 0, totalNetwork: 0, staged: 1000, totalStaged: 1000))
        complete.signal()
        #expect(try await session.next(register: { _ in }) == .phase(.completed))
        await producer.withLock { $0 }?.value
    }

    @Test func cancellingVerificationJoinsWorkerCleanup() async throws {
        let hold = TestEvent(), cancelled = TestEvent(), task = Mutex<Task<Void, Never>?>(nil)
        let session = VerificationStream { publish in
            defer { cancelled.signal() }
            publish(.progress(downloaded: 0, totalNetwork: 0, staged: 1, totalStaged: 2))
            try await hold.wait()
            return AsyncThrowingStream { $0.finish() }
        }
        _ = try await session.next(register: { _ in })
        _ = try await session.next(register: { value in task.withLock { $0 = value } })
        let producer = task.withLock { $0 }; producer?.cancel(); await producer?.value
        try await cancelled.wait()
        await #expect(throws: (any Error).self) { _ = try await session.next(register: { _ in }) }
    }

    @Test func cancellationBeforeRegistrationCancelsAndJoinsProducer() async throws {
        let producer = Mutex<Task<Void, Never>?>(nil)
        let builderRan = Mutex(false)
        let registered = TestEvent()
        let session = VerificationStream { _ in
            builderRan.withLock { $0 = true }
            return AsyncThrowingStream { $0.finish() }
        }
        #expect(try await session.next(register: { _ in }) == .phase(.verifying))
        let caller = Task {
            try await withTaskCancellationHandler {
                try await session.next { task in
                    // Existing registration seam: cancellation sees no producer yet.
                    withUnsafeCurrentTask { $0?.cancel() }
                    producer.withLock { $0 = task }
                    registered.signal()
                }
            } onCancel: {
                producer.withLock { $0?.cancel() }
            }
        }
        try await registered.wait()
        _ = await caller.result
        #expect(producer.withLock { $0?.isCancelled } == true)
        #expect(!builderRan.withLock { $0 })
        await producer.withLock { $0 }?.value
    }

    @Test func droppingVerificationStreamCancelsItsProducer() async throws {
        let hold = TestEvent(), cancelled = TestEvent()
        var stream: AsyncThrowingStream<OperationEvent, any Error>? = verification { publish in
            defer { cancelled.signal() }
            publish(.progress(downloaded: 0, totalNetwork: 0, staged: 1, totalStaged: 2))
            try await hold.wait()
            return AsyncThrowingStream { $0.finish() }
        }
        var iterator = stream?.makeAsyncIterator(); stream = nil
        #expect(try await iterator?.next() == .phase(.verifying))
        #expect(try await iterator?.next() == .progress(downloaded: 0, totalNetwork: 0, staged: 1, totalStaged: 2))
        iterator = nil
        try await cancelled.wait()
    }
}
