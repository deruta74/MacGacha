import Foundation

public enum Redactor {
    private static let keys = "token|authkey|auth_key|stoken|ltoken|cookie_token|password|session|ticket|authorization|cookie|set-cookie|uid|account_id|accountid|user_id|userid|session_id|access_token|refresh_token"
    // These expressions are constant, never constructed from log contents.
    private static let headers = try! NSRegularExpression(
        pattern: #"(?im)(\b(?:authorization|cookie|set-cookie)[\t ]*:[\t ]*)[^\r\n]*"#)
    private static let jsonKeys = try! NSRegularExpression(
        pattern: #"(?i)"(?:"# + keys + #")"\s*:\s*"#)
    private static let assignments = try! NSRegularExpression(
        pattern: #"(?i)\b(?:"# + keys + #")[\t ]*=[\t ]*"#)
    private static let sensitiveKeys: Set<String> = Set(keys.split(separator: "|").map { normalized(String($0)) })

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
        for (key, value) in metadata {
            result[redactText(key)] = isSensitive(key) ? "<redacted>" : redact(value)
        }
        return result
    }

    private static func normalized(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func isSensitive(_ key: String) -> Bool {
        sensitiveKeys.contains(normalized(key))
    }

    private static func redactJSON(_ object: Any, depth: Int) -> Any {
        guard depth < 32 else { return "<redacted>" }
        if let dictionary = object as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, value) in dictionary {
                result[redactText(key)] = isSensitive(key) ? "<redacted>" : redactJSON(value, depth: depth + 1)
            }
            return result
        }
        if let array = object as? [Any] { return array.map { redactJSON($0, depth: depth + 1) } }
        if let string = object as? String { return redact(string, depth: depth + 1) }
        return object
    }

    private static func redactText(_ s: String) -> String {
        var result = headers.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
            withTemplate: "$1<redacted>")
        result = replaceValues(in: result, matching: jsonKeys, json: true)
        return replaceValues(in: result, matching: assignments, json: false)
    }

    private static func replaceValues(in text: String, matching expression: NSRegularExpression, json: Bool) -> String {
        let bytes = Array(text.utf8)
        var result: [UInt8] = []
        var copied = 0
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let prefixStart = text.utf8.distance(from: text.utf8.startIndex, to: range.lowerBound)
            guard prefixStart >= copied else { continue }
            let start = text.utf8.distance(from: text.utf8.startIndex, to: range.upperBound)
            let end = valueEnd(in: bytes, start: start, json: json)
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
            if json && (byte == 44 || byte == 125 || byte == 93) { break }
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
