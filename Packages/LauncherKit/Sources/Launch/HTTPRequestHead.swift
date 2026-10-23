// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Network

// Parsing and framing are independent of transport. No URL normalization is
// allowed to change an authority before the block-list decision.
struct ProxyHTTPError: Error {}
enum HTTPBodyKind: Equatable { case none, length(Int64), chunked, closeDelimited }
struct HTTPAuthority: Equatable {
    let host: String
    let port: UInt16
    var text: String { "\(host.contains(":") ? "[\(host)]" : host):\(port)" }
    init(_ raw: String, defaultPort: UInt16? = nil) throws {
        guard !raw.isEmpty, raw.utf8.allSatisfy({ $0 > 32 && $0 < 127 }), !raw.contains("@"), !raw.contains("\\") else { throw ProxyHTTPError() }
        var name: String, portText: String?
        if raw.first == "[" {
            guard let close = raw.firstIndex(of: "]"), let address = IPv6Address(String(raw[raw.index(after: raw.startIndex)..<close])) else { throw ProxyHTTPError() }
            name = address.debugDescription.lowercased()
            let rest = raw[raw.index(after: close)...]
            guard rest.isEmpty || rest.first == ":" else { throw ProxyHTTPError() }
            portText = rest.isEmpty ? nil : String(rest.dropFirst())
        } else {
            let fields = raw.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count <= 2 else { throw ProxyHTTPError() }
            name = String(fields[0]).lowercased()
            if name.hasSuffix(".") { name.removeLast() }
            guard !name.isEmpty, name.utf8.count <= 253,
                name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                    !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                        && label.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 })
                }) else { throw ProxyHTTPError() }
            if name.allSatisfy({ $0.isNumber || $0 == "." }), name.contains("."), IPv4Address(name) == nil { throw ProxyHTTPError() }
            portText = fields.count == 2 ? String(fields[1]) : nil
        }
        if let portText {
            guard !portText.isEmpty, portText.utf8.allSatisfy({ (48...57).contains($0) }), let value = UInt16(portText), value > 0 else { throw ProxyHTTPError() }
            port = value
        } else {
            guard let defaultPort else { throw ProxyHTTPError() }
            port = defaultPort
        }
        host = name
    }
}

struct HTTPFields {
    let first: String
    let fields: [(String, String)]
    let connection: Set<String>
    let framing: HTTPBodyKind
    let transfer: String?
    let length: Int64?
    init(_ data: Data) throws {
        guard data.count <= 65_536, data.suffix(4) == Data([13, 10, 13, 10]),
            let raw = String(data: data.dropLast(4), encoding: .isoLatin1) else { throw ProxyHTTPError() }
        try Self.checkLineEndings(data)
        let lines = raw.components(separatedBy: "\r\n")
        guard let first = lines.first, !first.isEmpty else { throw ProxyHTTPError() }
        self.first = first
        var fields: [(String, String)] = []
        for line in lines.dropFirst() { fields.append(try Self.field(line)) }
        self.fields = fields
        let lengths = fields.filter { $0.0 == "content-length" }.map(\.1)
        let transfers = fields.filter { $0.0 == "transfer-encoding" }.map(\.1)
        guard lengths.count <= 1, lengths.isEmpty || transfers.isEmpty else { throw ProxyHTTPError() }
        if let value = lengths.first {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int64(value) else { throw ProxyHTTPError() }
            length = count; transfer = nil; framing = .length(count)
        } else if !transfers.isEmpty {
            let tokens = transfers.joined(separator: ",").split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard tokens.last == "chunked", tokens.dropLast().allSatisfy({ Self.isToken($0) && $0 != "chunked" }) else { throw ProxyHTTPError() }
            length = nil; transfer = tokens.joined(separator: ", "); framing = .chunked
        } else { length = nil; transfer = nil; framing = .none }
        let connections = fields.filter { $0.0 == "connection" }.map(\.1).joined(separator: ",")
        if connections.isEmpty { connection = [] }
        else {
            let tokens = connections.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard tokens.allSatisfy(Self.isToken), Set(tokens).isDisjoint(with: ["host", "content-length", "transfer-encoding", "expect"]) else { throw ProxyHTTPError() }
            connection = Set(tokens)
        }
    }
    static func field(_ line: String) throws -> (String, String) {
        guard let colon = line.firstIndex(of: ":"), isToken(String(line[..<colon])),
            line.utf8.allSatisfy({ $0 == 9 || $0 >= 32 && $0 != 127 }) else { throw ProxyHTTPError() }
        return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }
    static func isToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || "!#$%&'*+-.^_`|~".utf8.contains($0) }
    }
    static func checkLineEndings(_ data: Data) throws {
        let bytes = Array(data)
        for i in bytes.indices {
            if bytes[i] == 10 && (i == 0 || bytes[i - 1] != 13) { throw ProxyHTTPError() }
            if bytes[i] == 13 && i + 1 < bytes.count && bytes[i + 1] != 10 { throw ProxyHTTPError() }
        }
    }
    func encoded(first: String, extra: [String], includeLength: Bool = true, includeTransfer: Bool = true) -> Data {
        let hop: Set<String> = ["connection", "keep-alive", "proxy-connection", "proxy-authorization", "proxy-authenticate", "te", "trailer", "upgrade", "host", "content-length", "transfer-encoding"]
        var lines = [first]
        for (key, value) in fields where !hop.contains(key) && !connection.contains(key) {
            // Field names are case insensitive; conventional spelling is only
            // for readability. Values round-trip as octets, including obs-text.
            lines.append("\(key.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "-")): \(value)")
        }
        if includeLength, let length { lines.append("Content-Length: \(length)") }
        if includeTransfer, let transfer { lines.append("Transfer-Encoding: \(transfer)") }
        lines += extra
        return (lines.joined(separator: "\r\n") + "\r\n\r\n").data(using: .isoLatin1)!
    }
}

