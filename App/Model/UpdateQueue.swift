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
        var ownershipID: UUID?
        var plannedInstall: PlannedInstall?
        var approval: SpaceApproval?
        var approvedRetry: Bool?

        var kind: PendingOperation.Kind { plannedInstall == nil ? .update : .install }
        var spaceApproved: Bool { approvedRetry == true || plannedInstall?.approved == true }

        func matchesLocation(_ record: GameRecord) -> Bool {
            if let source {
                return source.installIdentity == record.installIdentity && source.installPath == record.installPath
            }
            return plannedInstall?.location.standardizedFileURL == record.installPath.standardizedFileURL
        }

        func ownsPlan(in record: GameRecord) -> Bool {
            guard let current = record.pending, current.kind == kind, !record.uninstalling, matchesLocation(record) else { return false }
            if let pending {
                return pending == current && (record.deliveryQueueOwner == nil || ownsPublication(in: record))
            }
            return ownsPublication(in: record) && record.installed == source?.installed
        }

        func ownsPublication(in record: GameRecord) -> Bool {
            ownershipID != nil && ownershipID == record.deliveryQueueOwner
        }
    }

    struct PlannedInstall: Codable, Equatable, Sendable {
        let startDate: Date
        let location: URL
        let voices: Set<String>
        let approved: Bool
    }

    struct SpaceApproval: Codable, Equatable, Sendable {
        let required: Int64
        let available: Int64
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
    private var quietDownloadsPreference: Bool?
    var quietDownloadSpeedLimit: Int64?
    private var keepAwakePreference: Bool?

    var keepMacAwakeForScheduledDownloads: Bool {
        get { keepAwakePreference ?? true }
        set { keepAwakePreference = newValue }
    }

    var quietDownloads: Bool {
        get { quietDownloadsPreference ?? true }
        set { quietDownloadsPreference = newValue }
    }

    func permits(at date: Date, calendar: Calendar = .current, onAC: Bool?) -> Bool {
        guard enabled, !requiresAC || onAC == true else { return false }
        return isInsideDailyWindow(at: date, calendar: calendar)
    }

    func isInsideDailyWindow(at date: Date, calendar: Calendar = .current) -> Bool {
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
    case connection, acPower, dailyWindow, idle, scheduledInstall(Date)

    var userMessage: String {
        switch self {
        case .connection: String(localized: "Waiting for a connection without Low Data Mode.")
        case .acPower: String(localized: "Waiting for AC power.")
        case .dailyWindow: String(localized: "Waiting for scheduled hours.")
        case .idle: String(localized: "Waiting for idle time.")
        case .scheduledInstall(let date): ScheduledInstallState.title(for: date)
        }
    }
}

struct ScheduledInstallState: Equatable {
    let request: UpdateQueue.PlannedInstall
    let isHeld: Bool
    let isRunning: Bool
    let failure: UpdateQueueFailure?

    var title: String { Self.title(for: request.startDate) }

    static func title(for date: Date) -> String {
        String(localized: "Install scheduled for \(date.formatted(date: .abbreviated, time: .shortened))")
    }
}

enum UpdateQueueSleepHint: Equatable {
    case onBattery, powerUnknown, disabled, unavailable

    var userMessage: String {
        switch self {
        case .onBattery: String(localized: "This Mac may sleep on battery power. Scheduled downloads can start after it wakes.")
        case .powerUnknown, .disabled, .unavailable: String(localized: "This Mac may sleep. Scheduled downloads can start after it wakes.")
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
        do {
            try fs.writeAtomically(data, to: SafeRelativePath("update-queue.json"))
        } catch {
            // A parent directory sync can report failure after the rename.
            // Reconcile the visible snapshot before reporting the edit lost.
            guard (try? load(migrating: nil)) == queue else { throw error }
        }
    }
}
