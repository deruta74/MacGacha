// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import Foundation
import LauncherCore
import UserNotifications

enum GameNotificationAuthorization: Sendable, Equatable {
    case notDetermined, allowed, denied
}

enum GameNotificationKind: String, Codable, Sendable {
    case installFinished, updateFinished, repairFinished, operationFailed, pausedForSpace
    case preDownloadFinished, updateAvailable, preDownloadAvailable, dependencySetupFinished

    var isAvailability: Bool { self == .updateAvailable || self == .preDownloadAvailable }
    var title: String {
        switch self {
        case .installFinished: String(localized: "Installation finished")
        case .updateFinished: String(localized: "Update finished")
        case .repairFinished: String(localized: "Repair finished")
        case .operationFailed: String(localized: "Operation failed")
        case .pausedForSpace: String(localized: "Paused for space")
        case .preDownloadFinished: String(localized: "Pre-download finished")
        case .updateAvailable: String(localized: "Game update available")
        case .preDownloadAvailable: String(localized: "Pre-download available")
        case .dependencySetupFinished: String(localized: "Dependency setup finished")
        }
    }
}

struct GameNotification: Sendable {
    let id: String
    let gameID: String
    let kind: GameNotificationKind
    let title: String
    let body: String
}

struct GameNotificationSelection: Equatable {
    let id = UUID()
    let gameID: String
}

@MainActor protocol GameNotificationCenter: AnyObject {
    var onResponse: (@MainActor @Sendable (String) -> Void)? { get set }
    func authorizationState() async -> GameNotificationAuthorization
    func requestAuthorization() async throws -> Bool
    func deliver(_ notification: GameNotification) async throws
}

@MainActor final class EmptyGameNotificationCenter: GameNotificationCenter {
    var onResponse: (@MainActor @Sendable (String) -> Void)?
    func authorizationState() async -> GameNotificationAuthorization { .notDetermined }
    func requestAuthorization() async throws -> Bool { false }
    func deliver(_ notification: GameNotification) async throws {}
}

@MainActor final class SystemGameNotificationCenter: NSObject, GameNotificationCenter, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    var onResponse: (@MainActor @Sendable (String) -> Void)?

    override init() {
        center = UNUserNotificationCenter.current()
        super.init()
        center.delegate = self
    }

    func authorizationState() async -> GameNotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .authorized, .provisional, .ephemeral: .allowed
        case .denied: .denied
        @unknown default: .denied
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func deliver(_ notification: GameNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title; content.body = notification.body
        content.sound = .default
        content.userInfo = ["gameID": notification.gameID]
        try await center.add(UNNotificationRequest(identifier: notification.id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        // Dismissing a banner must not navigate or activate the launcher.
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            let id = response.notification.request.content.userInfo["gameID"] as? String else {
            completionHandler(); return
        }
        Task { @MainActor [weak self] in self?.onResponse?(id) }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // A request queued while inactive may arrive after activation.
        completionHandler([])
    }

    static func revealLauncher() {
        NSApp.unhide(nil)
        let window = NSApp.windows.first { $0.identifier?.rawValue == "launcher" || $0.title == "MacGacha" }
            ?? NSApp.windows.first { $0.canBecomeMain && !$0.isExcludedFromWindowsMenu }
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.lo7ted.macgacha") else { return }
        NSWorkspace.shared.open(url)
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
    let paths: AppPaths
    private func read(_ fs: ContainedFileSystem) throws -> Set<Marker> {
        let path = try SafeRelativePath("notification-history.json")
        guard try fs.itemType(at: path) != nil else { return [] }
        return try JSONDecoder().decode(Set<Marker>.self, from: fs.readFile(at: path, maxBytes: 1_048_576))
    }
    func contains(_ marker: Marker) throws -> Bool {
        try read(ContainedFileSystem(root: paths.root)).contains(marker)
    }
    func claim(_ marker: Marker) throws -> Bool {
        let fs = try ContainedFileSystem(root: paths.root)
        var markers = try read(fs)
        guard markers.insert(marker).inserted else { return false }
        try save(markers, fs: fs)
        return true
    }
    func release(_ marker: Marker) throws {
        let fs = try ContainedFileSystem(root: paths.root)
        var markers = try read(fs)
        markers.remove(marker)
        try save(markers, fs: fs)
    }
    private func save(_ markers: Set<Marker>, fs: ContainedFileSystem) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(markers.sorted {
            if $0.gameID != $1.gameID { return $0.gameID < $1.gameID }
            if $0.version != $1.version { return $0.version < $1.version }
            return $0.kind.rawValue < $1.kind.rawValue
        })
        guard data.count <= 1_048_576 else { throw LauncherError.io("Notification history limit") }
        try fs.writeAtomically(data, to: SafeRelativePath("notification-history.json"))
    }
}
