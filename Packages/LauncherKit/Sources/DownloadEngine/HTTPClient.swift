import Foundation

public struct HTTPResponseHead: Sendable {
    public let status: Int
    public let contentLength: Int64?
    public let contentRange: ClosedRange<Int64>?
    public let totalLength: Int64?
    public let retryAfter: Duration?

    public init(
        status: Int,
        contentLength: Int64? = nil,
        contentRange: ClosedRange<Int64>? = nil,
        totalLength: Int64? = nil,
        retryAfter: Duration? = nil
    ) {
        self.status = status
        self.contentLength = contentLength
        self.contentRange = contentRange
        self.totalLength = totalLength
        self.retryAfter = retryAfter
    }

    init(_ response: HTTPURLResponse) {
        let length = response.expectedContentLength
        let (range, total) = Self.parseRange(response.value(forHTTPHeaderField: "Content-Range"))
        self.init(
            status: response.statusCode,
            contentLength: length >= 0 ? length : nil,
            contentRange: range,
            totalLength: total,
            retryAfter: Self.parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"))
        )
    }

    private static func parseRange(_ header: String?) -> (ClosedRange<Int64>?, Int64?) {
        guard let header else { return (nil, nil) }
        let parts = header.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return (nil, nil) }
        let values = parts[1].split(separator: "/", omittingEmptySubsequences: false)
        guard values.count == 2 else { return (nil, nil) }
        let total = Int64(values[1])
        guard values[1] == "*" || total.map({ $0 >= 0 }) == true else { return (nil, nil) }
        if values[0] == "*" { return (nil, total) }
        let bounds = values[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let first = Int64(bounds[0]), let last = Int64(bounds[1]),
              first >= 0, last >= first, total.map({ last < $0 }) ?? true
        else { return (nil, nil) }
        return (first...last, total)
    }

    private static func parseRetryAfter(_ header: String?) -> Duration? {
        guard let header else { return nil }
        let value = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Int64(value), seconds >= 0 { return .seconds(seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return .seconds(max(0, date.timeIntervalSinceNow))
    }
}

public protocol HTTPClient: Sendable {
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws
        -> (HTTPResponseHead, AsyncThrowingStream<Data, any Error>)
}
