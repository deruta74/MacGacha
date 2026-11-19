// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import Sophon

/// An installation with no version is adopted locally and requires an update.
public struct SandboxInstallation: Codable, Sendable, Equatable {
    public let version: String?
    public let listPath: SafeRelativePath
    public init(version: String?, listPath: SafeRelativePath) throws {
        guard version.map(SandboxPackage.isValidVersion) ?? true else { throw LauncherError.io("Invalid sandbox version") }
        try SandboxFiles.validateListPath(listPath)
        self.version = version; self.listPath = listPath
    }
    private enum CodingKeys: String, CodingKey { case version, listPath }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(version: c.decodeIfPresent(String.self, forKey: .version), listPath: c.decode(SafeRelativePath.self, forKey: .listPath))
    }
}

public enum SandboxState: Sendable, Equatable {
    case notInstalled(size: Int64)
    case installed(version: String)
    case outdated(installed: String?, available: String, size: Int64)
}