struct HTTPRequestHead {
    let method: String
    let authority: HTTPAuthority
    let body: HTTPBodyKind
    let forwarded: Data
    let close: Bool
    let expectContinue: Bool
    var isConnect: Bool { method == "CONNECT" }
    init(_ data: Data) throws {
        let fields = try HTTPFields(data)
        let line = fields.first.split(separator: " ", omittingEmptySubsequences: false)
        guard line.count == 3, HTTPFields.isToken(String(line[0])), ["HTTP/1.1", "HTTP/1.0"].contains(line[2]),
            line[1].utf8.allSatisfy({ $0 > 32 && $0 < 127 }), !line[1].contains("#"),
            fields.fields.filter({ $0.0 == "host" }).count <= 1,
            !fields.fields.contains(where: { $0.0 == "upgrade" }), !fields.connection.contains("upgrade") else { throw ProxyHTTPError() }
        method = String(line[0])
        let target = String(line[1])
        var origin = ""
        if method == "CONNECT" {
            authority = try HTTPAuthority(target)
            guard fields.framing == .none || fields.framing == .length(0) else { throw ProxyHTTPError() }
        } else {
            guard target.lowercased().hasPrefix("http://") else { throw ProxyHTTPError() }
            let rest = target.dropFirst(7)
            let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? rest.endIndex
            authority = try HTTPAuthority(String(rest[..<end]), defaultPort: 80)
            origin = end == rest.endIndex ? "/" : (rest[end] == "?" ? "/" : "") + rest[end...]
        }
        body = fields.framing
        close = fields.connection.contains("close") || line[2] == "HTTP/1.0" && !fields.connection.contains("keep-alive")
        let expectations = fields.fields.filter { $0.0 == "expect" }.map { $0.1.lowercased() }
        guard expectations.isEmpty || expectations == ["100-continue"] else { throw ProxyHTTPError() }
        expectContinue = expectations == ["100-continue"] && body != .none && body != .length(0)
        forwarded = fields.encoded(first: "\(method) \(origin) HTTP/1.1", extra: ["Host: \(authority.text)", "Connection: close"])
    }
}

