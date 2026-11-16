// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

/// The model serializes history calls with delivery. Disk I/O never holds its actor.
protocol GameNotificationHistoryAccess: Sendable {
    func contains(_ marker: GameNotificationHistory.Marker) async throws -> Bool
    func claim(_ marker: GameNotificationHistory.Marker) async throws -> Bool
    func release(_ marker: GameNotificationHistory.Marker) async throws
}

struct LiveGameNotificationHistory: GameNotificationHistoryAccess {
    let store: GameNotificationHistory
    func contains(_ marker: GameNotificationHistory.Marker) async throws -> Bool {
        try await BlockingIO.run { try store.contains(marker) }
    }
    func claim(_ marker: GameNotificationHistory.Marker) async throws -> Bool {
        try await BlockingIO.run { try store.claim(marker) }
    }
    func release(_ marker: GameNotificationHistory.Marker) async throws {
        try await BlockingIO.run { try store.release(marker) }
    }
}

/// Availability claims are written before submitting to the OS. An uncertain
/// termination favors a missed banner over repeating it on every launch.
struct GameNotificationHistory: Sendable {
    struct Marker: Codable, Hashable, Sendable {
        let gameID: String
        let version: String
        let kind: GameNotificationKind
    }
    /// Numeric campaigns advance monotonically. Earlier versions stay suppressed
    /// after retirement, including across restarts, reinstalls and stale metadata.
    /// Opaque versions have no safe ordering and retain their exact receipts.
    private struct State: Codable {
        var schemaVersion = 1
        var watermarks: Set<Marker> = []
        var markers: Set<Marker> = []

        func contains(_ marker: Marker) -> Bool {
            if markers.contains(marker) { return true }
            guard let version = CampaignVersion(marker.version) else { return false }
            return watermarks.contains {
                $0.gameID == marker.gameID && $0.kind == marker.kind
                    && CampaignVersion($0.version).map { version <= $0 } == true
            }
        }

        mutating func compact() {
            var latest: [String: [GameNotificationKind: Marker]] = [:]
            var opaque: Set<Marker> = []
            for marker in markers.union(watermarks) {
                guard GameDefinition.find(marker.gameID) != nil, marker.kind.isAvailability else { continue }
                guard let version = CampaignVersion(marker.version) else { opaque.insert(marker); continue }
                if let previous = latest[marker.gameID]?[marker.kind],
                    let old = CampaignVersion(previous.version), old >= version { continue }
                latest[marker.gameID, default: [:]][marker.kind] = marker
            }
            watermarks = Set(latest.values.flatMap { $0.values })
            markers = opaque
        }
    }

    /// A strict decimal dotted version. No lexicographic or locale-dependent
    /// comparison may retire an opaque label or put 7.10 before 7.9.
    private struct CampaignVersion: Comparable {
        let parts: [UInt64]
        init?(_ raw: String) {
            guard !raw.isEmpty, raw.utf8.count <= 256 else { return nil }
            let pieces = raw.split(separator: ".", omittingEmptySubsequences: false)
            guard !pieces.isEmpty, pieces.count <= 16 else { return nil }
            var parsed: [UInt64] = []
            for piece in pieces {
                guard !piece.isEmpty, piece.utf8.allSatisfy({ (48...57).contains($0) }),
                    let value = UInt64(piece) else { return nil }
                parsed.append(value)
            }
            while parsed.last == 0 { parsed.removeLast() }
            parts = parsed
        }
        static func < (lhs: Self, rhs: Self) -> Bool {
            for index in 0..<max(lhs.parts.count, rhs.parts.count) {
                let left = index < lhs.parts.count ? lhs.parts[index] : 0
                let right = index < rhs.parts.count ? rhs.parts[index] : 0
                if left != right { return left < right }
            }
            return false
        }
    }

    let paths: AppPaths
    private func read(_ fs: ContainedFileSystem) throws -> State {
        let path = try SafeRelativePath("notification-history.json")
        guard try fs.itemType(at: path) != nil else { return State() }
        let data = try fs.readFile(at: path, maxBytes: 1_048_576)
        let decoder = JSONDecoder()
        if let legacy = try? decoder.decode(Set<Marker>.self, from: data) { return State(markers: legacy) }
        let state = try decoder.decode(State.self, from: data)
        guard state.schemaVersion == 1 else { throw LauncherError.io("Invalid notification history schema") }
        return state
    }
    func contains(_ marker: Marker) throws -> Bool {
        try read(ContainedFileSystem(root: paths.root)).contains(marker)
    }
    func claim(_ marker: Marker) throws -> Bool {
        let fs = try ContainedFileSystem(root: paths.root)
        var state = try read(fs)
        // Only previous deliveries/uncertain submissions retire. The new claim
        // stays removable until submission, so a failed/obsolete one can retry.
        state.compact()
        guard !state.contains(marker) else { try save(state, fs: fs); return false }
        state.markers.insert(marker)
        try save(state, fs: fs)
        return true
    }
    func release(_ marker: Marker) throws {
        let fs = try ContainedFileSystem(root: paths.root)
        var state = try read(fs)
        state.markers.remove(marker)
        try save(state, fs: fs)
    }
    private func save(_ state: State, fs: ContainedFileSystem) throws {
        // Stable arrays keep migration and subsequent writes deterministic.
        func ordered(_ markers: Set<Marker>) -> [Marker] {
            markers.sorted {
                if $0.gameID != $1.gameID { return $0.gameID < $1.gameID }
                if $0.version != $1.version { return $0.version < $1.version }
                return $0.kind.rawValue < $1.kind.rawValue
            }
        }
        struct EncodedState: Encodable {
            let schemaVersion: Int
            let watermarks: [Marker]
            let markers: [Marker]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(EncodedState(schemaVersion: state.schemaVersion,
            watermarks: ordered(state.watermarks), markers: ordered(state.markers)))
        guard data.count <= 1_048_576 else { throw LauncherError.io("Notification history limit") }
        try fs.writeAtomically(data, to: SafeRelativePath("notification-history.json"))
    }
}
