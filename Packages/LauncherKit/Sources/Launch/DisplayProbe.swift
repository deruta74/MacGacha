// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import ColorSync
import CoreGraphics
import Foundation

public struct ConnectedDisplay: Sendable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let isMain: Bool
    public init(id: String, name: String, isMain: Bool) { self.id = id; self.name = name; self.isMain = isMain }
}

public protocol DisplayProbe: Sendable {
    /// Wine numbers the main display first; a failed probe returns an empty list.
    func connectedDisplays() -> [ConnectedDisplay]
}

public struct FixedDisplayProbe: DisplayProbe {
    private let displays: [ConnectedDisplay]
    public init(_ displays: [ConnectedDisplay] = []) { self.displays = displays }
    public func connectedDisplays() -> [ConnectedDisplay] { displays }
}

/// CoreGraphics-only: callers on launch supervision never need the main actor.
/// The app enriches names from NSScreen on the main actor.
public struct SystemDisplayProbe: DisplayProbe {
    package enum DisplayList: Sendable, Equatable { case active, online }
    package typealias Enumeration = @Sendable (DisplayList) -> [(display: ConnectedDisplay, mirrors: Bool)]
    private let enumerate: Enumeration
    public init() { enumerate = Self.systemDisplays }
    package init(enumerate: @escaping Enumeration) { self.enumerate = enumerate }

    // Wine's cocoa_display.m enumerates online displays, including sleeping ones.
    public func connectedDisplays() -> [ConnectedDisplay] { Self.ordered(enumerate(.online)) }

    private static func systemDisplays(_ list: DisplayList) -> [(display: ConnectedDisplay, mirrors: Bool)] {
        let getDisplayList = list == .online ? CGGetOnlineDisplayList : CGGetActiveDisplayList
        var count: UInt32 = 0
        guard getDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard getDisplayList(count, &ids, &count) == .success else { return [] }
        let main = CGMainDisplayID()
        var candidates: [(display: ConnectedDisplay, mirrors: Bool)] = []
        for id in ids.prefix(Int(count)) {
            let mirrors = CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay
            // Keep the mirror source; only displays mirroring another are skipped.
            if mirrors { continue }
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                let name = CFUUIDCreateString(nil, uuid) else { return [] }
            candidates.append((ConnectedDisplay(id: name as String, name: "", isMain: id == main), false))
        }
        return candidates
    }

    /// Stable partition: preserve CoreGraphics order among the non-main displays.
    public static func ordered(_ candidates: [(display: ConnectedDisplay, mirrors: Bool)]) -> [ConnectedDisplay] {
        let displays = candidates.filter { !$0.mirrors }.map(\.display)
        return displays.filter(\.isMain) + displays.filter { !$0.isMain }
    }
}