struct HTTPResponseHead {
    let status: Int
    let body: HTTPBodyKind
    private let fields: HTTPFields
    init(_ data: Data, method: String) throws {
        fields = try HTTPFields(data)
        let line = fields.first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard line.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(line[0]), line[1].count == 3,
            line[1].utf8.allSatisfy({ (48...57).contains($0) }), let status = Int(line[1]), (100...599).contains(status), status != 101,
            fields.first.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }) else { throw ProxyHTTPError() }
        self.status = status
        if method == "HEAD" || status < 200 || status == 204 || status == 304 { body = .none }
        else { body = fields.framing == .none ? .closeDelimited : fields.framing }
    }
    func forwarded(close: Bool) -> Data {
        fields.encoded(first: fields.first, extra: ["Connection: \(close ? "close" : "keep-alive")"],
            includeLength: status >= 200 && status != 204, includeTransfer: status >= 200 && status != 204)
    }
}

/// Incremental framing retains at most a read buffer and one bounded line.
/// Chunked bodies are validated and relayed unchanged, never decoded/reencoded.
struct HTTPBodyFrame {
    private enum Chunk { case size, bytes(Int64), ending, trailers, done }
    private let kind: HTTPBodyKind
    private var remaining: Int64 = 0
    private var chunk = Chunk.size
    private var trailerBytes = 0
    private(set) var done = false
    init(_ kind: HTTPBodyKind) {
        self.kind = kind
        if case .length(let length) = kind { remaining = length; done = length == 0 }
        if kind == .none { done = true }
    }
    mutating func take(from buffer: inout Data, eof: Bool) throws -> Data? {
        if done { return nil }
        switch kind {
        case .none: done = true; return nil
        case .length:
            if !buffer.isEmpty {
                let count = Int(min(remaining, Int64(buffer.count)))
                remaining -= Int64(count); done = remaining == 0
                return Self.consume(count, from: &buffer)
            }
        case .closeDelimited:
            if !buffer.isEmpty { return Self.consume(buffer.count, from: &buffer) }
            if eof { done = true; return nil }
        case .chunked:
            switch chunk {
            case .size, .trailers:
                guard let range = buffer.range(of: Data([13, 10])) else {
                    try HTTPFields.checkLineEndings(buffer)
                    guard buffer.count <= 8192 else { throw ProxyHTTPError() }
                    if eof { throw ProxyHTTPError() }; return nil
                }
                let count = buffer.distance(from: buffer.startIndex, to: range.upperBound)
                guard count <= 8192 else { throw ProxyHTTPError() }
                let line = Self.consume(count, from: &buffer)
                try HTTPFields.checkLineEndings(line)
                let text = String(data: line.dropLast(2), encoding: .isoLatin1)!
                if case .trailers = chunk {
                    trailerBytes += count
                    guard trailerBytes <= 65_536 else { throw ProxyHTTPError() }
                    if text.isEmpty { chunk = .done; done = true }
                    else {
                        let field = try HTTPFields.field(text)
                        guard !["content-length", "transfer-encoding", "host", "connection", "trailer", "upgrade", "proxy-authorization"].contains(field.0) else { throw ProxyHTTPError() }
                    }
                } else {
                    let size = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                    guard !size.isEmpty, size.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                        let length = Int64(size, radix: 16), text.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else { throw ProxyHTTPError() }
                    chunk = length == 0 ? .trailers : .bytes(length)
                }
                return line
            case .bytes(let remaining):
                if !buffer.isEmpty {
                    let count = Int(min(remaining, Int64(buffer.count)))
                    chunk = remaining == count ? .ending : .bytes(remaining - Int64(count))
                    return Self.consume(count, from: &buffer)
                }
            case .ending:
                guard buffer.count >= 2 else { if eof { throw ProxyHTTPError() }; return nil }
                guard buffer.prefix(2) == Data([13, 10]) else { throw ProxyHTTPError() }
                chunk = .size; return Self.consume(2, from: &buffer)
            case .done: done = true; return nil
            }
        }
        if eof { throw ProxyHTTPError() }
        return nil
    }
    static func consume(_ count: Int, from buffer: inout Data) -> Data {
        let result = Data(buffer.prefix(count)); buffer.removeFirst(count); return result
    }
}
