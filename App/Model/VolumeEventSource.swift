// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import Foundation

enum VolumeEvent: Sendable {
    case mounted(URL?), unmounted(URL?)
    var volume: URL? { switch self { case .mounted(let url), .unmounted(let url): url } }
    var isUnmount: Bool { if case .unmounted = self { true } else { false } }
}

@MainActor protocol VolumeEventSource {
    /// The returned observation removes its callbacks when released.
    func observe(_ receive: @escaping @MainActor @Sendable (VolumeEvent) -> Void) -> any Sendable
}

@MainActor struct WorkspaceVolumeEventSource: VolumeEventSource {
    let center: NotificationCenter
    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter) { self.center = center }
    func observe(_ receive: @escaping @MainActor @Sendable (VolumeEvent) -> Void) -> any Sendable {
        WorkspaceVolumeObservation(center: center, receive: receive)
    }
}

/// Notification tokens are immutable and NotificationCenter supports removal on any thread.
private final class WorkspaceVolumeObservation: @unchecked Sendable {
    private let center: NotificationCenter
    private let tokens: [any NSObjectProtocol]
    init(center: NotificationCenter, receive: @escaping @MainActor @Sendable (VolumeEvent) -> Void) {
        self.center = center
        tokens = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { notification in
                let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                let event: VolumeEvent = name == NSWorkspace.didMountNotification ? .mounted(url) : .unmounted(url)
                Task { @MainActor in receive(event) }
            }
        }
    }
    deinit { for token in tokens { center.removeObserver(token) } }
}
