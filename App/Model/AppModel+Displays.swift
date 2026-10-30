// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import ColorSync
import CoreGraphics
import Foundation
import Launch

@MainActor extension AppModel {
    func refreshConnectedDisplays() {
        let names = displayNames()
        connectedDisplays = displayProbe.connectedDisplays().map {
            ConnectedDisplay(id: $0.id, name: names[$0.id] ?? $0.name, isMain: $0.isMain)
        }
    }
}

@MainActor enum ScreenDisplayNames {
    static func current() -> [String: String] {
        var names: [String: String] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
                let id = CFUUIDCreateString(nil, uuid) else { continue }
            names[id as String] = screen.localizedName
        }
        return names
    }
}

/// The token is immutable after registration; NotificationCenter owns delivery.
/// Removal is safe on any executor, including the model's nonisolated deinit.
final class ScreenChangeObservation: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: any NSObjectProtocol
    @MainActor init(center: NotificationCenter, model: AppModel) {
        self.center = center
        token = center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil) { [weak model] _ in
            Task { @MainActor [weak model] in model?.refreshConnectedDisplays() }
        }
    }
    deinit { center.removeObserver(token) }
}
