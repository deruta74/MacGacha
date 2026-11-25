// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import GameLibrary
import LauncherCore

/// A local, opt-in queue. Only plans started by the queue may resume unattended.
struct UpdateQueue: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        let id: String
        var paused = false
        var planID: String? = nil
        var pending: PendingOperation? = nil
        var source: GameRecord? = nil
        var automatic = false
    }
    var entries: [Entry] = []
    var enabled = true
    var scheduled = false
    var startMinute = 22 * 60
    var endMinute = 6 * 60
    var requiresAC = false
    var requiresIdle = false
    var idleMinutes = 5
    var automatic = false
    var automaticGames: Set<String> = []
    var lastDiscovery: Date? = nil

    func permits(at date: Date, calendar: Calendar = .current, onAC: Bool?) -> Bool {
        guard enabled, !requiresAC || onAC == true else { return false }
        guard scheduled else { return true }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        guard (0..<1440).contains(startMinute), (0..<1440).contains(endMinute), startMinute != endMinute else { return false }
        if startMinute < endMinute { return minute >= startMinute && minute < endMinute }
        return minute >= startMinute || minute < endMinute
    }
}

enum UpdateQueueFailure: Equatable {
    case operation(LauncherError)
    case installationChanged
    case pendingOperation
    case approvalRequired(required: Int64, available: Int64)

    var logCase: String {
        switch self {
        case .operation(let error): error.logCase
        case .installationChanged: "installationChanged"
        case .pendingOperation: "pendingOperation"
        case .approvalRequired: "approvalRequired"
        }
    }

    var userMessage: String {
        switch self {
        case .operation(let error): error.userMessage
        case .installationChanged: LauncherError.io("Installation changed").userMessage
        case .pendingOperation: LauncherError.busy("Pending operation changed").userMessage
        case .approvalRequired: LauncherError.insufficientSpace(required: 0, available: 0).userMessage
        }
    }
}

enum UpdateQueueWaiting: Equatable {
    case connection, acPower, dailyWindow, idle

    var userMessage: String {
        switch self {
        case .connection: String(localized: "Waiting for a connection without Low Data Mode.")
        case .acPower: String(localized: "Waiting for AC power.")
        case .dailyWindow: String(localized: "Waiting for scheduled hours.")
        case .idle: String(localized: "Waiting for idle time.")
        }
    }
}

struct AutomaticCheckGameGroup: Identifiable, Equatable {
    struct Edition: Identifiable, Equatable {
        let id: String
        let displayName: String
        let region: Region
        let isInstalled: Bool
    }

    let id: String
    let displayName: String
    let region: Region
    let editions: [Edition]
}

/// Filesystem calls belong on BlockingIO. A valid file always wins over legacy defaults.
struct UpdateQueueStore: Sendable {
    static let legacyKey = "updateQueue.v1"
    private static let limit = 1_048_576
    let root: URL

    func load(migrating legacy: Data?) throws -> UpdateQueue {
        let fs = try ContainedFileSystem(root: root)
        let path = try SafeRelativePath("update-queue.json")
        if try fs.itemType(at: path) != nil {
            return try JSONDecoder().decode(UpdateQueue.self, from: fs.readFile(at: path, maxBytes: Self.limit))
        }
        guard let legacy else { return UpdateQueue() }
        guard legacy.count <= Self.limit else { throw LauncherError.io("Queue file exceeds size limit") }
        let queue = try JSONDecoder().decode(UpdateQueue.self, from: legacy)
        try save(queue)
        return queue
    }

    func save(_ queue: UpdateQueue) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(queue)
        guard data.count <= Self.limit else { throw LauncherError.io("Queue file exceeds size limit") }
        let fs = try ContainedFileSystem(root: root)
        try fs.writeAtomically(data, to: SafeRelativePath("update-queue.json"))
    }
}
