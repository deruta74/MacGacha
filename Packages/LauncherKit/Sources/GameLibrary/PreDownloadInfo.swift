// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

/// A cache overlay, independent of the installed build and normal pending work.
public struct PreDownloadInfo: Sendable, Equatable {
    public enum State: String, Sendable { case unavailable, available, paused, ready }
    public let state: State
    public let version: String?
    public let bytes: Int64
    public let downloaded: Int64
    public let planID: SafeIdentifier?
    public let planDigest: Digest?
    public let canDelete: Bool
    public init(state: State, version: String? = nil, bytes: Int64 = 0, downloaded: Int64 = 0,
        planID: SafeIdentifier? = nil, planDigest: Digest? = nil, canDelete: Bool = false) {
        self.state = state; self.version = version; self.bytes = bytes; self.downloaded = downloaded
        self.planID = planID; self.planDigest = planDigest; self.canDelete = canDelete
    }
    public static let unavailable = PreDownloadInfo(state: .unavailable)
}
