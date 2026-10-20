import Foundation

public enum Redactor {
    private static let keys = "token|authkey|auth_key|stoken|ltoken|cookie_token|password|session|ticket|authorization|cookie|set-cookie|uid|account_id|accountid|user_id|userid|session_id|access_token|refresh_token"
    // These expressions are constant, never constructed from log contents.
    private static let headers = try! NSRegularExpression(
        pattern: #"(?im)(\b(?:authorization|cookie|set-cookie)[\t ]*:[\t ]*)[^\r\n]*"#)
    private static let jsonValues = try! NSRegularExpression(
        pattern: #"(?i)("(?:"# + keys + #")"\s*:\s*)("(?:\\.|[^"\\])*(?:"|$)|[^,}\]\r\n]+)"#)
    private static let assignments = try! NSRegularExpression(
        pattern: #"(?i)(\b(?:"# + keys + #")[\t ]*=[\t ]*)(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\s&;"']*)"#)
    private static let sensitiveKeys: Set<String> = Set(keys.split(separator: "|").map { normalized(String($0)) })

    public static func redact(_ s: String) -> String {
        if let data = s.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let sanitized = try? JSONSerialization.data(withJSONObject: redactJSON(object, depth: 0),
               options: [.sortedKeys, .withoutEscapingSlashes]) {
            return String(decoding: sanitized, as: UTF8.self)
        }
        return redactText(s)
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
        if let string = object as? String { return redactText(string) }
        return object
    }

    private static func redactText(_ s: String) -> String {
        var result = headers.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
            withTemplate: "$1<redacted>")
        result = jsonValues.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
            withTemplate: "$1\"<redacted>\"")
        return assignments.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
            withTemplate: "$1<redacted>")
    }
}
