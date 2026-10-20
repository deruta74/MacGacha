import Foundation

public struct AppPaths: Sendable {
    public let root: URL
    public let stagingName = ".macgacha-staging"

    public init(root: URL) {
        self.root = root
    }

    public static func standard() -> AppPaths {
        AppPaths(root: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MacGacha", isDirectory: true))
    }

    public var runtimes: URL { root.appendingPathComponent("Runtimes", isDirectory: true) }
    public var prefixes: URL { root.appendingPathComponent("Prefixes", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    public var consent: URL { root.appendingPathComponent("consent.json") }

    public func ensureExists(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw LauncherError.io(error.localizedDescription)
        }
    }
}
