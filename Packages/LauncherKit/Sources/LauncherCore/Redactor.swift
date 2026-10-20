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
    private static let tokenShapes = try! NSRegularExpression(pattern: #"eyJ[\w-]+\.[\w-]+\.[\w-]+|v2_[A-Za-z0-9_-]{17,}"#)
    private static let cookieFields = try! NSRegularExpression(
        pattern: #"(?i)(?<![a-z0-9_-])(name|value)[\t ]*[:=][\t ]*"#)
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

    /// Normalizes only the uncommon camelCase/encoded-prefix path, in one scalar pass.
    private static func normalized(_ key: String) -> String {
        let scalars = key.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex && scalars[index] == "%" {
            let hex1 = scalars.index(after: index)
            guard hex1 < scalars.endIndex else { break }
            let hex2 = scalars.index(after: hex1)
            guard hex2 < scalars.endIndex, isHex(scalars[hex1].value), isHex(scalars[hex2].value) else { break }
            index = scalars.index(after: hex2)
        }
        var result = ""
        var previous: UInt32 = 0
        while index < scalars.endIndex {
            let scalar = scalars[index]
            let value = scalar.value
            let next = scalars.index(after: index)
            let nextIsLower = next < scalars.endIndex && (97...122).contains(scalars[next].value)
            if (65...90).contains(value) {
                if (97...122).contains(previous) || (48...57).contains(previous)
                    || ((65...90).contains(previous) && nextIsLower) { result.append("_") }
                // ASCII uppercase + 32 is always a valid lowercase Unicode scalar.
                result.unicodeScalars.append(UnicodeScalar(value + 32)!)
            } else if value == 45 {
                result.append("_")
            } else if value > 127 {
                result += String(scalar).lowercased()
            } else {
                result.unicodeScalars.append(scalar)
            }
            previous = value
            index = next
        }
        return result
    }

    private static func isHex(_ value: UInt32) -> Bool {
        (48...57).contains(value) || (65...70).contains(value) || (97...102).contains(value)
    }

    private static func matchesSensitiveFragment(_ key: String) -> Bool {
        legacyKeys.contains(key) || sensitiveFragments.contains { key.contains($0) }
    }

    private static func isSensitive(_ key: String) -> Bool {
        let lower = key.lowercased()
        if matchesSensitiveFragment(lower) { return true }
        if lower.contains("-"), matchesSensitiveFragment(lower.replacingOccurrences(of: "-", with: "_")) { return true }
        guard key.hasPrefix("%") || key.utf8.contains(where: { (65...90).contains($0) }) else { return false }
        return matchesSensitiveFragment(normalized(key))
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
        let cookies = redactCookieValues(s)
        let quoted = replaceValues(in: cookies, matching: jsonKeys, json: true)
        let result = replaceValues(in: quoted, matching: singleQuotedKeys, json: false)
        let assignmentsRedacted = replaceValues(in: result, matching: assignments, json: false)
        let sanitized = replaceValues(in: assignmentsRedacted, matching: colonValues, json: false, colon: true)
        return tokenShapes.stringByReplacingMatches(in: sanitized, range: NSRange(sanitized.startIndex..., in: sanitized),
            withTemplate: "<redacted>")
    }

    private static func replaceValues(in text: String, matching expression: NSRegularExpression,
        json: Bool, colon: Bool = false) -> String {
        let bytes = Array(text.utf8)
        var result: [UInt8] = []
        var copied = 0
        var context = TextContext()
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let keyRange = Range(match.range(at: 1), in: text) else { continue }
            let rawKey = String(text[keyRange])
            let key = json && rawKey.contains("\\")
                ? (try? JSONDecoder().decode(String.self, from: Data(("\"" + rawKey + "\"").utf8))) ?? rawKey : rawKey
            let lowerKey = key.lowercased()
            let headerStyle = lowerKey.contains("authorization") || lowerKey.contains("cookie") || lowerKey.hasPrefix("x-rpc-")
            guard isSensitive(key) || (!json && headerStyle) else { continue }
            let prefixStart = text.utf8.distance(from: text.utf8.startIndex, to: range.lowerBound)
            guard prefixStart >= copied else { continue }
            let start = text.utf8.distance(from: text.utf8.startIndex, to: range.upperBound)
            context.advance(in: bytes, to: prefixStart)
            let query = !json && (prefixStart > 0 && (bytes[prefixStart - 1] == 63 || bytes[prefixStart - 1] == 38)
                || rawKey.lowercased().contains("%3f") || rawKey.lowercased().contains("%26"))
            // Foundation's activity labels are ordinary text, while quoted/structured session fields
            // and fields inside printed Swift values retain sensitive-key treatment.
            if colon && !query && context.parentheses == 0 && context.jsonDepth == 0
                && (key == "Session" || key == "URLSession"), start < bytes.count,
                bytes[start] != 34 && bytes[start] != 39 { continue }
            let wholeLine = !json && !query && headerStyle
            let end: Int
            if query {
                end = queryValueEnd(in: bytes, start: start)
            } else if wholeLine {
                end = bytes[start...].firstIndex { $0 == 10 || $0 == 13 } ?? bytes.count
            } else {
                end = valueEnd(in: bytes, start: start, json: json && context.jsonDepth > 0,
                    closesParenthesis: context.parentheses > 0)
            }
            guard end > start else { continue }
            result.append(contentsOf: bytes[copied..<start])
            result.append(contentsOf: (json ? "\"<redacted>\"" : "<redacted>").utf8)
            copied = end
        }
        result.append(contentsOf: bytes[copied...])
        return String(decoding: result, as: UTF8.self)
    }

    private static func valueEnd(in bytes: [UInt8], start: Int, json: Bool,
        closesParenthesis: Bool = false, authScheme: Bool = true) -> Int {
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
            return valueEnd(in: bytes, start: valueStart, json: json, closesParenthesis: closesParenthesis, authScheme: false)
        }
        if bytes[start] == 34 || bytes[start] == 39 {
            return quotedEnd(in: bytes, start: start, quote: bytes[start], escapedDelimiter: false)
        }
        if bytes[start] == 92, start + 1 < bytes.count, bytes[start + 1] == 34 || bytes[start + 1] == 39 {
            return quotedEnd(in: bytes, start: start, quote: bytes[start + 1], escapedDelimiter: true)
        }
        var end = start
        var innerParentheses = 0
        while end < bytes.count {
            let byte = bytes[end]
            if byte <= 32 || byte == 38 || byte == 59 || isEncodedTerminator(in: bytes, at: end) { break }
            if json && (byte == 44 || byte == 125 || byte == 93) { break }
            if byte == 40 { innerParentheses += 1 }
            if byte == 41 {
                if innerParentheses > 0 { innerParentheses -= 1 }
                else if closesParenthesis { break }
            }
            end += 1 // Quotes in the middle of an unquoted token are part of that token.
        }
        return end
    }

    private struct TextContext {
        var parentheses = 0
        var jsonDepth = 0
        private var cursor = 0
        private var quote: UInt8?
        private var escaped = false

        mutating func advance(in bytes: [UInt8], to end: Int) {
            while cursor < end {
                let byte = bytes[cursor]
                if let delimiter = quote {
                    if escaped { escaped = false }
                    else if byte == 92 { escaped = true }
                    else if byte == delimiter { quote = nil }
                } else {
                    switch byte {
                    case 34, 39: quote = byte
                    case 40: parentheses += 1
                    case 41: parentheses = max(0, parentheses - 1)
                    case 123, 91: jsonDepth += 1
                    case 125, 93: jsonDepth = max(0, jsonDepth - 1)
                    default: break
                    }
                }
                cursor += 1
            }
        }
    }

    private static func redactCookieValues(_ text: String) -> String {
        guard text.localizedCaseInsensitiveContains("name"), text.localizedCaseInsensitiveContains("value") else { return text }
        let bytes = Array(text.utf8)
        var result: [UInt8] = []
        var copied = 0
        var sensitiveName = false
        var scopeEnd = 0
        for field in cookieFields.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(field.range, in: text), let keyRange = Range(field.range(at: 1), in: text) else { continue }
            let prefix = text.utf8.distance(from: text.utf8.startIndex, to: range.lowerBound)
            guard prefix >= copied else { continue }
            let start = text.utf8.distance(from: text.utf8.startIndex, to: range.upperBound)
            if text[keyRange].lowercased() == "name" {
                let end = valueEnd(in: bytes, start: start, json: false)
                let rawName = String(decoding: bytes[start..<end], as: UTF8.self)
                let name: String
                if rawName.contains("\\"), let decoded = try? JSONDecoder().decode(String.self, from: Data(rawName.utf8)) {
                    name = decoded
                } else { name = rawName.trimmingCharacters(in: CharacterSet(charactersIn: "\"',;> \t\r\n")) }
                sensitiveName = isSensitive(name)
                let preceding = text[..<range.lowerBound]
                if let opening = preceding.range(of: "<NSHTTPCookie", options: [.backwards, .caseInsensitive]),
                   !preceding[opening.upperBound...].contains(">") {
                    scopeEnd = bytes[start...].firstIndex(of: 62) ?? bytes.count
                } else {
                    scopeEnd = bytes[start...].firstIndex { $0 == 10 || $0 == 13 } ?? bytes.count
                }
            } else if sensitiveName && prefix < scopeEnd {
                let quoted = start < bytes.count && (bytes[start] == 34 || bytes[start] == 39
                    || (bytes[start] == 92 && start + 1 < bytes.count && (bytes[start + 1] == 34 || bytes[start + 1] == 39)))
                let end: Int
                if quoted {
                    // A '>' inside a quoted cookie value belongs to the value, not the wrapper.
                    end = valueEnd(in: bytes, start: start, json: false)
                } else {
                    // Foundation prints unquoted values as a complete field line, including spaces.
                    let lineEnd = bytes[start...].firstIndex { $0 == 10 || $0 == 13 } ?? bytes.count
                    end = min(lineEnd, scopeEnd)
                }
                guard end > start else { continue }
                result.append(contentsOf: bytes[copied..<start])
                result.append(contentsOf: "\"<redacted>\"".utf8)
                copied = end
                sensitiveName = false
            }
        }
        result.append(contentsOf: bytes[copied...])
        return String(decoding: result, as: UTF8.self)
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
