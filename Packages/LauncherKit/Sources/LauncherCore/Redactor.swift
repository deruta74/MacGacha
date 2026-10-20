import Foundation

public enum Redactor {
    private static let sensitiveFragments = ["token", "ticket", "password", "passwd", "secret", "session",
        "cookie", "authkey", "auth_key", "authorization", "stoken", "ltoken", "ltuid", "ltmid", "account_mid", "account_id"]
    private static let legacyKeys: Set<String> = ["uid", "accountid", "user_id", "userid"]
    // Match keys once, then apply the same sensitivity predicate to every representation.
    private static let jsonKeys = try! NSRegularExpression(
        pattern: #"(?:AnyHashable\([\t ]*)?"((?:\\.|[^"\\])*)"(?:[\t ]*\))?[\t ]*[:=]\s*"#)
    private static let singleQuotedKeys = try! NSRegularExpression(
        pattern: #"(?:AnyHashable\([\t ]*)?'([^']*)'(?:[\t ]*\))?[\t ]*[:=][\t ]*"#)
    private static let acronymBoundary = try! NSRegularExpression(pattern: "([A-Z]+)([A-Z][a-z])")
    private static let camelBoundary = try! NSRegularExpression(pattern: "([a-z0-9])([A-Z])")
    private static let assignments = try! NSRegularExpression(
        pattern: #"(?i)((?:%[0-9a-f]{2})+[a-z0-9_-]+|(?<![a-z0-9_-])[a-z0-9_-]+)[\t ]*(?:=|%3d)[\t ]*"#)
    private static let colonValues = try! NSRegularExpression(
        pattern: #"(?i)(?<![a-z0-9_-])([a-z0-9_-]+)[\t ]*:[\t ]*"#)

    public static func redact(_ s: String) -> String {
        redact(s, depth: 0)
    }

    private static func redact(_ s: String, depth: Int) -> String {
        guard depth < 32 else { return "<redacted>" }
        if let data = s.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let sanitized = try? JSONSerialization.data(withJSONObject: redactJSON(object, depth: depth),
               options: [.sortedKeys, .withoutEscapingSlashes]) {
            return String(decoding: sanitized, as: UTF8.self)
        }
        return redactText(redactEscapedStrings(s, depth: depth))
    }

    /// Redacts mixed text/JSON logs across line boundaries, retaining their trailing line endings.
    public static func redactLog(_ text: String) -> String {
        let endings = Array(text.utf8.reversed().prefix { $0 == 10 || $0 == 13 }.reversed())
        let body = String(decoding: text.utf8.dropLast(endings.count), as: UTF8.self)
        let suffix = String(decoding: endings, as: UTF8.self)
        if (try? JSONSerialization.jsonObject(with: Data(body.utf8))) != nil {
            return redact(body) + suffix
        }
        // Only JSON values are replaced globally; per-line parsing protects JSONL string syntax.
        let multiline = replaceValues(in: body, matching: jsonKeys, json: true)
        return multiline.components(separatedBy: "\n").map { redact($0) }.joined(separator: "\n") + suffix
    }

    public static func redact(metadata: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for key in metadata.keys.sorted() {
            if key.utf8.count > 256 {
                let safeKey = uniqueKey("<omitted \(key.utf8.count) byte key>", in: result)
                result[safeKey] = "<redacted>"
                continue
            }
            let processedKey = redactText(key)
            let baseKey = processedKey.utf8.count > 256 ? "<omitted \(processedKey.utf8.count) byte key>" : processedKey
            let safeKey = uniqueKey(baseKey, in: result, maxBytes: 256)
            result[safeKey] = isSensitive(key) ? "<redacted>" : redact(metadata[key] ?? "")
        }
        return result
    }

    private static func normalized(_ key: String) -> String {
        var key = key
        while key.utf8.count >= 3, key.hasPrefix("%"), UInt8(key.dropFirst().prefix(2), radix: 16) != nil {
            key.removeFirst(3)
        }
        key = acronymBoundary.stringByReplacingMatches(in: key, range: NSRange(key.startIndex..., in: key), withTemplate: "$1_$2")
        key = camelBoundary.stringByReplacingMatches(in: key, range: NSRange(key.startIndex..., in: key), withTemplate: "$1_$2")
        return key.lowercased().replacingOccurrences(of: "-", with: "_")
    }

    private static func isSensitive(_ key: String) -> Bool {
        let plain = key.lowercased().replacingOccurrences(of: "-", with: "_")
        let snake = normalized(key)
        return legacyKeys.contains(plain) || legacyKeys.contains(snake)
            || sensitiveFragments.contains { plain.contains($0) || snake.contains($0) }
    }

    static func uniqueKey<Value>(_ key: String, in dictionary: [String: Value], maxBytes: Int = .max) -> String {
        var candidate = key
        var suffix = 2
        while dictionary[candidate] != nil {
            let ending = "#\(suffix)"
            var prefix = ""
            for scalar in key.unicodeScalars {
                guard prefix.utf8.count + scalar.utf8.count <= maxBytes - ending.utf8.count else { break }
                prefix.unicodeScalars.append(scalar)
            }
            candidate = prefix + ending
            suffix += 1
        }
        return candidate
    }

    private static func redactJSON(_ object: Any, depth: Int) -> Any {
        guard depth < 32 else { return "<redacted>" }
        if let dictionary = object as? [String: Any] {
            var result: [String: Any] = [:]
            for key in dictionary.keys.sorted() {
                let safeKey = uniqueKey(redactText(key), in: result)
                result[safeKey] = isSensitive(key) ? "<redacted>" : redactJSON(dictionary[key]!, depth: depth + 1)
            }
            return result
        }
        if let array = object as? [Any] { return array.map { redactJSON($0, depth: depth + 1) } }
        if let string = object as? String { return redact(string, depth: depth + 1) }
        return object
    }

    private static func redactText(_ s: String) -> String {
        let quoted = replaceValues(in: s, matching: jsonKeys, json: true)
        let result = replaceValues(in: quoted, matching: singleQuotedKeys, json: false)
        let assignmentsRedacted = replaceValues(in: result, matching: assignments, json: false)
        return replaceValues(in: assignmentsRedacted, matching: colonValues, json: false, colon: true)
    }

    private static func replaceValues(in text: String, matching expression: NSRegularExpression,
        json: Bool, colon: Bool = false) -> String {
        let bytes = Array(text.utf8)
        var result: [UInt8] = []
        var copied = 0
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let keyRange = Range(match.range(at: 1), in: text) else { continue }
            let rawKey = String(text[keyRange])
            let key = json && rawKey.contains("\\")
                ? (try? JSONDecoder().decode(String.self, from: Data(("\"" + rawKey + "\"").utf8))) ?? rawKey : rawKey
            guard isSensitive(key) else { continue }
            let prefixStart = text.utf8.distance(from: text.utf8.startIndex, to: range.lowerBound)
            guard prefixStart >= copied else { continue }
            let start = text.utf8.distance(from: text.utf8.startIndex, to: range.upperBound)
            let preceding = colon ? bytes[..<prefixStart].last(where: { $0 != 9 && $0 != 32 }) : nil
            let headerLine = colon && (preceding == nil || preceding == 10 || preceding == 13)
            let lowerKey = key.lowercased()
            let query = !json && (prefixStart > 0 && (bytes[prefixStart - 1] == 63 || bytes[prefixStart - 1] == 38)
                || rawKey.lowercased().contains("%3f") || rawKey.lowercased().contains("%26"))
            let wholeLine = !json && !query && (headerLine || lowerKey.contains("authorization") || lowerKey.contains("cookie"))
            let end: Int
            if query {
                end = queryValueEnd(in: bytes, start: start)
            } else if wholeLine {
                end = bytes[start...].firstIndex { $0 == 10 || $0 == 13 } ?? bytes.count
            } else {
                end = valueEnd(in: bytes, start: start, json: json)
            }
            guard end > start else { continue }
            result.append(contentsOf: bytes[copied..<start])
            result.append(contentsOf: (json ? "\"<redacted>\"" : "<redacted>").utf8)
            copied = end
        }
        result.append(contentsOf: bytes[copied...])
        return String(decoding: result, as: UTF8.self)
    }

    private static func valueEnd(in bytes: [UInt8], start: Int, json: Bool, authScheme: Bool = true) -> Int {
        guard start < bytes.count else { return start }
        if bytes[start] == 123 || bytes[start] == 91 || bytes[start] == 40 { return balancedEnd(in: bytes, start: start) }
        var identifierEnd = start
        while identifierEnd < bytes.count && (bytes[identifierEnd] == 95 || bytes[identifierEnd] == 46
            || (65...90).contains(bytes[identifierEnd]) || (97...122).contains(bytes[identifierEnd])
            || (48...57).contains(bytes[identifierEnd])) { identifierEnd += 1 }
        if identifierEnd > start, identifierEnd < bytes.count, bytes[identifierEnd] == 40 {
            return balancedEnd(in: bytes, start: identifierEnd)
        }
        let scheme = String(decoding: bytes[start..<identifierEnd], as: UTF8.self).lowercased()
        if authScheme, ["bearer", "basic", "digest"].contains(scheme), identifierEnd < bytes.count,
           bytes[identifierEnd] == 32 || bytes[identifierEnd] == 9 {
            var valueStart = identifierEnd
            while valueStart < bytes.count && (bytes[valueStart] == 32 || bytes[valueStart] == 9) { valueStart += 1 }
            return valueEnd(in: bytes, start: valueStart, json: json, authScheme: false)
        }
        if bytes[start] == 34 || bytes[start] == 39 {
            return quotedEnd(in: bytes, start: start, quote: bytes[start], escapedDelimiter: false)
        }
        if bytes[start] == 92, start + 1 < bytes.count, bytes[start + 1] == 34 || bytes[start + 1] == 39 {
            return quotedEnd(in: bytes, start: start, quote: bytes[start + 1], escapedDelimiter: true)
        }
        var end = start
        while end < bytes.count {
            let byte = bytes[end]
            if byte == 9 || byte == 10 || byte == 13 || byte == 32 || byte == 38 || byte == 59 || byte == 35
                || isEncodedTerminator(in: bytes, at: end) { break }
            if byte == 44 || byte == 125 || byte == 93 || (!json && byte == 41) { break }
            end += 1 // Quotes in the middle of an unquoted token are part of that token.
        }
        return end
    }

    private static func isEncodedTerminator(in bytes: [UInt8], at offset: Int) -> Bool {
        guard offset + 2 < bytes.count, bytes[offset] == 37 else { return false }
        let high = bytes[offset + 1]
        let low = bytes[offset + 2] | 32
        return (high == 50 && (low == 54 || low == 51)) || (high == 51 && low == 98)
    }

    private static func queryValueEnd(in bytes: [UInt8], start: Int) -> Int {
        var end = start
        while end < bytes.count {
            if bytes[end] == 38 || bytes[end] == 35 || bytes[end] <= 32 || isEncodedTerminator(in: bytes, at: end) { break }
            end += 1
        }
        return end
    }

    private static func jsonString(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? "\"<redacted>\""
    }

    private static func redactEscapedStrings(_ text: String, depth: Int) -> String {
        guard text.contains("\\") else { return text }
        // A second escaping layer may leave an entire object with escaped quotes, without outer quotes.
        if text.contains("\\\""),
           let decoded = try? JSONDecoder().decode(String.self, from: Data(("\"" + text + "\"").utf8)), decoded != text {
            let sanitized = redact(decoded, depth: depth + 1)
            return sanitized == decoded ? text : String(jsonString(sanitized).dropFirst().dropLast())
        }
        let bytes = Array(text.utf8)
        var result: [UInt8] = []
        var copied = 0
        var cursor = 0
        while cursor < bytes.count {
            guard bytes[cursor] == 34 else { cursor += 1; continue }
            let end = quotedEnd(in: bytes, start: cursor, quote: 34, escapedDelimiter: false)
            let literal = String(decoding: bytes[cursor..<end], as: UTF8.self)
            if literal.contains("\\"), let decoded = try? JSONDecoder().decode(String.self, from: Data(literal.utf8)) {
                let sanitized = redact(decoded, depth: depth + 1)
                if sanitized != decoded {
                    result.append(contentsOf: bytes[copied..<cursor])
                    result.append(contentsOf: jsonString(sanitized).utf8)
                    copied = end
                }
            }
            cursor = max(cursor + 1, end)
        }
        result.append(contentsOf: bytes[copied...])
        return String(decoding: result, as: UTF8.self)
    }

    private static func quotedEnd(in bytes: [UInt8], start: Int, quote: UInt8, escapedDelimiter: Bool) -> Int {
        var cursor = start + (escapedDelimiter ? 2 : 1)
        while cursor < bytes.count {
            if bytes[cursor] == 10 || bytes[cursor] == 13 { return cursor }
            if bytes[cursor] == 92 {
                if escapedDelimiter {
                    let run = cursor
                    while cursor < bytes.count && bytes[cursor] == 92 { cursor += 1 }
                    if cursor < bytes.count && bytes[cursor] == quote {
                        if cursor - run == 1 { return cursor + 1 }
                        cursor += 1
                    }
                } else {
                    cursor += 1
                    if cursor < bytes.count && bytes[cursor] != 10 && bytes[cursor] != 13 { cursor += 1 }
                }
            } else if !escapedDelimiter && bytes[cursor] == quote {
                return cursor + 1
            } else {
                cursor += 1
            }
        }
        return cursor // An unterminated quote owns the remainder of its line/input.
    }

    private static func balancedEnd(in bytes: [UInt8], start: Int) -> Int {
        var closers: [UInt8] = []
        var quote: UInt8?
        var cursor = start
        while cursor < bytes.count {
            let byte = bytes[cursor]
            if let delimiter = quote {
                if byte == 92 { cursor += 1 }
                else if byte == delimiter { quote = nil }
            } else if byte == 34 || byte == 39 {
                quote = byte
            } else if byte == 123 || byte == 91 || byte == 40 {
                guard closers.count < 128 else { return bytes.count }
                closers.append(byte == 123 ? 125 : byte == 91 ? 93 : 41)
            } else if byte == 125 || byte == 93 || byte == 41 {
                guard closers.last == byte else { return bytes.count }
                closers.removeLast()
                if closers.isEmpty { return cursor + 1 }
            }
            cursor += 1
        }
        return bytes.count // Malformed composite values fail closed.
    }
}
