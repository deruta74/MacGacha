import Foundation

public struct SafeRelativePath: Hashable, Codable, Sendable, CustomStringConvertible {
    public let components: [String]

    public init(_ raw: String) throws {
        let components = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !raw.isEmpty, !raw.hasPrefix("/"), !raw.contains("\u{0}"), !raw.contains("\\"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw LauncherError.unsafePath(raw)
        }
        self.components = components
    }

    public var description: String {
        components.joined(separator: "/")
    }

    public func resolved(against root: URL) -> URL {
        components.reduce(root) { $0.appendingPathComponent($1) }
    }

    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
