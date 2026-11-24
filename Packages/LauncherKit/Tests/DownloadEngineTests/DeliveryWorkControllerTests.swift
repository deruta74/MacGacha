// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import TestSupport
import LauncherCore
@testable import DownloadEngine

@Suite(.timeLimit(.minutes(1))) struct DeliveryWorkControllerTests {
    @Test(arguments: [DeliveryWorkController.Kind.transfer, .assembly])
    func gameplayWaitsForAdmittedWorkAndEndingGameplayWakesWaiters(_ kind: DeliveryWorkController.Kind) async throws {
        let controller = DeliveryWorkController()
        try await controller.acquire(kind)
        try await controller.acquire(kind)
        controller.setGameplayActive(true)
        let events = AsyncStream<String>.makeStream()
        let waiter = Task {
            try await OperationWork.$observer.withValue({ if $0 == .deliveryWorkWaiting { events.continuation.yield("waiting") } }) {
                try await controller.acquire(kind)
                events.continuation.yield("admitted")
            }
        }
        defer { waiter.cancel() }
        var event = events.stream.makeAsyncIterator()
        #expect(await event.next() == "waiting")
        // An admitted operation retains its slot: reducing parallelism never
        // cancels it or changes the work already using it.
        controller.release(kind)
        controller.setGameplayActive(false)
        #expect(await event.next() == "admitted")
        try await waiter.value
        controller.release(kind)
        controller.release(kind)
    }

    @Test func cancellationRemovesAWaitingAssemblyWithoutLeakingCapacity() async throws {
        let controller = DeliveryWorkController()
        controller.setGameplayActive(true)
        try await controller.acquire(.assembly)
        let queued = AsyncStream<Void>.makeStream()
        let waiter = Task {
            try await OperationWork.$observer.withValue({ if $0 == .deliveryWorkWaiting { queued.continuation.yield(()) } }) {
                try await controller.acquire(.assembly)
            }
        }
        var event = queued.stream.makeAsyncIterator()
        _ = await event.next()
        waiter.cancel()
        await #expect(throws: (any Error).self) { try await waiter.value }
        controller.release(.assembly)
        try await controller.acquire(.assembly)
        controller.release(.assembly)
    }

    @Test func cachedLocalInstallationUsesGameplayAssemblyAdmissionAndResumesLive() async throws {
        let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url), cdn = MockCDN()
        let bytes = Data("cached contents".utf8)
        try fs.writeAtomically(bytes, to: SafeRelativePath("source"))
        let file = try stagingFile("output", "cached contents", [Extent(source: .local(path: SafeRelativePath("source"), offset: 0),
            fileOffset: 0, length: Int64(bytes.count), digest: stagingDigest("cached contents"))])
        let plan = try stagingPlan([], [file]), controller = DeliveryWorkController()
        controller.setGameplayActive(true)
        try await controller.acquire(.assembly)
        let queued = AsyncStream<Void>.makeStream()
        let install = Task {
            try await OperationWork.$observer.withValue({ if $0 == .deliveryWorkWaiting { queued.continuation.yield(()) } }) {
                try await opCollect(InstallOperation(plan: plan, installRoot: temp.url, fetcher: stagingFetcher(cdn),
                    deliveryWorkController: controller).run())
            }
        }
        defer { install.cancel(); controller.release(.assembly) }
        var event = queued.stream.makeAsyncIterator()
        _ = await event.next()
        #expect(try fs.size(at: file.path) == nil)
        #expect(cdn.requestLog.isEmpty)
        controller.setGameplayActive(false)
        #expect(try await install.value.last == .phase(.completed))
        #expect(try fs.readFile(at: file.path, maxBytes: bytes.count) == bytes)
    }
}
