// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine

extension GameLibrary {
    /// Mount events retry journals even when their destination is not the current
    /// record path. Busy or still-unavailable moves keep their durable exclusion.
    public func recoverPendingMoves() async -> [String] {
        var recovered: [String] = []
        guard let ids = try? await store.gameDirectories() else { return [] }
        for id in ids.sorted() {
            do {
                guard try await store.readState("move-journal.json", for: id, maxBytes: 65536) != nil else { continue }
                try await mover.recover(id)
                recovered.append(id)
            } catch {
                log?.post(.info, "game", "Move recovery deferred", metadata: ["game": id])
            }
        }
        return recovered
    }

    var mover: GameMover {
        GameMover(paths: paths, store: store, disk: disk, fileOps: fileOps,
            locationProbe: locationProbe, guard: operationGuard, log: log)
    }

    /// Active pre-download streams must be cancelled and drained by their owner.
    /// The mover itself refuses live leases and never rewrites normal saved plans.
    public func move(_ game: GameDefinition, to folder: URL) -> AsyncThrowingStream<OperationEvent, any Error> {
        let session = GameMoveStream(mover: mover, game: game, folder: folder)
        return pipelineStream(abandon: {}) { register in try await session.next(register: register) }
    }
}

/// One producer owns the move. Slow consumers retain phase changes and only
/// the latest byte snapshot, with cancellation joined before releasing the slot.
private actor GameMoveStream {
    private let mover: GameMover
    private let game: GameDefinition
    private let folder: URL
    private let channel = PipelineChannel()
    private var producer: Task<Void, Never>?

    init(mover: GameMover, game: GameDefinition, folder: URL) {
        self.mover = mover; self.game = game; self.folder = folder
    }

    func next(register: @Sendable (Task<Void, Never>) -> Void) async throws -> OperationEvent? {
        if producer == nil {
            let mover = mover, game = game, folder = folder, channel = channel
            let task = Task {
                let counter = PipelineProgress(sizes: [:])
                do {
                    try await mover.move(game, to: folder) { event in
                        if case .progress(_, _, let staged, let total) = event {
                            counter.stage(staged, total: total)
                            channel.send(counter.snapshot())
                        } else { channel.send(event) }
                    }
                    channel.finish()
                } catch { channel.finish(error) }
            }
            producer = task; register(task)
            if Task.isCancelled { task.cancel() }
        }
        do {
            let event = try await channel.next()
            if event == .phase(.completed) || event == nil { await producer?.value }
            return event
        }
        catch {
            await producer?.value
            throw error
        }
    }
}
