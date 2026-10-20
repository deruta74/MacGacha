import Foundation

public enum Redactor {
    private static let sensitiveFragments = ["token", "ticket", "password", "passwd", "secret", "session",
        "cookie", "authkey", "auth_key", "authorization", "stoken", "ltoken", "ltuid", "ltmid", "account_mid", "account_id"]
    private static let legacyKeys: Set<String> = ["uid", "accountid", "user_id", "userid"]
    // Match keys once, then apply the same sensitivity predicate to every representation.
    private static let jsonKeys = try! NSRegularExpression(pattern: #""((?:\\.|[^"\\])*)"\s*:\s*"#)
    private static let assignments = try! NSRegularExpression(
        pattern: #"(?i)(?<![a-z0-9_-])([a-z0-9_-]+)[\t ]*(?:=|%3d)[\t ]*"#)
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
        return redactText(s)
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
            let safeKey = uniqueKey(redactText(key), in: result)
            result[safeKey] = isSensitive(key) ? "<redacted>" : redact(metadata[key] ?? "")
        }
        return result
    }

    private static func normalized(_ key: String) -> String {
        key.lowercased().replacingOccurrences(of: "-", with: "_")
    }

    private static func isSensitive(_ key: String) -> Bool {
        let key = normalized(key)
        return legacyKeys.contains(key) || sensitiveFragments.contains { key.contains($0) }
    }

    static func uniqueKey<Value>(_ key: String, in dictionary: [String: Value]) -> String {
        var candidate = key
        var suffix = 2
        while dictionary[candidate] != nil {
            candidate = "\(key)#\(suffix)"
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
        let result = replaceValues(in: s, matching: jsonKeys, json: true)
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
            let key = json ? (try? JSONDecoder().decode(String.self, from: Data(("\"" + rawKey + "\"").utf8))) ?? rawKey : rawKey
            guard isSensitive(key) else { continue }
            let prefixStart = text.utf8.distance(from: text.utf8.startIndex, to: range.lowerBound)
            guard prefixStart >= copied else { continue }
            let start = text.utf8.distance(from: text.utf8.startIndex, to: range.upperBound)
            let preceding = colon ? bytes[..<prefixStart].last(where: { $0 != 9 && $0 != 32 }) : nil
            let headerLine = colon && (preceding == nil || preceding == 10 || preceding == 13)
            let normalizedKey = normalized(key)
            let wholeLine = !json && (headerLine || ["authorization", "cookie", "set_cookie"].contains(normalizedKey))
            let end: Int
            if wholeLine {
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

    private static func valueEnd(in bytes: [UInt8], start: Int, json: Bool) -> Int {
        guard start < bytes.count else { return start }
        if bytes[start] == 123 || bytes[start] == 91 { return balancedEnd(in: bytes, start: start) }
        if bytes[start] == 34 || bytes[start] == 39 {
            return quotedEnd(in: bytes, start: start, quote: bytes[start], escapedDelimiter: false)
        }
        if bytes[start] == 92, start + 1 < bytes.count, bytes[start + 1] == 34 || bytes[start + 1] == 39 {
            return quotedEnd(in: bytes, start: start, quote: bytes[start + 1], escapedDelimiter: true)
        }
        var end = start
        while end < bytes.count {
            let byte = bytes[end]
            if byte == 9 || byte == 10 || byte == 13 || byte == 32 || byte == 38 || byte == 59 { break }
            if byte == 44 || byte == 125 || byte == 93 || (!json && byte == 41) { break }
            end += 1 // Quotes in the middle of an unquoted token are part of that token.
        }
        return end
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
            } else if byte == 123 || byte == 91 {
                guard closers.count < 128 else { return bytes.count }
                closers.append(byte == 123 ? 125 : 93)
            } else if byte == 125 || byte == 93 {
                guard closers.last == byte else { return bytes.count }
                closers.removeLast()
                if closers.isEmpty { return cursor + 1 }
            }
            cursor += 1
        }
        return bytes.count // Malformed composite values fail closed.
    }
}
