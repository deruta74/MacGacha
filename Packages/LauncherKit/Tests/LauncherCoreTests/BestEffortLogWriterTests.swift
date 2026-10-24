// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import TestSupport
@testable import LauncherCore

@Suite(.timeLimit(.minutes(1))) struct BestEffortLogWriterTests {
    @Test func dropsOldestWithinCountAndByteBounds() async throws {
        let gate = BlockingTestGate(), values = Mutex<[Int]>([])
        defer { gate.release() }
        let writer = BestEffortLogWriter<Int>(maxPendingCount: 2, maxPendingBytes: 4) { value in
            gate.block(); values.withLock { $0.append(value) }
        }
        writer.post(0, bytes: 2)
        try await gate.entered.wait()
        writer.post(1, bytes: 2); writer.post(2, bytes: 2); writer.post(3, bytes: 2)
        #expect(writer.droppedCount == 1)
        writer.post(4, bytes: 3) // Byte budget evicts both queued two-byte records.
        writer.post(5, bytes: 5) // An individually oversized record is discarded.
        #expect(writer.droppedCount == 4)
        #expect(values.withLock { $0.isEmpty })
        gate.release()
        await writer.drain()
        #expect(values.withLock { $0 } == [0, 4])
    }

    @Test func eventPostReturnsWhileStorageIsBlocked() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let gate = BlockingTestGate()
        defer { gate.release() }
        let log = EventLog(directory: temp, pendingRecords: 2, beforeWrite: { gate.block() })
        log.post(.info, "launch", "first")
        try await gate.entered.wait()
        for value in 1...5 { log.post(.info, "launch", "record \(value)") }
        #expect(log.droppedRecordCount == 3)
        gate.release()
        await log.flush()
        let text = try await BlockingIO.run { try String(contentsOf: temp.appendingPathComponent("macgacha.log"), encoding: .utf8) }
        #expect(!text.contains("record 1"))
        #expect(text.contains("record 4"))
        #expect(text.contains("record 5"))
    }
}
