import Foundation

public struct SafeRelativePath: Hashable, Codable, Sendable, CustomStringConvertible {
    public let components: [String]

    public init(_ raw: String) throws {
        let bytes = raw.utf8
        let components = bytes.split(separator: 0x2f, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard !bytes.isEmpty, bytes.first != 0x2f, !bytes.contains(0x00), !bytes.contains(0x5c),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw LauncherError.unsafePath(raw)
        }
        // Keep a separator from visually combining with the next component.
        guard components.allSatisfy({ $0.unicodeScalars.first?.properties.isGraphemeExtend != true }) else {
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
